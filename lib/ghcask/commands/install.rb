# frozen_string_literal: true

require "tmpdir"

require "ghcask/cask_file"
require "ghcask/commands/base"
require "ghcask/direct_url"
require "ghcask/repo_ref"
require "ghcask/source"

module Ghcask
  module Commands
    # `install`, `generate`, `reinstall` — one pipeline: build a Source, then reuse the
    # existing cask or refresh it (resolve → download → infer app → write cask → cache →
    # delegate to brew). github-vs-url branching lives in the sources.
    class Install < Base
      Options = Struct.new(
        :url, :asset_pattern, :app, :cask, :name, :cmd, :stable, :prerelease, :version,
        :arch, :quarantine, :dry_run, :force, :trust, :install, :reinstall, :passthrough,
        keyword_init: true
      )

      def install
        run("install", install: true, reinstall: false)
      end

      def generate
        run("generate", install: false, reinstall: false)
      end

      def reinstall
        run("reinstall", install: true, reinstall: true)
      end

      private

      def run(name, install:, reinstall:)
        guard do
          targets, options = parse(name, install: install, reinstall: reinstall)
          next 0 if targets == :help

          validate_targets!(targets, options, name, reinstall: reinstall)
          catalog = tap.registry.load_if_exists || Catalog.new
          targets.each { |target| process(target, options, catalog) }
          0
        end
      end

      def parse(name, install:, reinstall:)
        options = Options.new(
          stable: false, prerelease: false, dry_run: false, force: false,
          trust: false, install: install, reinstall: reinstall, quarantine: nil, passthrough: []
        )
        args, options.passthrough = split_passthrough(@argv)
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: brew ghcask #{name} #{reinstall ? "cask-name|owner/repo [...]" : "owner/repo [...]"} [options]"
          opts.on("--url URL", "Use a direct .dmg/.pkg/.zip/.tgz/.tar.{gz,xz,bz2,zst} package URL") { |value| options.url = value }
          opts.on("--asset PATTERN", "Select release asset by glob pattern") { |value| options.asset_pattern = value } unless reinstall
          opts.on("--app NAME", "Set .app bundle name explicitly") { |value| options.app = value }
          opts.on("--cask CASK", "Set generated cask name") { |value| options.cask = value } unless reinstall
          opts.on("--name NAME", "Set display name") { |value| options.name = value }
          opts.on("--cmd NAME", "Command name for an installed CLI binary") { |value| options.cmd = value }
          opts.on("--stable", "Select latest stable release explicitly") { options.stable = true }
          opts.on("--prerelease", "Allow prerelease releases") { options.prerelease = true }
          opts.on("--version VERSION", "Install and pin a specific release tag or version") { |value| options.version = value }
          opts.on("--arch ARCH", "Override local architecture") { |value| options.arch = value }
          opts.on("-s", "--no-quarantine", "Skip macOS quarantine (strips the xattr after install)") { options.quarantine = false }
          opts.on("-n", "--dry-run", "Show the plan without writing local state") { options.dry_run = true }
          force_help = install ? "Re-download from the source and pass --force to Homebrew" : "Re-download from the source even if cached"
          opts.on("-f", "--force", force_help) { options.force = true }
          opts.on("-t", "--trust", "Trust the generated local cask after writing it") { options.trust = true } unless reinstall
          forward_brew_flags(opts, options.passthrough)
          opts.on("-h", "--help", "Show help") do
            stdout.puts opts
            return [:help, options]
          end
        end
        parser.parse!(args)
        [args.dup, options]
      end

      def validate_targets!(targets, options, name, reinstall:)
        raise UsageError, empty_target_usage(name, reinstall) if targets.empty?
        if reinstall
          selectors = [options.version, options.prerelease, options.stable].count { |value| value }
          raise UsageError, "--version, --prerelease, and --stable are mutually exclusive" if selectors > 1
        elsif options.prerelease && options.stable
          raise UsageError, "--prerelease and --stable are mutually exclusive"
        end
        raise UsageError, "--url supports exactly one cask name" if options.url && targets.length != 1
        return if targets.length == 1

        single = single_target_options(options)
        raise UsageError, "#{single.join(", ")} only support one target" unless single.empty?
      end

      def empty_target_usage(name, reinstall)
        return "cask name or repository is required. Usage: brew ghcask reinstall cask-name|owner/repo" if reinstall

        "repository is required. Usage: brew ghcask #{name} owner/repo"
      end

      def single_target_options(options)
        names = []
        names << "--app" if options.app
        names << "--cask" if options.cask && !options.reinstall
        names << "--name" if options.name
        names << "--cmd" if options.cmd
        names << "--version" if options.version
        names
      end

      def process(target, options, catalog)
        source, existing, reuse = build_source(target, options, catalog)
        if reuse
          handle_reuse(existing, options, catalog)
        else
          handle_refresh(source, options, catalog)
        end
      end

      def build_source(target, options, catalog)
        return build_reinstall_source(target, options, catalog) if options.reinstall
        return build_url_install_source(target, options, catalog) if options.url

        build_github_install_source(target, options, catalog)
      end

      def build_github_install_source(target, options, catalog)
        ref = RepoRef.parse(target)
        requested_version = options.version || ref.version
        existing = reusable_github_entry(catalog, ref.repo, options, requested_version)
        return [nil, existing, true] if existing

        source = GithubSource.new(
          repo: ref.repo,
          release_policy: options.prerelease ? "latest-prerelease" : "latest-stable",
          requested_version: requested_version,
          asset_pattern: options.asset_pattern,
          cask_override: options.cask, force: options.force,
          install: options.install, quarantine: options.quarantine,
          app_override: options.app, name_override: options.name, arch_override: options.arch, command_override: options.cmd
        )
        [source, nil, false]
      end

      def build_url_install_source(target, options, catalog)
        cask = CaskFile.normalize_name(target)
        raise UsageError, "Direct URL installs require an explicit cask name. Use `brew ghcask install cask-name --url URL`." if cask.empty?
        if target.to_s.include?("/") || target.to_s.start_with?("http://", "https://")
          raise UsageError, "Direct URL cask name must not look like a GitHub repository. Use `brew ghcask install cask-name --url URL`."
        end
        raise UsageError, "--cask is only available for GitHub source installs. Direct URL installs use the positional cask name." if options.cask
        raise UsageError, "--asset is only available for GitHub source installs." if options.asset_pattern
        raise UsageError, "--prerelease and --stable are only available for GitHub source installs." if options.prerelease || options.stable

        url = DirectUrl.package_url(options.url)
        existing = reusable_url_entry(catalog, cask, options)
        if existing && url != existing.asset_url
          raise UsageError, "#{cask} already exists from a different URL. Use `brew ghcask reinstall #{cask} --url #{options.url}` to change it."
        end
        return [nil, existing, true] if existing

        source = UrlSource.new(
          cask_name: cask, url: url, version_override: options.version,
          install: options.install, quarantine: options.quarantine,
          app_override: options.app, name_override: options.name, arch_override: options.arch, command_override: options.cmd
        )
        [source, nil, false]
      end

      def build_reinstall_source(target, options, catalog)
        name, entry = resolve_entry(catalog, target)
        ref = repo_ref_or_nil(target)
        requested = options.version || ref&.version
        github_selection = !requested.to_s.empty? || options.prerelease || options.stable

        return build_url_reinstall(name, entry, options, github_selection) if entry.url?

        build_github_reinstall(name, entry, options, requested, github_selection)
      end

      def build_url_reinstall(name, entry, options, github_selection)
        raise UsageError, "GitHub release selection is only supported for GitHub casks. Use `brew ghcask reinstall #{name} --url NEW_URL` for direct URL casks." if github_selection
        return [nil, entry, true] unless options.url || options.force

        source = UrlSource.new(
          cask_name: name, url: DirectUrl.package_url(options.url || entry.asset_url),
          version_override: options.version, existing: entry, install: true,
          quarantine: options.quarantine, app_override: options.app,
          name_override: options.name, arch_override: options.arch, command_override: options.cmd
        )
        [source, entry, false]
      end

      def build_github_reinstall(name, entry, options, requested, github_selection)
        raise UsageError, "reinstall --url is only supported for direct URL casks. Use `brew ghcask reinstall #{name} --force` to re-fetch a GitHub cask." if options.url
        return [nil, entry, true] unless github_selection || options.force

        policy = if options.prerelease
          "latest-prerelease"
        elsif options.stable
          "latest-stable"
        else
          entry.release_policy
        end
        requested_version = github_selection ? requested : entry.requested_version

        source = GithubSource.new(
          repo: entry.repo, release_policy: policy, requested_version: requested_version,
          asset_pattern: entry.asset_pattern, existing: entry, install: true, force: options.force,
          quarantine: options.quarantine, app_override: options.app,
          name_override: options.name, arch_override: options.arch, command_override: options.cmd
        )
        [source, entry, false]
      end

      def reusable_github_entry(catalog, repo, options, requested_version)
        return nil unless reusable_install_options?(options) && requested_version.to_s.empty?

        match = catalog.find_by_repo(repo)
        return nil unless match
        return nil unless tap.cask_exist?(match.first)

        match.last
      end

      def reusable_url_entry(catalog, cask, options)
        return nil unless reusable_install_options?(options)

        entry = catalog[cask]
        return nil unless entry&.url?
        return nil unless tap.cask_exist?(cask)

        entry
      end

      def reusable_install_options?(options)
        !options.asset_pattern && !options.app && !options.cask && !options.name &&
          !options.version && !options.arch && !options.force &&
          !options.prerelease && !options.stable
      end

      def handle_reuse(entry, options, catalog)
        quarantine_change = !options.quarantine.nil? && options.quarantine != entry.quarantine?
        display = quarantine_change ? entry.merge(quarantine: options.quarantine) : entry

        show_entry(display, options)
        stdout.puts "Using existing local cask."
        stdout.puts entry.url? ? "Skipping direct URL download." : "Skipping GitHub lookup."

        if options.dry_run
          stdout.puts "Would set quarantine to #{options.quarantine ? "enabled" : "disabled"}." if quarantine_change
          print_action_plan(display, options) if options.install
          return
        end

        if quarantine_change
          entry.quarantine = options.quarantine
          entry.updated_at = Ghcask.now
        end
        finish(entry, options, catalog, dirty: quarantine_change)
      end

      def handle_refresh(source, options, catalog)
        if options.dry_run && source.previewable_without_download?
          entry = source.preview_entry(source.resolve(github, fetch_description: false))
          show_entry(entry, options)
          print_action_plan(entry, options)
          return
        end

        resolution = source.resolve(github)

        reused = source.unchanged_entry(resolution) unless options.force
        if reused
          show_entry(reused, options)
          if options.dry_run
            print_action_plan(reused, options)
            return
          end
          stdout.puts "#{reused.cask}: already current, reusing the local cask."
          finish(reused, options, catalog, dirty: false)
          return
        end

        entry = nil
        Dir.mktmpdir("ghcask-#{options.reinstall ? "reinstall" : "install"}-") do |dir|
          cached = cached_package(resolution, options)
          path = cached || source.download(resolution, github: github, package: package, destination_dir: dir, stdout: stdout)
          sha = package.sha256(path)
          app_meta = package.infer_app(path, app_override: source.app_override_for_inference)
          entry = source.build_entry(resolution, sha: sha, app_meta: app_meta)

          show_entry(entry, options)
          if options.dry_run
            print_action_plan(entry, options)
            next
          end

          persist(entry, path, options, catalog, cached: !cached.nil?)
        end
        finish(entry, options, catalog, dirty: true) unless options.dry_run
      end

      def cached_package(resolution, options)
        return nil if options.force

        url = resolution.asset&.url
        return nil if url.to_s.empty?

        path = brew.cached_download_for_url(url)
        stdout.puts "Using cached download #{File.basename(path)} (pass --force to re-download)." if path
        path
      end

      def persist(entry, asset_path, options, catalog, cached: false)
        tap.init
        CaskFile.write(tap.cask_path(entry.cask), entry) { brew.trust(entry.cask) if options.trust }
        catalog[entry.cask] = entry
        brew.cache_package(entry.cask, asset_path) unless cached
      end

      def finish(entry, options, catalog, dirty:)
        unless options.install
          tap.registry.save(catalog) if dirty
          stdout.puts "Generated local cask: #{entry.cask}."
          return
        end

        if options.reinstall
          brew.reinstall(entry.cask, force: options.force, quarantine: entry.quarantine?, extra: options.passthrough)
        else
          brew.install(entry.cask, force: options.force, quarantine: entry.quarantine?, extra: options.passthrough)
        end

        if entry.install_state != Entry::STATE_INSTALLED
          entry.install_state = Entry::STATE_INSTALLED
          dirty = true
        end
        tap.registry.save(catalog) if dirty
        apply_quarantine_policy(entry)
      end

      def show_entry(entry, options)
        if options.dry_run || options.passthrough.include?("--verbose")
          print_entry(entry)
        else
          stdout.puts "==> #{entry.cask} #{entry.version}"
        end
      end

      def print_entry(entry)
        if entry.url?
          stdout.puts "Source: direct URL"
          stdout.puts "URL: #{entry.asset_url}"
        else
          stdout.puts "Source: GitHub"
          stdout.puts "Repository: #{entry.repo}"
          stdout.puts "Release policy: #{entry.release_policy}"
        end
        stdout.puts "Requested version: #{entry.requested_version}" if entry.pinned?
        stdout.puts "Release: #{entry.release_tag}" if entry.release_tag
        stdout.puts "Version: #{entry.version}"
        stdout.puts "Asset: #{entry.asset_name}"
        stdout.puts "Asset URL: #{entry.asset_url}" unless entry.url?
        stdout.puts "Architecture: #{entry.arch || "(not set)"}"
        stdout.puts "Homepage: #{entry.homepage}"
        stdout.puts "Cask: #{entry.cask}"
        stdout.puts "Cask path: #{tap.cask_path(entry.cask)}"
        stdout.puts "Name: #{entry.name}"
        if entry.pkg?
          stdout.puts "Package: #{entry.asset_name}"
          stdout.puts "Pkg id: #{entry.pkg_id}" if entry.pkg_id
        elsif entry.binary?
          stdout.puts "Binary: #{entry.binary}"
          stdout.puts "Command: #{entry.command}"
        else
          stdout.puts "App: #{entry.app}"
        end
        stdout.puts "sha256: #{entry.sha256}"
        stdout.puts "Quarantine: #{entry.quarantine? ? "enabled" : "disabled"}"
      end

      def print_action_plan(entry, options)
        unless options.reinstall
          stdout.puts "Would write cask: #{tap.cask_path(entry.cask)}"
          stdout.puts "Would trust cask after writing it." if options.trust
        end
        unless options.install
          stdout.puts "Would generate the local cask without installing."
          return
        end

        action = options.reinstall ? :reinstall : :install
        stdout.puts "Would run: #{brew.plan(entry.cask, action: action, force: options.force, quarantine: entry.quarantine?, extra: options.passthrough).join(" ")}"
        stdout.puts "Would clear quarantine for the installed app." unless entry.quarantine?
      end
    end
  end
end

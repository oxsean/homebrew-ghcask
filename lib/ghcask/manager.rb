# frozen_string_literal: true

require "optparse"
require "fileutils"
require "json"
require "set"
require "tmpdir"
require "time"

require "ghcask/asset_selector"
require "ghcask/cask"
require "ghcask/direct_url"
require "ghcask/github"
require "ghcask/homebrew"
require "ghcask/local_tap"
require "ghcask/package"
require "ghcask/repo_ref"

module Ghcask
  class Manager
    class Error < StandardError; end

    def initialize(argv, stdout:, stderr:, github: GitHub::Client.new, tap: LocalTap.new, runner: CommandRunner.new, package: Package)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @github = github
      @tap = tap
      @runner = runner
      @package = package
      @homebrew_cache = Homebrew::Cache.new(runner: runner, stdout: stdout, stderr: stderr)
    end

    def update(upgrade: true)
      options = parse_update(upgrade: upgrade)
      data = @tap.registry.ensure_exists
      raise Error, "update does not accept cask names. Use `brew ghcask upgrade cask-name` to target one app." if !upgrade && !options[:targets].empty?

      names = upgrade ? target_names(data, options[:targets]) : data["casks"].keys
      raise Error, "--force requires exactly one explicit cask name" if options[:force] && options[:targets].length != 1

      upgrade_names = []
      names.each do |name|
        entry = data["casks"].fetch(name)
        if url_source?(entry)
          raise Error, "upgrade --force is not supported for direct URL casks. Use `brew ghcask reinstall #{name} --url NEW_URL`." if options[:force]

          @stdout.puts "#{name}: direct URL cask, skipping source refresh"
          upgrade_names << name if upgrade && !options[:dry_run]
          next
        end

        original_requested_version = entry["requested_version"]
        upgrade_names << name if upgrade && !options[:dry_run]
        if options[:force]
          entry["requested_version"] = nil
        end

        release = @github.select_release(
          entry.fetch("repo"),
          policy: entry.fetch("release_policy"),
          requested_version: entry["requested_version"]
        )
        asset = AssetSelector.new(release.assets, arch: entry["arch"] || AssetSelector.local_arch).select(pattern: entry["asset_pattern"])
        if entry["release_tag"] == release.tag_name &&
           entry["asset_name"] == asset.name &&
           original_requested_version == entry["requested_version"]
          @stdout.puts "#{name}: already current"
          next
        end

        sha = entry["sha256"]
        if options[:dry_run]
          refresh_entry(entry, release, asset, sha)
        else
          Dir.mktmpdir("ghcask-update-") do |dir|
            asset_path = @package.download(asset, destination_dir: dir, stdout: @stdout)
            sha = @package.sha256(asset_path)
            refresh_entry(entry, release, asset, sha)
            Cask.write(cask_path(name), entry)
            @homebrew_cache.cache_cask(name, asset_path)
          end
        end
        @stdout.puts "#{name}: refreshed to #{release.tag_name}"
      end

      @tap.registry.save(data) unless options[:dry_run]
      upgrade_casks(data, upgrade_names)
      0
    rescue OptionParser::ParseError, Error, DirectUrl::Error, Registry::Error, GitHub::Error, AssetSelector::Error, Package::Error, Homebrew::Error => e
      @stderr.puts "ghcask update: #{e.message}"
      1
    end

    def outdated
      options = parse_outdated
      data = @tap.registry.ensure_exists
      data["casks"].each do |name, entry|
        if url_source?(entry)
          @stdout.puts "#{name}: direct URL cask, not checkable" if options[:all]
          next
        end

        release = @github.select_release(
          entry.fetch("repo"),
          policy: entry.fetch("release_policy"),
          requested_version: options[:all] ? nil : entry["requested_version"]
        )
        if entry["release_tag"] == release.tag_name
          @stdout.puts "#{name}: current #{entry["release_tag"]}"
        else
          @stdout.puts "#{name}: #{entry["release_tag"]} -> #{release.tag_name}"
        end
      end
      0
    rescue OptionParser::ParseError, Error, Registry::Error, GitHub::Error, Homebrew::Error => e
      @stderr.puts "ghcask outdated: #{e.message}"
      1
    end

    def list
      data = @tap.registry.ensure_exists
      data["casks"].each do |name, entry|
        source = url_source?(entry) ? entry["cask"] : entry["repo"]
        @stdout.puts "#{name}\t#{entry["version"]}\t#{source}"
      end
      0
    rescue Registry::Error, Homebrew::Error => e
      @stderr.puts "ghcask list: #{e.message}"
      1
    end

    def info
      target = @argv.shift
      raise Error, "cask name or repository is required" if target.to_s.empty?

      data = @tap.registry.ensure_exists
      name, entry = resolve_managed_cask(data, target)

      @stdout.puts "Cask: #{name}"
      @stdout.puts "Full cask: ghcask/local/#{name}"
      @stdout.puts "Source type: #{source_type(entry)}"
      if url_source?(entry)
        @stdout.puts "URL: #{entry["asset_url"]}"
      else
        @stdout.puts "Repository URL: https://github.com/#{entry["repo"]}"
      end
      @stdout.puts "Release policy: #{entry["release_policy"]}"
      @stdout.puts "Version: #{entry["version"]}"
      @stdout.puts "Asset URL: #{entry["asset_url"]}"
      @stdout.puts "sha256: #{entry["sha256"]}"
      @stdout.puts "App: #{entry["app"]}"
      @stdout.puts "Cask path: #{cask_path(name)}"
      print_homebrew_install_info(name)
      0
    rescue Error, Registry::Error, Homebrew::Error => e
      @stderr.puts "ghcask info: #{e.message}"
      1
    end

    def uninstall
      options = parse_uninstall
      target = @argv.shift
      raise Error, "cask name or repository is required" if target.to_s.empty?
      raise Error, "unknown option #{@argv.first}" unless @argv.empty?

      data = @tap.registry.ensure_exists
      name, = resolve_managed_cask(data, target)

      if options[:dry_run]
        @stdout.puts "Would uninstall #{name} with Homebrew." unless options[:keep_installed]
        @stdout.puts "Would keep installed app." if options[:keep_installed]
        @stdout.puts "Would remove ghcask metadata for #{name}."
        @stdout.puts "Would remove generated cask file: #{cask_path(name)}"
        return 0
      end

      uninstall_cask(name) unless options[:keep_installed]
      data["casks"].delete(name)
      @tap.registry.save(data)
      FileUtils.rm_f(cask_path(name))
      @stdout.puts "Uninstalled #{name}."
      0
    rescue Error, Registry::Error, Homebrew::Error => e
      @stderr.puts "ghcask uninstall: #{e.message}"
      1
    end

    def reinstall
      options = parse_reinstall
      target = @argv.shift
      raise Error, "cask name or repository is required" if target.to_s.empty?
      raise Error, "unknown option #{@argv.first}" unless @argv.empty?

      data = @tap.registry.ensure_exists
      name, entry = resolve_managed_cask(data, target)
      repo_ref = parse_repo_target(target)
      requested_version = options[:version] || repo_ref&.version

      return reinstall_url(data, name, entry, options) if options[:url]
      if requested_version
        return reinstall_github_release(data, name, entry, requested_version, entry.fetch("release_policy"), options)
      end
      return reinstall_github_release(data, name, entry, nil, "latest-prerelease", options) if options[:prerelease]
      return reinstall_github_release(data, name, entry, nil, "latest-stable", options) if options[:stable]

      command = reinstall_command(name, force: options[:force])
      if options[:dry_run]
        @stdout.puts "Would run: #{command.join(" ")}"
        return 0
      end

      @stdout.puts "Running: #{command.join(" ")}"
      run_homebrew(command, error_prefix: "Homebrew reinstall failed")
      @stdout.puts "Homebrew finished reinstall for #{name}."
      0
    rescue OptionParser::ParseError, Error, Registry::Error, GitHub::Error, AssetSelector::Error, Package::Error, Homebrew::Error => e
      @stderr.puts "ghcask reinstall: #{e.message}"
      1
    end

    def pin
      target = @argv.shift
      raise Error, "cask name or repository is required" if target.to_s.empty?
      raise Error, "unknown option #{@argv.first}" unless @argv.empty?

      data = @tap.registry.ensure_exists
      name, entry = resolve_managed_cask(data, target)
      raise Error, "pin is only supported for GitHub casks. Direct URL casks are changed with `brew ghcask reinstall #{name} --url NEW_URL`." if url_source?(entry)

      entry["requested_version"] = entry.fetch("release_tag")
      entry["updated_at"] = Time.now.utc.iso8601
      @tap.registry.save(data)
      @stdout.puts "Pinned #{name} to #{entry.fetch("release_tag")}."
      0
    rescue Error, Registry::Error, Homebrew::Error => e
      @stderr.puts "ghcask pin: #{e.message}"
      1
    end

    def unpin
      target = @argv.shift
      raise Error, "cask name or repository is required" if target.to_s.empty?
      raise Error, "unknown option #{@argv.first}" unless @argv.empty?

      data = @tap.registry.ensure_exists
      name, entry = resolve_managed_cask(data, target)
      raise Error, "unpin is only supported for GitHub casks. Direct URL casks are changed with `brew ghcask reinstall #{name} --url NEW_URL`." if url_source?(entry)

      entry["requested_version"] = nil
      entry["updated_at"] = Time.now.utc.iso8601
      @tap.registry.save(data)
      @stdout.puts "Unpinned #{name}. It will follow #{entry.fetch("release_policy")}."
      0
    rescue Error, Registry::Error, Homebrew::Error => e
      @stderr.puts "ghcask unpin: #{e.message}"
      1
    end

    def cleanup
      options = parse_cleanup
      data = @tap.registry.ensure_exists
      removed = cleanup_candidates(data)

      if removed.empty?
        @stdout.puts "No deleted local casks found."
        return 0
      end

      removed.each do |name, reason|
        @stdout.puts "#{options[:dry_run] ? "Would remove" : "Removed"} #{reason}: #{name}"
        data["casks"].delete(name) unless options[:dry_run]
        FileUtils.rm_f(cask_path(name)) unless options[:dry_run]
      end
      @tap.registry.save(data) unless options[:dry_run]
      0
    rescue OptionParser::ParseError, Error, Registry::Error, Homebrew::Error => e
      @stderr.puts "ghcask cleanup: #{e.message}"
      1
    end

    private

    def parse_update(upgrade:)
      options = { dry_run: false, force: false, targets: [] }
      parser = OptionParser.new do |opts|
        opts.on("--dry-run") { options[:dry_run] = true }
        opts.on("--force") { options[:force] = true } if upgrade
      end
      parser.parse!(@argv)
      options[:targets] = @argv.dup
      options
    end

    def parse_outdated
      options = { all: false }
      parser = OptionParser.new do |opts|
        opts.on("--all") { options[:all] = true }
      end
      parser.parse!(@argv)
      raise Error, "unknown argument #{@argv.first}" unless @argv.empty?

      options
    end

    def parse_cleanup
      options = { dry_run: false }
      parser = OptionParser.new do |opts|
        opts.on("--dry-run") { options[:dry_run] = true }
      end
      parser.parse!(@argv)
      raise Error, "unknown argument #{@argv.first}" unless @argv.empty?

      options
    end

    def parse_uninstall
      options = { keep_installed: false, dry_run: false }
      parser = OptionParser.new do |opts|
        opts.on("--keep-installed") { options[:keep_installed] = true }
        opts.on("--dry-run") { options[:dry_run] = true }
      end
      parser.parse!(@argv)
      options
    end

    def parse_reinstall
      options = { url: nil, app: nil, name: nil, version: nil, arch: nil, prerelease: false, stable: false, dry_run: false, force: false }
      parser = OptionParser.new do |opts|
        opts.on("--url URL") { |value| options[:url] = value }
        opts.on("--app NAME") { |value| options[:app] = value }
        opts.on("--name NAME") { |value| options[:name] = value }
        opts.on("--version VERSION") { |value| options[:version] = value }
        opts.on("--arch ARCH") { |value| options[:arch] = value }
        opts.on("--prerelease") { options[:prerelease] = true }
        opts.on("--stable") { options[:stable] = true }
        opts.on("--force") { options[:force] = true }
        opts.on("--dry-run") { options[:dry_run] = true }
      end
      parser.parse!(@argv)
      policy_options = [options[:version], options[:prerelease], options[:stable]].count { |value| value }
      raise Error, "--version, --prerelease, and --stable are mutually exclusive" if policy_options > 1

      options
    end

    def target_names(data, targets)
      names = targets.empty? ? data["casks"].keys : targets
      missing = names.reject { |name| data["casks"].key?(name) }
      raise Error, "managed cask not found: #{missing.first}" unless missing.empty?

      names
    end

    def refresh_entry(entry, release, asset, sha)
      entry["version"] = release.tag_name.to_s.sub(/\Av/i, "")
      entry["release_tag"] = release.tag_name
      entry["asset_name"] = asset.name
      entry["asset_url"] = asset.url
      entry["sha256"] = sha
      entry["updated_at"] = Time.now.utc.iso8601
    end

    def reinstall_url(data, name, entry, options)
      raise Error, "reinstall --url is only supported for direct URL casks. Use `brew ghcask upgrade #{name} --force` for GitHub casks." unless url_source?(entry)

      url = DirectUrl.package_url(options[:url])
      Dir.mktmpdir("ghcask-url-reinstall-") do |dir|
        asset = GitHub::Asset.new(name: DirectUrl.asset_name(url), url: url)
        asset_path = @package.download(asset, destination_dir: dir, stdout: @stdout)
        sha = @package.sha256(asset_path)
        app = @package.infer_app(asset_path, app_override: options[:app])
        homepage = DirectUrl.homepage(url)
        updated = entry.merge(
          "name" => options[:name] || app.name || entry["name"],
          "app" => app.app || entry["app"],
          "arch" => options[:arch] || entry["arch"],
          "version" => options[:version] || app.version || DirectUrl.version_from_filename(asset.name) || "latest",
          "asset_name" => asset.name,
          "asset_url" => asset.url,
          "homepage" => homepage,
          "sha256" => sha,
          "updated_at" => Time.now.utc.iso8601
        )
        print_reinstall_url_plan(updated)
        return 0 if options[:dry_run]

        data["casks"][name] = updated
        Cask.write(cask_path(name), updated)
        @tap.registry.save(data)
        @homebrew_cache.cache_cask(name, asset_path)
      end

      command = reinstall_command(name, force: options[:force])
      @stdout.puts "Running: #{command.join(" ")}"
      run_homebrew(command, error_prefix: "Homebrew reinstall failed")
      @stdout.puts "Homebrew finished reinstall for #{name}."
      0
    end

    def reinstall_github_release(data, name, entry, requested_version, release_policy, options)
      raise Error, "GitHub release selection is only supported for GitHub casks. Use `brew ghcask reinstall #{name} --url NEW_URL` for direct URL casks." if url_source?(entry)

      release = @github.select_release(entry.fetch("repo"), policy: release_policy, requested_version: requested_version)
      arch = options[:arch] || entry["arch"] || AssetSelector.local_arch
      asset = AssetSelector.new(release.assets, arch: arch).select(pattern: entry["asset_pattern"])

      if options[:dry_run]
        preview = entry.merge(
          "release_policy" => release_policy,
          "requested_version" => requested_version,
          "arch" => arch,
          "version" => release.tag_name.to_s.sub(/\Av/i, ""),
          "release_tag" => release.tag_name,
          "asset_name" => asset.name,
          "asset_url" => asset.url,
          "sha256" => "(will calculate during reinstall)"
        )
        print_reinstall_github_plan(name, preview)
        @stdout.puts "Would run: #{reinstall_command(name, force: options[:force]).join(" ")}"
        return 0
      end

      Dir.mktmpdir("ghcask-reinstall-") do |dir|
        asset_path = @package.download(asset, destination_dir: dir, stdout: @stdout)
        sha = @package.sha256(asset_path)
        app = @package.infer_app(asset_path, app_override: options[:app] || entry["app"])
        refreshed = entry.merge(
          "name" => options[:name] || app.name || entry["name"],
          "app" => app.app || entry["app"],
          "release_policy" => release_policy,
          "requested_version" => requested_version,
          "arch" => arch,
          "version" => release.tag_name.to_s.sub(/\Av/i, ""),
          "release_tag" => release.tag_name,
          "asset_name" => asset.name,
          "asset_url" => asset.url,
          "sha256" => sha,
          "updated_at" => Time.now.utc.iso8601
        )
        data["casks"][name] = refreshed
        Cask.write(cask_path(name), refreshed)
        @tap.registry.save(data)
        @homebrew_cache.cache_cask(name, asset_path)
        print_reinstall_github_plan(name, refreshed)
      end

      command = reinstall_command(name, force: options[:force])
      @stdout.puts "Running: #{command.join(" ")}"
      run_homebrew(command, error_prefix: "Homebrew reinstall failed")
      @stdout.puts "Homebrew finished reinstall for #{name}."
      0
    end

    def resolve_managed_cask(data, target)
      entry = data["casks"][target]
      return [target, entry] if entry

      repo = normalize_repo_target(target)
      if repo
        match = data["casks"].find { |_name, candidate| candidate["repo"] == repo }
        return match if match
      end

      raise Error, "managed cask not found: #{target}"
    end

    def source_type(entry)
      entry.fetch("source_type")
    end

    def url_source?(entry)
      source_type(entry) == "url"
    end

    def normalize_repo_target(target)
      RepoRef.normalize(target)
    rescue RepoRef::Error
      nil
    end

    def parse_repo_target(target)
      RepoRef.parse(target)
    rescue RepoRef::Error
      nil
    end

    def cleanup_candidates(data)
      local_casks = local_cask_names
      installed_casks = installed_homebrew_casks
      data["casks"].each_with_object([]) do |(name, entry), candidates|
        if !local_casks.include?(name)
          candidates << [name, "registry entry for deleted cask file"]
        elsif entry["install_state"] != "generated" && installed_casks && !installed_casks.include?(name)
          candidates << [name, "managed cask uninstalled by Homebrew"]
        end
      end
    end

    def local_cask_names
      Dir.glob(File.join(@tap.casks_dir, "*.rb")).map { |path| File.basename(path, ".rb") }.to_set
    end

    def installed_homebrew_casks
      result = @runner.capture(["brew", "list", "--cask"])
      return nil unless result.success?

      result.stdout.lines.map(&:strip).reject(&:empty?).to_set
    end

    def installed_homebrew_versions(names)
      return {} if names.empty?

      tokens = names.map { |name| "ghcask/local/#{name}" }
      result = @runner.capture(["brew", "info", "--cask", "--json=v2", *tokens])
      return {} unless result.success?

      casks = JSON.parse(result.stdout).fetch("casks", [])
      casks.each_with_object({}) do |cask, versions|
        tokens = [cask["full_token"], cask["token"]].compact.map(&:to_s)
        name = names.find { |candidate| tokens.any? { |token| token == candidate || token.end_with?("/#{candidate}") } }
        installed = cask["installed"]
        installed = installed.last if installed.is_a?(Array)
        installed = installed.to_s
        versions[name] = installed if name && !installed.empty?
      end
    rescue JSON::ParserError, KeyError
      {}
    end

    def cask_path(name)
      File.join(@tap.casks_dir, "#{name}.rb")
    end

    def upgrade_casks(data, names)
      installed_versions = installed_homebrew_versions(names)
      names.each do |name|
        installed_version = installed_versions[name]
        if installed_version && installed_version.sub(/\Av/i, "") == data["casks"].fetch(name)["version"].to_s.sub(/\Av/i, "")
          next
        end

        upgrade_cask(name)
      end
    end

    def upgrade_cask(name)
      command = ["brew", "upgrade", "--cask", "ghcask/local/#{name}"]
      @stdout.puts "Running: #{command.join(" ")}"
      run_homebrew(command, error_prefix: "Homebrew upgrade failed")
    end

    def reinstall_command(name, force:)
      command = ["brew", "reinstall", "--cask"]
      command << "--force" if force
      command << "ghcask/local/#{name}"
      command
    end

    def uninstall_cask(name)
      command = ["brew", "uninstall", "--cask", "ghcask/local/#{name}"]
      @stdout.puts "Running: #{command.join(" ")}"
      run_homebrew(command, error_prefix: "Homebrew uninstall failed", warn_only_if: :not_installed)
    end

    def run_homebrew(command, error_prefix:, warn_only_if: nil)
      result = @runner.capture(command)
      @stdout.print result.stdout unless result.stdout.empty?
      @stderr.print result.stderr unless result.stderr.empty?
      return if result.success?

      message = homebrew_error_summary(result.stderr.strip.empty? ? result.stdout : result.stderr)
      if warn_only_if == :not_installed && homebrew_not_installed?(message)
        @stderr.puts "Warning: #{message}. Removing ghcask metadata anyway."
        return
      end

      raise Error, "#{error_prefix}: #{message}"
    end

    def homebrew_not_installed?(message)
      message.match?(/not installed|not currently installed|no such cask/i)
    end

    def homebrew_error_summary(text)
      lines = text.lines.map(&:strip).reject(&:empty?)
      lines.find { |line| line.start_with?("Error:") } ||
        lines.reverse.find { |line| line.match?(/\berror:/i) } ||
        lines.last ||
        "command failed"
    end

    def print_homebrew_install_info(name)
      result = @runner.capture(["brew", "info", "--cask", "--json=v2", "ghcask/local/#{name}"])
      unless result.success?
        @stdout.puts "Installed: unknown"
        return
      end

      cask = JSON.parse(result.stdout).fetch("casks", []).first
      unless cask
        @stdout.puts "Installed: unknown"
        return
      end

      installed = cask["installed"]
      if installed && !installed.to_s.empty?
        @stdout.puts "Installed: yes"
        @stdout.puts "Installed version: #{installed}"
        installed_paths(cask).each { |path| @stdout.puts "Installed path: #{path}" }
      else
        @stdout.puts "Installed: no"
      end
    rescue JSON::ParserError, KeyError
      @stdout.puts "Installed: unknown"
    end

    def print_reinstall_url_plan(entry)
      @stdout.puts "Source: direct URL"
      @stdout.puts "URL: #{entry.fetch("asset_url")}"
      @stdout.puts "Asset: #{entry.fetch("asset_name")}"
      @stdout.puts "Cask: #{entry.fetch("cask")}"
      @stdout.puts "Version: #{entry.fetch("version")}"
      @stdout.puts "sha256: #{entry.fetch("sha256")}"
    end

    def print_reinstall_github_plan(name, entry)
      @stdout.puts "Source: GitHub"
      @stdout.puts "Repository: #{entry.fetch("repo")}"
      @stdout.puts "Release policy: #{entry.fetch("release_policy")}"
      @stdout.puts "Requested version: #{entry.fetch("requested_version")}"
      @stdout.puts "Release: #{entry.fetch("release_tag")}"
      @stdout.puts "Version: #{entry.fetch("version")}"
      @stdout.puts "Asset: #{entry.fetch("asset_name")}"
      @stdout.puts "Asset URL: #{entry.fetch("asset_url")}"
      @stdout.puts "Architecture: #{entry["arch"] || "(not set)"}"
      @stdout.puts "Cask: #{name}"
      @stdout.puts "Cask path: #{cask_path(name)}"
      @stdout.puts "Name: #{entry.fetch("name")}"
      @stdout.puts "App: #{entry.fetch("app")}"
      @stdout.puts "sha256: #{entry.fetch("sha256")}"
    end

    def installed_paths(cask)
      Array(cask["artifacts"]).flat_map do |artifact|
        if artifact.is_a?(Hash)
          direct_target = artifact["target"]
          artifact.values.flat_map do |value|
            if value.is_a?(Hash)
              value["target"]
            elsif value.is_a?(Array)
              value.last.is_a?(Hash) ? value.last["target"] : nil
            end
          end + [direct_target]
        end
      end.compact
    end
  end
end

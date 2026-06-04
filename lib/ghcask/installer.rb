# frozen_string_literal: true

require "fileutils"
require "open3"
require "optparse"
require "time"
require "tmpdir"

require "ghcask/asset_selector"
require "ghcask/cask"
require "ghcask/direct_url"
require "ghcask/github"
require "ghcask/homebrew"
require "ghcask/local_tap"
require "ghcask/package"
require "ghcask/repo_ref"

module Ghcask
  class Installer
    class Error < StandardError; end

    Options = Struct.new(
      :asset_pattern,
      :app,
      :cask,
      :name,
      :prerelease,
      :version,
      :arch,
      :url,
      :dry_run,
      :no_install,
      :trust,
      keyword_init: true
    )

    def initialize(argv, stdout:, stderr:, github: GitHub::Client.new, tap: LocalTap.new, package: Package, runner: CommandRunner.new)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @github = github
      @tap = tap
      @package = package
      @runner = runner
      @homebrew_cache = Homebrew::Cache.new(runner: runner, stdout: stdout, stderr: stderr)
    end

    def run
      repo_input, options = parse
      return 0 if repo_input == :help
      return install_url(repo_input, options) if options.url

      repo_ref = RepoRef.parse(repo_input)
      repo = repo_ref.repo
      options.version ||= repo_ref.version
      @tap.init unless options.dry_run
      existing = reusable_existing_entry(repo, options)
      if existing
        print_reuse_plan(existing, options: options)
        install_cask(existing.fetch("cask")) unless options.dry_run || options.no_install
        mark_installed(existing.fetch("cask")) unless options.dry_run || options.no_install
        @stdout.puts existing_install_message(existing, options)
        return 0
      end

      release_policy = options.prerelease ? "latest-prerelease" : "latest-stable"
      release = @github.select_release(repo, policy: release_policy, requested_version: options.version)
      asset = AssetSelector.new(release.assets, arch: options.arch || AssetSelector.local_arch).select(pattern: options.asset_pattern)
      cask_name = Cask.normalize_name(options.cask || options.app || repo.split("/").last)
      raise Error, "Could not infer cask name. Re-run with --cask CASK." if cask_name.empty?

      cask_path = File.join(@tap.casks_dir, "#{cask_name}.rb")

      if options.dry_run
        print_plan(
          repo,
          release,
          asset,
          cask_name,
          cask_path,
          sha: "(will calculate during install)",
          options: options,
          release_policy: release_policy,
          app: options.app || "(will infer during install)",
          display_name: options.name || release.name || cask_name
        )
        return 0
      end

      entry = nil
      Dir.mktmpdir("ghcask-install-") do |dir|
        asset_path = @package.download(asset, destination_dir: dir, stdout: @stdout)
        sha = @package.sha256(asset_path)
        app = @package.infer_app(asset_path, app_override: options.app)
        cask_name = Cask.normalize_name(options.cask || app.app || repo.split("/").last)
        cask_path = File.join(@tap.casks_dir, "#{cask_name}.rb")
        display_name = options.name || app.name || release.name || cask_name
        entry = registry_entry(
          repo: repo,
          cask_name: cask_name,
          display_name: display_name,
          app: app.app,
          release: release,
          asset: asset,
          sha: sha,
          options: options,
          release_policy: release_policy
        )
        Cask.write(cask_path, entry) { trust_cask(cask_name) if options.trust }
        save_registry(cask_name, entry)
        print_plan(
          repo,
          release,
          asset,
          cask_name,
          cask_path,
          sha: sha,
          options: options,
          release_policy: release_policy,
          app: app.app,
          display_name: display_name
        )
        @homebrew_cache.cache_cask(cask_name, asset_path) unless options.no_install
      end

      install_cask(cask_name) unless options.no_install
      mark_installed(cask_name) unless options.no_install
      @stdout.puts options.no_install ? "Generated local cask without installing." : "Homebrew finished install for #{cask_name}."
      0
    rescue OptionParser::ParseError, Error, DirectUrl::Error, RepoRef::Error, GitHub::Error, AssetSelector::Error, Package::Error, Registry::Error, Homebrew::Error => e
      @stderr.puts "ghcask install: #{e.message}"
      1
    end

    private

    def parse
      options = Options.new(prerelease: false, dry_run: false, no_install: false, trust: false)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: brew ghcask install owner/repo [options]"
        opts.on("--url URL", "Install directly from a package URL") { |value| options.url = value }
        opts.on("--asset PATTERN", "Select release asset by glob pattern") { |value| options.asset_pattern = value }
        opts.on("--app NAME", "Set .app bundle name explicitly") { |value| options.app = value }
        opts.on("--cask CASK", "Set generated cask name") { |value| options.cask = value }
        opts.on("--name NAME", "Set display name") { |value| options.name = value }
        opts.on("--prerelease", "Allow prerelease releases") { options.prerelease = true }
        opts.on("--version VERSION", "Install a specific release tag or version") { |value| options.version = value }
        opts.on("--arch ARCH", "Override local architecture") { |value| options.arch = value }
        opts.on("--dry-run", "Show the plan without writing files or installing") { options.dry_run = true }
        opts.on("--no-install", "Generate the local cask without installing") { options.no_install = true }
        opts.on("--trust", "Trust the generated local cask after writing it") { options.trust = true }
        opts.on("-h", "--help", "Show help") do
          @stdout.puts opts
          return [:help, options]
        end
      end
      parser.parse!(@argv)
      [@argv.shift, options]
    end

    def install_url(cask_input, options)
      cask_name = Cask.normalize_name(cask_input)
      raise Error, "Direct URL installs require an explicit cask name. Use `brew ghcask install cask-name --url URL`." if cask_name.empty?
      if cask_input.to_s.include?("/") || cask_input.to_s.start_with?("http://", "https://")
        raise Error, "Direct URL cask name must not look like a GitHub repository. Use `brew ghcask install cask-name --url URL`."
      end
      raise Error, "--cask is only available for GitHub source installs. Direct URL installs use the positional cask name." if options.cask
      raise Error, "--asset is only available for GitHub source installs." if options.asset_pattern
      raise Error, "--prerelease is only available for GitHub source installs." if options.prerelease

      url = DirectUrl.package_url(options.url)
      @tap.init unless options.dry_run
      existing = reusable_existing_url_entry(cask_name, options)
      if existing
        print_reuse_url_plan(existing, options: options)
        install_cask(existing.fetch("cask")) unless options.dry_run || options.no_install
        mark_installed(existing.fetch("cask")) unless options.dry_run || options.no_install
        @stdout.puts existing_url_install_message(existing, options)
        return 0
      end

      cask_path = File.join(@tap.casks_dir, "#{cask_name}.rb")
      entry = nil
      Dir.mktmpdir("ghcask-url-install-") do |dir|
        asset = GitHub::Asset.new(name: DirectUrl.asset_name(url), url: url)
        asset_path = @package.download(asset, destination_dir: dir, stdout: @stdout)
        sha = @package.sha256(asset_path)
        app = @package.infer_app(asset_path, app_override: options.app)
        display_name = options.name || app.name || Cask.normalize_name(cask_name)
        entry = url_registry_entry(
          cask_name: cask_name,
          display_name: display_name,
          app: app.app,
          asset: asset,
          sha: sha,
          options: options,
          app_version: app.version
        )
        print_url_plan(entry, cask_path, options: options)
        unless options.dry_run
          Cask.write(cask_path, entry) { trust_cask(cask_name) if options.trust }
          save_registry(cask_name, entry)
          @homebrew_cache.cache_cask(cask_name, asset_path) unless options.no_install
        end
      end

      install_cask(cask_name) unless options.dry_run || options.no_install
      mark_installed(cask_name) unless options.dry_run || options.no_install
      @stdout.puts options.no_install ? "Generated local cask without installing." : "Homebrew finished install for #{cask_name}." unless options.dry_run
      0
    end

    def reusable_existing_entry(repo, options)
      return nil unless reusable_install_options?(options)

      data = @tap.registry.load
      entry = data["casks"].values.find { |candidate| candidate["repo"] == repo }
      return nil unless entry
      return nil unless File.exist?(File.join(@tap.casks_dir, "#{entry.fetch("cask")}.rb"))

      entry
    rescue Registry::Error
      nil
    end

    def reusable_existing_url_entry(cask_name, options)
      return nil unless reusable_install_options?(options)

      data = @tap.registry.load
      entry = data["casks"][cask_name]
      return nil unless entry && entry["source_type"] == "url"
      return nil unless File.exist?(File.join(@tap.casks_dir, "#{entry.fetch("cask")}.rb"))

      entry
    rescue Registry::Error
      nil
    end

    def reusable_install_options?(options)
      !options.asset_pattern &&
        !options.app &&
        !options.cask &&
        !options.name &&
        !options.prerelease &&
        !options.version &&
        !options.arch
    end

    def registry_entry(repo:, cask_name:, display_name:, app:, release:, asset:, sha:, options:, release_policy:)
      {
        "repo" => repo,
        "source_type" => "github",
        "cask" => cask_name,
        "name" => display_name,
        "app" => app,
        "release_policy" => release_policy,
        "requested_version" => options.version,
        "asset_pattern" => options.asset_pattern,
        "arch" => options.arch || AssetSelector.local_arch,
        "version" => release.tag_name.to_s.sub(/\Av/i, ""),
        "release_tag" => release.tag_name,
        "asset_name" => asset.name,
        "asset_url" => asset.url,
        "sha256" => sha,
        "install_state" => options.no_install ? "generated" : "pending-install",
        "updated_at" => Time.now.utc.iso8601
      }
    end

    def url_registry_entry(cask_name:, display_name:, app:, asset:, sha:, options:, app_version:)
      homepage = DirectUrl.homepage(asset.url)
      {
        "repo" => nil,
        "source_type" => "url",
        "cask" => cask_name,
        "name" => display_name,
        "app" => app,
        "release_policy" => "url",
        "requested_version" => nil,
        "asset_pattern" => nil,
        "arch" => options.arch,
        "version" => options.version || app_version || DirectUrl.version_from_filename(asset.name) || "latest",
        "release_tag" => nil,
        "asset_name" => asset.name,
        "asset_url" => asset.url,
        "homepage" => homepage,
        "sha256" => sha,
        "install_state" => options.no_install ? "generated" : "pending-install",
        "updated_at" => Time.now.utc.iso8601
      }
    end

    def save_registry(cask_name, entry)
      data = @tap.registry.ensure_exists
      data["casks"][cask_name] = entry
      @tap.registry.save(data)
    end

    def mark_installed(cask_name)
      data = @tap.registry.ensure_exists
      data["casks"].fetch(cask_name)["install_state"] = "installed"
      @tap.registry.save(data)
    end

    def print_plan(repo, release, asset, cask_name, cask_path, sha:, options:, release_policy:, app:, display_name:)
      @stdout.puts "Source: GitHub"
      @stdout.puts "Repository: #{repo}"
      @stdout.puts "Release policy: #{release_policy}"
      @stdout.puts "Requested version: #{options.version}" if options.version
      @stdout.puts "Release: #{release.tag_name}"
      @stdout.puts "Version: #{release.tag_name.to_s.sub(/\Av/i, "")}"
      @stdout.puts "Asset: #{asset.name}"
      @stdout.puts "Asset URL: #{asset.url}"
      @stdout.puts "Architecture: #{options.arch || AssetSelector.local_arch}"
      @stdout.puts "Cask: #{cask_name}"
      @stdout.puts "Cask path: #{cask_path}"
      @stdout.puts "Name: #{display_name}"
      @stdout.puts "App: #{app}"
      @stdout.puts "sha256: #{sha}"
      print_install_dry_run_actions(cask_name, options, existing: false)
    end

    def print_url_plan(entry, cask_path, options:)
      @stdout.puts "Source: direct URL"
      @stdout.puts "URL: #{entry.fetch("asset_url")}"
      @stdout.puts "Asset: #{entry.fetch("asset_name")}"
      @stdout.puts "Cask: #{entry.fetch("cask")}"
      @stdout.puts "Cask path: #{cask_path}"
      @stdout.puts "Name: #{entry.fetch("name")}"
      @stdout.puts "App: #{entry.fetch("app")}"
      @stdout.puts "Version: #{entry.fetch("version")}"
      @stdout.puts "Architecture: #{entry["arch"] || "(not set)"}"
      @stdout.puts "Homepage: #{entry.fetch("homepage")}"
      @stdout.puts "sha256: #{entry.fetch("sha256")}"
      print_install_dry_run_actions(entry.fetch("cask"), options, existing: false)
    end

    def print_install_dry_run_actions(cask_name, options, existing:)
      return unless options.dry_run

      install = !options.no_install
      writes_local_state = !existing
      @stdout.puts "Would use existing local cask: #{existing ? "yes" : "no"}"
      @stdout.puts "Would write cask: #{writes_local_state ? "yes" : "no"}"
      @stdout.puts "Would update registry: #{writes_local_state ? "yes" : "no"}"
      @stdout.puts "Would trust cask: #{!existing && options.trust ? "yes" : "no"}"
      @stdout.puts "Would cache package for Homebrew: #{writes_local_state && install ? "yes" : "no"}"
      @stdout.puts "Would install with Homebrew: #{install ? "yes" : "no"}"
      @stdout.puts "Would run: brew install --cask ghcask/local/#{cask_name}" if install
    end

    def print_reuse_plan(entry, options:)
      @stdout.puts "Source: GitHub"
      @stdout.puts "Repository: #{entry.fetch("repo")}"
      @stdout.puts "Release policy: #{entry.fetch("release_policy")}"
      @stdout.puts "Release: #{entry.fetch("release_tag")}"
      @stdout.puts "Version: #{entry.fetch("version")}"
      @stdout.puts "Asset: #{entry.fetch("asset_name")}"
      @stdout.puts "Asset URL: #{entry.fetch("asset_url")}"
      @stdout.puts "Architecture: #{entry["arch"] || "(not set)"}"
      @stdout.puts "Cask: #{entry.fetch("cask")}"
      @stdout.puts "Cask path: #{File.join(@tap.casks_dir, "#{entry.fetch("cask")}.rb")}"
      @stdout.puts "Name: #{entry.fetch("name")}"
      @stdout.puts "App: #{entry.fetch("app")}"
      @stdout.puts "sha256: #{entry.fetch("sha256")}"
      @stdout.puts "Using existing local cask."
      @stdout.puts "Skipping GitHub lookup."
      print_install_dry_run_actions(entry.fetch("cask"), options, existing: true)
    end

    def print_reuse_url_plan(entry, options:)
      @stdout.puts "Source: direct URL"
      @stdout.puts "URL: #{entry.fetch("asset_url")}"
      @stdout.puts "Asset: #{entry.fetch("asset_name")}"
      @stdout.puts "Cask: #{entry.fetch("cask")}"
      @stdout.puts "Cask path: #{File.join(@tap.casks_dir, "#{entry.fetch("cask")}.rb")}"
      @stdout.puts "Name: #{entry.fetch("name")}"
      @stdout.puts "App: #{entry.fetch("app")}"
      @stdout.puts "Version: #{entry.fetch("version")}"
      @stdout.puts "Architecture: #{entry["arch"] || "(not set)"}"
      @stdout.puts "Homepage: #{entry.fetch("homepage")}"
      @stdout.puts "sha256: #{entry.fetch("sha256")}"
      @stdout.puts "Using existing local cask."
      @stdout.puts "Skipping direct URL download."
      print_install_dry_run_actions(entry.fetch("cask"), options, existing: true)
    end

    def existing_install_message(entry, options)
      if options.dry_run
        "Would use existing local cask without contacting GitHub."
      elsif options.no_install
        "Using existing local cask without installing."
      else
        "Homebrew finished install for #{entry.fetch("cask")}."
      end
    end

    def existing_url_install_message(entry, options)
      if options.dry_run
        "Would use existing local cask without downloading the direct URL."
      elsif options.no_install
        "Using existing local cask without installing."
      else
        "Homebrew finished install for #{entry.fetch("cask")}."
      end
    end

    def install_cask(cask_name)
      command = ["brew", "install", "--cask", "ghcask/local/#{cask_name}"]
      @stdout.puts "Running: #{command.join(" ")}"
      result = @runner.capture(command)
      @stdout.print result.stdout unless result.stdout.empty?
      @stderr.print result.stderr unless result.stderr.empty?
      return if result.success?

      message = result.stderr.strip.empty? ? result.stdout.strip : result.stderr.strip
      raise Error, "Homebrew install failed: #{message}. Inspect with `brew cat --cask ghcask/local/#{cask_name}`."
    end

    def trust_cask(cask_name)
      command = ["brew", "trust", "--cask", "ghcask/local/#{cask_name}"]
      @stdout.puts "Running: #{command.join(" ")}"
      result = @runner.capture(command)
      @stdout.print result.stdout unless result.stdout.empty?
      @stderr.print result.stderr unless result.stderr.empty?
      return if result.success?

      message = result.stderr.strip.empty? ? result.stdout.strip : result.stderr.strip
      raise Error, "Homebrew trust failed: #{message}. Try `brew trust --cask ghcask/local/#{cask_name}` manually."
    end

  end

  class CommandRunner
    Result = Struct.new(:stdout, :stderr, :status, keyword_init: true) do
      def success?
        status.success?
      end
    end

    def capture(command)
      stdout, stderr, status = Open3.capture3(*command)
      Result.new(stdout: stdout, stderr: stderr, status: status)
    rescue Errno::ENOENT => e
      Result.new(stdout: "", stderr: e.message, status: FailureStatus.new)
    end
  end

  class FailureStatus
    def success?
      false
    end
  end
end

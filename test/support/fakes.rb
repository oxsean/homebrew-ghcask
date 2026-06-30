# frozen_string_literal: true

require "ghcask"

module GhcaskTest
  # Records every command and replays canned results matched by argv prefix.
  class FakeRunner
    Result = Struct.new(:stdout, :stderr, :ok) do
      def success?
        ok
      end
    end

    attr_reader :commands

    def initialize
      @commands = []
      @rules = []
      @executables = Hash.new(true)
    end

    # Match a command by leading tokens, e.g. on("brew", "info", stdout: "...").
    def on(*prefix, stdout: "", stderr: "", ok: true)
      @rules << [prefix, Result.new(stdout, stderr, ok)]
      self
    end

    def executable(name, present: true)
      @executables[name] = present
      self
    end

    def capture(command)
      @commands << command
      rule = @rules.reverse.find { |prefix, _| command[0, prefix.size] == prefix }
      rule ? rule[1] : Result.new("", "", true)
    end

    def executable?(name)
      @executables.fetch(name, true)
    end

    def which(name)
      executable?(name) ? "/usr/bin/#{name}" : nil
    end
  end

  # Returns a fixed Release (or a repo => Release/Exception map) and records calls.
  class FakeGitHub
    attr_reader :requests, :downloads

    attr_reader :auth_token

    def initialize(release, auth_token: nil, repo_description: nil, repos: [])
      @release = release
      @auth_token = auth_token
      @repo_description = repo_description
      @repos = repos
      @requests = []
      @downloads = []
    end

    def repo_description(_repo)
      @repo_description
    end

    def search_repos(_query, limit: 20)
      @repos.first(limit)
    end

    def select_release(repo, policy:, requested_version: nil)
      @requests << { repo: repo, policy: policy, requested_version: requested_version }
      result = @release.is_a?(Hash) ? @release.fetch(repo) : @release
      raise result if result.is_a?(Exception)

      result
    end

    def download(repo:, tag:, asset:, destination_dir:, stdout: nil)
      @downloads << { repo: repo, tag: tag, asset: asset }
      path = File.join(destination_dir, File.basename(asset.name.to_s))
      File.write(path, "github-package")
      path
    end
  end

  class ExplodingGitHub
    def select_release(*)
      raise "GitHub should not have been contacted"
    end
  end

  # Stands in for the Package module; writes a placeholder file on download.
  class FakePackage
    attr_reader :downloads

    attr_reader :download_headers

    def initialize(sha: "fakesha", app: "App.app", name: nil, version: nil, pkg_id: nil, binary: nil, command: nil, bundle_id: nil, extras: nil)
      @sha = sha
      @app = app
      @name = name
      @version = version
      @pkg_id = pkg_id
      @binary = binary
      @command = command
      @bundle_id = bundle_id
      @extras = extras
      @downloads = []
      @download_headers = []
    end

    def download(asset, destination_dir:, stdout: nil, headers: [])
      @downloads << asset
      @download_headers << headers
      path = File.join(destination_dir, File.basename(asset.name.to_s))
      File.write(path, "package-bytes")
      path
    end

    def sha256(_path)
      @sha
    end

    def infer_app(_path, app_override: nil)
      return Ghcask::Package::AppMetadata.new(binary: @binary, command: @command, name: @name, extras: @extras) if @binary

      app = app_override || @app
      Ghcask::Package::AppMetadata.new(
        app: app,
        name: @name || (app && app.sub(/\.app\z/i, "")),
        version: @version,
        pkg_id: @pkg_id,
        bundle_id: @bundle_id
      )
    end
  end

  # High-level brew double so command tests assert on actions, not argv strings.
  class FakeBrew
    attr_reader :installs, :reinstalls, :upgrades, :uninstalls, :trusts, :cached

    def initialize(installed_versions: {}, app_paths: {}, info: {}, installed_casks: nil, uninstall_result: :ok, install_error: nil, cached_urls: {})
      @installed_versions = installed_versions
      @app_paths = app_paths
      @info = info
      @installed_casks = installed_casks
      @uninstall_result = uninstall_result
      @install_error = install_error
      @cached_urls = cached_urls
      @installs = []
      @reinstalls = []
      @upgrades = []
      @uninstalls = []
      @trusts = []
      @cached = []
    end

    def token(name)
      "ghcask/local/#{name}"
    end

    def install(name, force: false, quarantine: true, extra: [])
      @installs << call_record(name, force, quarantine, extra)
      raise @install_error if @install_error

      :ok
    end

    def reinstall(name, force: false, quarantine: true, extra: [])
      @reinstalls << call_record(name, force, quarantine, extra)
      :ok
    end

    # Only record :extra when present, so assertions that don't care stay clean.
    def call_record(name, force, quarantine, extra)
      record = { name: name, force: force, quarantine: quarantine }
      record[:extra] = extra unless extra.empty?
      record
    end

    def upgrade(name, force: false, extra: [])
      record = { name: name }
      record[:force] = force if force
      record[:extra] = extra unless extra.empty?
      @upgrades << record
      :ok
    end

    def uninstall(name, force: false, zap: false, extra: [])
      record = { name: name, force: force }
      record[:zap] = zap if zap
      record[:extra] = extra unless extra.empty?
      @uninstalls << record
      @uninstall_result
    end

    def trust(name)
      @trusts << name
      :ok
    end

    def plan(name, action:, force: false, quarantine: true, extra: [])
      command = ["brew", action.to_s, "--cask"]
      command << "--force" if force
      command << "--no-quarantine" unless quarantine
      command.concat(extra)
      command << token(name)
      command
    end

    def cache_package(name, asset_path)
      @cached << { name: name, existed: File.exist?(asset_path) }
      "/cache/#{name}"
    end

    def cached_download_for_url(url)
      @cached_urls[url]
    end

    def info(name)
      @info[name]
    end

    def installed_app_paths(name)
      @app_paths.fetch(name, [])
    end

    def installed_versions(names)
      names.each_with_object({}) do |name, out|
        version = @installed_versions[name]
        out[name] = version if version
      end
    end

    def installed_casks
      @installed_casks
    end
  end

  class FakeQuarantine
    attr_reader :released, :warned

    def initialize(error: nil)
      @released = []
      @warned = []
      @error = error
    end

    def release(paths)
      @released << paths
      raise @error if @error

      paths
    end

    def warn_if_blocked(paths)
      @warned << paths
    end
  end
end

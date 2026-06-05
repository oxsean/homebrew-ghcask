# frozen_string_literal: true

require "test_helper"
require "tmpdir"

require "ghcask/manager"

class ManagerTest < Minitest::Test
  FakeResult = Struct.new(:stdout, :stderr, :ok, keyword_init: true) do
    def success?
      ok
    end
  end

  class FakeGitHub
    attr_reader :requests

    def initialize(releases)
      @releases = releases
      @requests = []
    end

    def select_release(repo, policy:, requested_version:)
      @requests << [repo, policy, requested_version]
      @releases.fetch(repo)
    end
  end

  class ExplodingGitHub
    def select_release(*)
      raise "GitHub should not be called"
    end
  end

  class FakeRunner
    attr_reader :commands

    def initialize(ok: true, stdout: "", stderr: "")
      @ok = ok
      @stdout = stdout
      @stderr = stderr
      @commands = []
    end

    def capture(command)
      @commands << command
      if @stdout.is_a?(Hash)
        response = @stdout.fetch(command.join(" "))
        return FakeResult.new(stdout: response.fetch(:stdout, ""), stderr: response.fetch(:stderr, ""), ok: response.fetch(:ok, true))
      end

      FakeResult.new(stdout: @stdout, stderr: @ok ? @stderr : (@stderr.empty? ? "failed" : @stderr), ok: @ok)
    end
  end

  class FakePackage
    attr_reader :downloads

    def initialize(sha: "newsha", content: "downloaded asset", app: "Example.app", version: nil)
      @sha = sha
      @content = content
      @app = app
      @version = version
      @downloads = []
    end

    def download(asset, destination_dir:, stdout: nil)
      stdout&.puts "==> Downloading #{asset.url}"
      @downloads << [asset, destination_dir]
      path = File.join(destination_dir, asset.name)
      File.write(path, @content)
      path
    end

    def sha256(_path)
      @sha
    end

    def infer_app(_path, app_override: nil)
      app = app_override || @app
      Ghcask::Package::AppMetadata.new(app: app, name: app.sub(/\.app\z/, ""), version: @version)
    end
  end

  def asset(name = "Example-arm64.dmg")
    Ghcask::GitHub::Asset.new(name: name, url: "https://example.test/#{name}")
  end

  def release(tag, asset_name: "Example-arm64.dmg")
    Ghcask::GitHub::Release.new(
      tag_name: tag,
      name: "Example",
      draft: false,
      prerelease: false,
      published_at: Time.parse("2026-01-01T00:00:00Z"),
      assets: [asset(asset_name)]
    )
  end

  def homebrew_info_json(*entries)
    JSON.dump(
      "casks" => entries.map do |name, installed|
        {
          "token" => name,
          "full_token" => "ghcask/local/#{name}",
          "installed" => installed
        }
      end
    )
  end

  def with_tap(entry)
    Dir.mktmpdir do |homebrew|
      tap = Ghcask::LocalTap.new(homebrew_repository: homebrew)
      tap.init
      tap.registry.save("version" => 1, "casks" => { entry.fetch("cask") => entry })
      Ghcask::Cask.write(File.join(tap.casks_dir, "#{entry.fetch("cask")}.rb"), entry)
      yield tap
    end
  end

  def entry(cask: "example", tag: "v1.0.0", policy: "latest-stable", requested_version: nil)
    {
      "repo" => "owner/repo",
      "source_type" => "github",
      "cask" => cask,
      "name" => "Example",
      "app" => "Example.app",
      "release_policy" => policy,
      "requested_version" => requested_version,
      "asset_pattern" => nil,
      "arch" => "arm64",
      "version" => tag.sub(/\Av/i, ""),
      "release_tag" => tag,
      "asset_name" => "Example-arm64.dmg",
      "asset_url" => "https://example.test/Example-arm64.dmg",
      "sha256" => "abc123",
      "install_state" => "installed",
      "updated_at" => "2026-01-01T00:00:00Z"
    }
  end

  def run_manager(argv, tap:, github:, runner: FakeRunner.new, package: FakePackage.new, command: :update, upgrade: true)
    stdout = StringIO.new
    stderr = StringIO.new
    manager = Ghcask::Manager.new(argv, stdout: stdout, stderr: stderr, github: github, tap: tap, runner: runner, package: package)
    status = command == :update ? manager.update(upgrade: upgrade) : manager.public_send(command)
    [status, stdout.string, stderr.string, runner]
  end

  def url_entry(cask: "example")
    {
      "repo" => nil,
      "source_type" => "url",
      "cask" => cask,
      "name" => "Example",
      "app" => "Example.app",
      "release_policy" => "url",
      "requested_version" => nil,
      "asset_pattern" => nil,
      "arch" => nil,
      "version" => "1.0.0",
      "release_tag" => nil,
      "asset_name" => "Example-1.0.0.dmg",
      "asset_url" => "https://downloads.example.test/Example-1.0.0.dmg",
      "homepage" => "https://downloads.example.test",
      "sha256" => "abc123",
      "install_state" => "installed",
      "updated_at" => "2026-01-01T00:00:00Z"
    }
  end

  def test_upgrade_refreshes_changed_release_and_runs_homebrew_upgrade
    Dir.mktmpdir do |tmp|
      with_tap(entry) do |tap|
        github = FakeGitHub.new("owner/repo" => release("v1.1.0"))
        cache_path = File.join(tmp, "downloads", "example-cache.dmg")
        runner = FakeRunner.new(stdout: {
          "brew --cache --cask ghcask/local/example" => { stdout: "#{cache_path}\n" },
          "brew info --cask --json=v2 ghcask/local/example" => { stdout: homebrew_info_json(["example", "1.0.0"]) },
          "brew upgrade --cask ghcask/local/example" => {}
        })
        package = FakePackage.new(content: "updated asset")
        status, stdout, stderr, runner = run_manager([], tap: tap, github: github, runner: runner, package: package)

        assert_equal 0, status
        assert_includes stdout, "Cached package for Homebrew: #{cache_path}"
        assert_includes stdout, "example: refreshed to v1.1.0"
        assert_includes stdout, "Running: brew upgrade --cask ghcask/local/example"
        assert_empty stderr
        assert_equal [
          ["brew", "--cache", "--cask", "ghcask/local/example"],
          ["brew", "info", "--cask", "--json=v2", "ghcask/local/example"],
          ["brew", "upgrade", "--cask", "ghcask/local/example"]
        ], runner.commands
        assert_equal "updated asset", File.read(cache_path)
        assert_equal "v1.1.0", tap.registry.load["casks"]["example"]["release_tag"]
        assert_equal "newsha", tap.registry.load["casks"]["example"]["sha256"]
      end
    end
  end

  def test_update_refreshes_changed_release_without_homebrew_upgrade
    Dir.mktmpdir do |tmp|
      with_tap(entry) do |tap|
        github = FakeGitHub.new("owner/repo" => release("v1.1.0"))
        cache_path = File.join(tmp, "downloads", "example-cache.dmg")
        runner = FakeRunner.new(stdout: {
          "brew --cache --cask ghcask/local/example" => { stdout: "#{cache_path}\n" }
        })
        package = FakePackage.new(content: "updated asset")
        status, stdout, stderr, runner = run_manager([], tap: tap, github: github, runner: runner, package: package, upgrade: false)

        assert_equal 0, status
        assert_includes stdout, "Cached package for Homebrew: #{cache_path}"
        assert_includes stdout, "example: refreshed to v1.1.0"
        refute_includes stdout, "Running: brew upgrade"
        assert_empty stderr
        assert_equal [["brew", "--cache", "--cask", "ghcask/local/example"]], runner.commands
        assert_equal "updated asset", File.read(cache_path)
        assert_equal "v1.1.0", tap.registry.load["casks"]["example"]["release_tag"]
      end
    end
  end

  def test_upgrade_skips_homebrew_upgrade_when_installed_version_is_current
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))
      runner = FakeRunner.new(stdout: {
        "brew info --cask --json=v2 ghcask/local/example" => { stdout: homebrew_info_json(["example", "1.0.0"]) }
      })

      status, stdout, stderr, runner = run_manager([], tap: tap, github: github, runner: runner)

      assert_equal 0, status
      assert_includes stdout, "example: already current"
      refute_includes stdout, "Running: brew upgrade --cask ghcask/local/example"
      assert_empty stderr
      assert_equal [["brew", "info", "--cask", "--json=v2", "ghcask/local/example"]], runner.commands
    end
  end

  def test_upgrade_skips_homebrew_upgrade_when_installed_version_is_unknown
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))
      runner = FakeRunner.new(stdout: {
        "brew info --cask --json=v2 ghcask/local/example" => { stdout: "", ok: false }
      })

      status, stdout, stderr, runner = run_manager([], tap: tap, github: github, runner: runner)

      assert_equal 0, status
      assert_includes stdout, "example: already current"
      refute_includes stdout, "Running: brew upgrade --cask ghcask/local/example"
      assert_empty stderr
      assert_equal [["brew", "info", "--cask", "--json=v2", "ghcask/local/example"]], runner.commands
    end
  end

  def test_upgrade_skips_direct_url_refresh_and_runs_homebrew_upgrade
    with_tap(url_entry) do |tap|
      runner = FakeRunner.new(stdout: {
        "brew info --cask --json=v2 ghcask/local/example" => { stdout: homebrew_info_json(["example", "0.9.0"]) },
        "brew upgrade --cask ghcask/local/example" => {}
      })

      status, stdout, stderr, runner = run_manager(
        [],
        tap: tap,
        github: ExplodingGitHub.new,
        runner: runner
      )

      assert_equal 0, status
      assert_includes stdout, "example: direct URL cask, skipping source refresh"
      assert_includes stdout, "Running: brew upgrade --cask ghcask/local/example"
      assert_empty stderr
      assert_equal [
        ["brew", "info", "--cask", "--json=v2", "ghcask/local/example"],
        ["brew", "upgrade", "--cask", "ghcask/local/example"]
      ], runner.commands
    end
  end

  def test_upgrade_reads_installed_versions_in_one_batch
    with_tap(entry) do |tap|
      second = entry(cask: "second", tag: "v2.0.0").merge("repo" => "owner/second")
      data = tap.registry.load
      data["casks"]["second"] = second
      tap.registry.save(data)
      Ghcask::Cask.write(File.join(tap.casks_dir, "second.rb"), second)
      github = FakeGitHub.new(
        "owner/repo" => release("v1.0.0"),
        "owner/second" => release("v2.0.0")
      )
      runner = FakeRunner.new(stdout: {
        "brew info --cask --json=v2 ghcask/local/example ghcask/local/second" => {
          stdout: homebrew_info_json(["example", "1.0.0"], ["second", "2.0.0"])
        }
      })

      status, stdout, stderr, runner = run_manager([], tap: tap, github: github, runner: runner)

      assert_equal 0, status
      assert_includes stdout, "example: already current"
      assert_includes stdout, "second: already current"
      refute_includes stdout, "skipping Homebrew upgrade"
      assert_empty stderr
      assert_equal [["brew", "info", "--cask", "--json=v2", "ghcask/local/example", "ghcask/local/second"]], runner.commands
    end
  end

  def test_update_skips_direct_url_refresh_without_homebrew_upgrade
    with_tap(url_entry) do |tap|
      status, stdout, stderr, runner = run_manager(
        [],
        tap: tap,
        github: ExplodingGitHub.new,
        upgrade: false
      )

      assert_equal 0, status
      assert_includes stdout, "example: direct URL cask, skipping source refresh"
      refute_includes stdout, "Running: brew upgrade"
      assert_empty stderr
      assert_empty runner.commands
    end
  end

  def test_upgrade_force_rejects_direct_url_cask
    with_tap(url_entry) do |tap|
      status, _stdout, stderr = run_manager(
        ["example", "--force"],
        tap: tap,
        github: ExplodingGitHub.new,
        upgrade: true
      )

      assert_equal 1, status
      assert_includes stderr, "upgrade --force is not supported for direct URL casks"
      assert_includes stderr, "brew ghcask reinstall example --url NEW_URL"
    end
  end

  def test_upgrade_force_single_cask_clears_requested_version
    specific = entry(policy: "latest-stable", requested_version: "v1.0.0")
    with_tap(specific) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.2.0"))
      runner = FakeRunner.new(stdout: {
        "brew --cache --cask ghcask/local/example" => { stdout: File.join(Dir.tmpdir, "example-cache.dmg") },
        "brew info --cask --json=v2 ghcask/local/example" => { stdout: homebrew_info_json(["example", "1.0.0"]) },
        "brew upgrade --cask ghcask/local/example" => {}
      })
      status, stdout, _stderr = run_manager(["example", "--force"], tap: tap, github: github, runner: runner, upgrade: true)

      assert_equal 0, status
      assert_includes stdout, "Running: brew upgrade --cask ghcask/local/example"
      refreshed = tap.registry.load["casks"]["example"]
      assert_equal "latest-stable", refreshed["release_policy"]
      assert_nil refreshed["requested_version"]
    end
  end

  def test_upgrade_force_preserves_prerelease_policy
    specific = entry(policy: "latest-prerelease", requested_version: "v2.0.0-beta.1")
    with_tap(specific) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v2.0.0-beta.2"))
      runner = FakeRunner.new(stdout: {
        "brew --cache --cask ghcask/local/example" => { stdout: File.join(Dir.tmpdir, "example-cache.dmg") },
        "brew info --cask --json=v2 ghcask/local/example" => { stdout: homebrew_info_json(["example", "2.0.0-beta.1"]) },
        "brew upgrade --cask ghcask/local/example" => {}
      })
      status, _stdout, _stderr = run_manager(["example", "--force"], tap: tap, github: github, runner: runner, upgrade: true)

      assert_equal 0, status
      assert_equal [["owner/repo", "latest-prerelease", nil]], github.requests
      refreshed = tap.registry.load["casks"]["example"]
      assert_equal "latest-prerelease", refreshed["release_policy"]
      assert_nil refreshed["requested_version"]
      assert_equal "v2.0.0-beta.2", refreshed["release_tag"]
    end
  end

  def test_update_rejects_cask_name_argument
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.2.0"))
      status, _stdout, stderr = run_manager(["example"], tap: tap, github: github, upgrade: false)

      assert_equal 1, status
      assert_includes stderr, "update does not accept cask names"
      assert_includes stderr, "brew ghcask upgrade cask-name"
    end
  end

  def test_upgrade_bulk_force_is_rejected
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.2.0"))
      status, _stdout, stderr = run_manager(["--force"], tap: tap, github: github)

      assert_equal 1, status
      assert_includes stderr, "--force requires exactly one explicit cask name"
    end
  end

  def test_outdated_reports_without_runner
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.1.0"))
      status, stdout, stderr = run_manager([], tap: tap, github: github, command: :outdated)

      assert_equal 0, status
      assert_includes stdout, "example: v1.0.0 -> v1.1.0"
      assert_empty stderr
    end
  end

  def test_outdated_respects_requested_version_by_default
    specific = entry(policy: "latest-stable", requested_version: "v1.0.0")
    with_tap(specific) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))
      status, stdout, stderr = run_manager([], tap: tap, github: github, command: :outdated)

      assert_equal 0, status
      assert_includes stdout, "example: current v1.0.0"
      assert_empty stderr
      assert_equal [["owner/repo", "latest-stable", "v1.0.0"]], github.requests
    end
  end

  def test_outdated_all_reports_newer_release_for_saved_policy
    specific = entry(policy: "latest-prerelease", requested_version: "v1.0.0")
    with_tap(specific) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.2.0"))
      status, stdout, stderr = run_manager(["--all"], tap: tap, github: github, command: :outdated)

      assert_equal 0, status
      assert_includes stdout, "example: v1.0.0 -> v1.2.0"
      assert_empty stderr
      assert_equal [["owner/repo", "latest-prerelease", nil]], github.requests
    end
  end

  def test_outdated_skips_direct_url_by_default
    with_tap(url_entry) do |tap|
      status, stdout, stderr = run_manager([], tap: tap, github: ExplodingGitHub.new, command: :outdated)

      assert_equal 0, status
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_outdated_all_reports_direct_url_as_not_checkable
    with_tap(url_entry) do |tap|
      status, stdout, stderr = run_manager(["--all"], tap: tap, github: ExplodingGitHub.new, command: :outdated)

      assert_equal 0, status
      assert_includes stdout, "example: direct URL cask, not checkable"
      assert_empty stderr
    end
  end

  def test_list_info_and_uninstall
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))

      status, stdout, = run_manager([], tap: tap, github: github, command: :list)
      assert_equal 0, status
      assert_includes stdout, "example\t1.0.0\towner/repo"

      info_runner = FakeRunner.new(stdout: JSON.dump(
        "casks" => [
          {
            "installed" => "1.0.0",
            "artifacts" => [
              {
                "app" => [
                  "Example.app"
                ],
                "target" => "/Applications/Example.app"
              }
            ]
          }
        ]
      ))
      status, stdout, = run_manager(["example"], tap: tap, github: github, runner: info_runner, command: :info)
      assert_equal 0, status
      assert_includes stdout, "Full cask: ghcask/local/example"
      refute_includes stdout, "Repository: owner/repo"
      assert_includes stdout, "Repository URL: https://github.com/owner/repo"
      assert_includes stdout, "Release policy: latest-stable"
      assert_includes stdout, "Asset URL: https://example.test/Example-arm64.dmg"
      refute_includes stdout, "Allow prerelease:"
      refute_includes stdout, "Release: v1.0.0"
      assert_includes stdout, "sha256: abc123"
      assert_includes stdout, "Installed: yes"
      assert_includes stdout, "Installed version: 1.0.0"
      assert_includes stdout, "Installed path: /Applications/Example.app"

      status, stdout, _stderr, runner = run_manager(["example"], tap: tap, github: github, command: :uninstall)
      assert_equal 0, status
      assert_includes stdout, "Uninstalled example."
      assert_equal [["brew", "uninstall", "--cask", "ghcask/local/example"]], runner.commands
      assert_empty tap.registry.load["casks"]
    end
  end

  def test_list_and_info_show_direct_url_source
    with_tap(url_entry) do |tap|
      status, stdout, = run_manager([], tap: tap, github: ExplodingGitHub.new, command: :list)
      assert_equal 0, status
      assert_includes stdout, "example\t1.0.0\texample"

      info_runner = FakeRunner.new(stdout: JSON.dump("casks" => []))
      status, stdout, stderr = run_manager(["example"], tap: tap, github: ExplodingGitHub.new, runner: info_runner, command: :info)
      assert_equal 0, status
      assert_includes stdout, "Source type: url"
      assert_includes stdout, "Full cask: ghcask/local/example"
      assert_includes stdout, "URL: https://downloads.example.test/Example-1.0.0.dmg"
      assert_includes stdout, "Release policy: url"
      assert_includes stdout, "Asset URL: https://downloads.example.test/Example-1.0.0.dmg"
      refute_includes stdout, "Allow prerelease:"
      refute_includes stdout, "Release:"
      assert_includes stdout, "sha256: abc123"
      assert_empty stderr
    end
  end

  def test_reinstall_runs_homebrew_reinstall_for_managed_cask
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))
      runner = FakeRunner.new(stdout: "reinstalled\n")

      status, stdout, stderr, runner = run_manager(["example"], tap: tap, github: github, runner: runner, command: :reinstall)

      assert_equal 0, status
      assert_includes stdout, "Running: brew reinstall --cask ghcask/local/example"
      assert_includes stdout, "reinstalled"
      assert_includes stdout, "Homebrew finished reinstall for example."
      assert_empty stderr
      assert_equal [["brew", "reinstall", "--cask", "ghcask/local/example"]], runner.commands
    end
  end

  def test_reinstall_accepts_repository_reference
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))
      runner = FakeRunner.new(stdout: "reinstalled\n")

      status, stdout, stderr, runner = run_manager(["owner/repo"], tap: tap, github: github, runner: runner, command: :reinstall)

      assert_equal 0, status
      assert_includes stdout, "Running: brew reinstall --cask ghcask/local/example"
      assert_empty stderr
      assert_equal [["brew", "reinstall", "--cask", "ghcask/local/example"]], runner.commands
    end
  end

  def test_reinstall_force_passes_force_to_homebrew_reinstall
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))
      runner = FakeRunner.new(stdout: "reinstalled\n")

      status, stdout, stderr, runner = run_manager(["example", "--force"], tap: tap, github: github, runner: runner, command: :reinstall)

      assert_equal 0, status
      assert_includes stdout, "Running: brew reinstall --cask --force ghcask/local/example"
      assert_empty stderr
      assert_equal [["brew", "reinstall", "--cask", "--force", "ghcask/local/example"]], runner.commands
    end
  end

  def test_reinstall_dry_run_previews_homebrew_reinstall_without_running
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))

      status, stdout, stderr, runner = run_manager(["example", "--dry-run"], tap: tap, github: github, command: :reinstall)

      assert_equal 0, status
      assert_includes stdout, "Would run: brew reinstall --cask ghcask/local/example"
      assert_empty stderr
      assert_empty runner.commands
      assert_equal "owner/repo", tap.registry.load["casks"]["example"]["repo"]
    end
  end

  def test_reinstall_dry_run_with_force_previews_force_command_without_running
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))

      status, stdout, stderr, runner = run_manager(["example", "--force", "--dry-run"], tap: tap, github: github, command: :reinstall)

      assert_equal 0, status
      assert_includes stdout, "Would run: brew reinstall --cask --force ghcask/local/example"
      assert_empty stderr
      assert_empty runner.commands
    end
  end

  def test_reinstall_direct_url_replaces_url_and_runs_homebrew_reinstall
    Dir.mktmpdir do |tmp|
      with_tap(url_entry) do |tap|
        cache_path = File.join(tmp, "downloads", "example-cache.dmg")
        runner = FakeRunner.new(stdout: {
          "brew --cache --cask ghcask/local/example" => { stdout: "#{cache_path}\n" },
          "brew reinstall --cask ghcask/local/example" => { stdout: "reinstalled\n" }
        })
        package = FakePackage.new(sha: "newsha", content: "new asset", app: "Renamed.app", version: "2.0.0")

        status, stdout, stderr, runner = run_manager(
          ["example", "--url", "https://downloads.example.test/Renamed-2.0.0.dmg"],
          tap: tap,
          github: ExplodingGitHub.new,
          runner: runner,
          package: package,
          command: :reinstall
        )

        assert_equal 0, status
        assert_includes stdout, "URL: https://downloads.example.test/Renamed-2.0.0.dmg"
        assert_includes stdout, "Version: 2.0.0"
        assert_includes stdout, "Cached package for Homebrew: #{cache_path}"
        assert_includes stdout, "Running: brew reinstall --cask ghcask/local/example"
        assert_empty stderr
        assert_equal "new asset", File.read(cache_path)
        assert_equal [
          ["brew", "--cache", "--cask", "ghcask/local/example"],
          ["brew", "reinstall", "--cask", "ghcask/local/example"]
        ], runner.commands

        refreshed = tap.registry.load["casks"]["example"]
        assert_equal "Renamed.app", refreshed["app"]
        assert_equal "Renamed", refreshed["name"]
        assert_equal "2.0.0", refreshed["version"]
        assert_equal "newsha", refreshed["sha256"]
        assert_equal "https://downloads.example.test/Renamed-2.0.0.dmg", refreshed["asset_url"]
        assert_includes File.read(File.join(tap.casks_dir, "example.rb")), 'app "Renamed.app"'
      end
    end
  end

  def test_reinstall_direct_url_force_passes_force_to_homebrew_reinstall
    Dir.mktmpdir do |tmp|
      with_tap(url_entry) do |tap|
        cache_path = File.join(tmp, "downloads", "example-cache.dmg")
        runner = FakeRunner.new(stdout: {
          "brew --cache --cask ghcask/local/example" => { stdout: "#{cache_path}\n" },
          "brew reinstall --cask --force ghcask/local/example" => { stdout: "reinstalled\n" }
        })

        status, stdout, stderr, runner = run_manager(
          ["example", "--url", "https://downloads.example.test/Renamed-2.0.0.dmg", "--force"],
          tap: tap,
          github: ExplodingGitHub.new,
          runner: runner,
          command: :reinstall
        )

        assert_equal 0, status
        assert_includes stdout, "Running: brew reinstall --cask --force ghcask/local/example"
        assert_empty stderr
        assert_equal [
          ["brew", "--cache", "--cask", "ghcask/local/example"],
          ["brew", "reinstall", "--cask", "--force", "ghcask/local/example"]
        ], runner.commands
      end
    end
  end

  def test_reinstall_direct_url_dry_run_does_not_write_or_run_homebrew
    with_tap(url_entry) do |tap|
      before = tap.registry.load
      package = FakePackage.new(sha: "newsha", app: "Renamed.app", version: "2.0.0")

      status, stdout, stderr, runner = run_manager(
        ["example", "--url", "https://downloads.example.test/Renamed-2.0.0.dmg", "--dry-run"],
        tap: tap,
        github: ExplodingGitHub.new,
        package: package,
        command: :reinstall
      )

      assert_equal 0, status
      assert_includes stdout, "Source: direct URL"
      assert_includes stdout, "sha256: newsha"
      assert_empty stderr
      assert_empty runner.commands
      assert_equal before, tap.registry.load
      assert_equal 1, package.downloads.length
    end
  end

  def test_reinstall_direct_url_rejects_github_source
    with_tap(entry) do |tap|
      status, _stdout, stderr = run_manager(
        ["example", "--url", "https://downloads.example.test/Example.dmg"],
        tap: tap,
        github: FakeGitHub.new("owner/repo" => release("v1.0.0")),
        command: :reinstall
      )

      assert_equal 1, status
      assert_includes stderr, "reinstall --url is only supported for direct URL casks"
    end
  end

  def test_reinstall_github_version_refreshes_cask_and_runs_homebrew_reinstall
    Dir.mktmpdir do |tmp|
      with_tap(entry) do |tap|
        cache_path = File.join(tmp, "downloads", "example-cache.dmg")
        github = FakeGitHub.new("owner/repo" => release("v1.2.0", asset_name: "Example-1.2.0-arm64.dmg"))
        runner = FakeRunner.new(stdout: {
          "brew --cache --cask ghcask/local/example" => { stdout: "#{cache_path}\n" },
          "brew reinstall --cask ghcask/local/example" => { stdout: "reinstalled\n" }
        })
        package = FakePackage.new(sha: "newsha", content: "specific asset", version: "1.2.0")

        status, stdout, stderr, runner = run_manager(
          ["owner/repo", "--version", "v1.2.0"],
          tap: tap,
          github: github,
          runner: runner,
          package: package,
          command: :reinstall
        )

        assert_equal 0, status
        assert_includes stdout, "Release policy: latest-stable"
        assert_includes stdout, "Requested version: v1.2.0"
        assert_includes stdout, "Release: v1.2.0"
        assert_includes stdout, "Cached package for Homebrew: #{cache_path}"
        assert_includes stdout, "Running: brew reinstall --cask ghcask/local/example"
        assert_empty stderr
        assert_equal [["owner/repo", "latest-stable", "v1.2.0"]], github.requests
        assert_equal [
          ["brew", "--cache", "--cask", "ghcask/local/example"],
          ["brew", "reinstall", "--cask", "ghcask/local/example"]
        ], runner.commands
        assert_equal "specific asset", File.read(cache_path)

        refreshed = tap.registry.load["casks"]["example"]
        assert_equal "latest-stable", refreshed["release_policy"]
        assert_equal "v1.2.0", refreshed["requested_version"]
        assert_equal "v1.2.0", refreshed["release_tag"]
        assert_equal "1.2.0", refreshed["version"]
        assert_equal "Example-1.2.0-arm64.dmg", refreshed["asset_name"]
        assert_equal "newsha", refreshed["sha256"]
      end
    end
  end

  def test_reinstall_github_tag_url_uses_tag_as_requested_version
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.2.0"))
      runner = FakeRunner.new(stdout: {
        "brew --cache --cask ghcask/local/example" => { stdout: File.join(Dir.tmpdir, "example-cache.dmg") },
        "brew reinstall --cask ghcask/local/example" => {}
      })

      status, stdout, stderr = run_manager(
        ["https://github.com/owner/repo/releases/tag/v1.2.0"],
        tap: tap,
        github: github,
        runner: runner,
        command: :reinstall
      )

      assert_equal 0, status
      assert_includes stdout, "Requested version: v1.2.0"
      assert_empty stderr
      assert_equal [["owner/repo", "latest-stable", "v1.2.0"]], github.requests
      assert_equal "v1.2.0", tap.registry.load["casks"]["example"]["requested_version"]
    end
  end

  def test_reinstall_github_version_dry_run_does_not_write_or_run_homebrew
    with_tap(entry) do |tap|
      before = tap.registry.load
      github = FakeGitHub.new("owner/repo" => release("v1.2.0"))
      package = FakePackage.new

      status, stdout, stderr, runner = run_manager(
        ["example", "--version", "v1.2.0", "--dry-run"],
        tap: tap,
        github: github,
        package: package,
        command: :reinstall
      )

      assert_equal 0, status
      assert_includes stdout, "Release policy: latest-stable"
      assert_includes stdout, "Requested version: v1.2.0"
      assert_includes stdout, "sha256: (will calculate during reinstall)"
      assert_includes stdout, "Would run: brew reinstall --cask ghcask/local/example"
      assert_empty stderr
      assert_empty runner.commands
      assert_empty package.downloads
      assert_equal before, tap.registry.load
    end
  end

  def test_reinstall_prerelease_switches_policy_and_runs_homebrew_reinstall
    Dir.mktmpdir do |tmp|
      with_tap(entry) do |tap|
        cache_path = File.join(tmp, "downloads", "example-cache.dmg")
        github = FakeGitHub.new("owner/repo" => release("v2.0.0-beta.1", asset_name: "Example-beta-arm64.dmg"))
        runner = FakeRunner.new(stdout: {
          "brew --cache --cask ghcask/local/example" => { stdout: "#{cache_path}\n" },
          "brew reinstall --cask ghcask/local/example" => {}
        })

        status, stdout, stderr = run_manager(
          ["example", "--prerelease"],
          tap: tap,
          github: github,
          runner: runner,
          command: :reinstall
        )

        assert_equal 0, status
        assert_includes stdout, "Release policy: latest-prerelease"
        assert_includes stdout, "Release: v2.0.0-beta.1"
        assert_empty stderr
        assert_equal [["owner/repo", "latest-prerelease", nil]], github.requests
        refreshed = tap.registry.load["casks"]["example"]
        assert_equal "latest-prerelease", refreshed["release_policy"]
        assert_nil refreshed["requested_version"]
        assert_equal "v2.0.0-beta.1", refreshed["release_tag"]
      end
    end
  end

  def test_reinstall_stable_switches_policy_and_runs_homebrew_reinstall
    prerelease_entry = entry(tag: "v2.0.0-beta.1", policy: "latest-prerelease")
    with_tap(prerelease_entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.9.0"))
      runner = FakeRunner.new(stdout: {
        "brew --cache --cask ghcask/local/example" => { stdout: File.join(Dir.tmpdir, "example-cache.dmg") },
        "brew reinstall --cask ghcask/local/example" => {}
      })

      status, stdout, stderr = run_manager(
        ["owner/repo", "--stable"],
        tap: tap,
        github: github,
        runner: runner,
        command: :reinstall
      )

      assert_equal 0, status
      assert_includes stdout, "Release policy: latest-stable"
      assert_includes stdout, "Release: v1.9.0"
      assert_empty stderr
      assert_equal [["owner/repo", "latest-stable", nil]], github.requests
      refreshed = tap.registry.load["casks"]["example"]
      assert_equal "latest-stable", refreshed["release_policy"]
      assert_nil refreshed["requested_version"]
      assert_equal "v1.9.0", refreshed["release_tag"]
    end
  end

  def test_reinstall_github_version_rejects_direct_url_source
    with_tap(url_entry) do |tap|
      status, _stdout, stderr = run_manager(
        ["example", "--version", "2.0.0"],
        tap: tap,
        github: ExplodingGitHub.new,
        command: :reinstall
      )

      assert_equal 1, status
      assert_includes stderr, "GitHub release selection is only supported for GitHub casks"
      assert_includes stderr, "brew ghcask reinstall example --url NEW_URL"
    end
  end

  def test_reinstall_prerelease_rejects_direct_url_source
    with_tap(url_entry) do |tap|
      status, _stdout, stderr = run_manager(
        ["example", "--prerelease"],
        tap: tap,
        github: ExplodingGitHub.new,
        command: :reinstall
      )

      assert_equal 1, status
      assert_includes stderr, "GitHub release selection is only supported for GitHub casks"
      assert_includes stderr, "brew ghcask reinstall example --url NEW_URL"
    end
  end

  def test_reinstall_policy_options_are_mutually_exclusive
    with_tap(entry) do |tap|
      status, _stdout, stderr = run_manager(
        ["example", "--version", "v1.2.0", "--prerelease"],
        tap: tap,
        github: ExplodingGitHub.new,
        command: :reinstall
      )

      assert_equal 1, status
      assert_includes stderr, "--version, --prerelease, and --stable are mutually exclusive"
    end
  end

  def test_pin_sets_requested_version_to_current_release
    with_tap(entry(tag: "v1.2.0")) do |tap|
      status, stdout, stderr = run_manager(["owner/repo"], tap: tap, github: ExplodingGitHub.new, command: :pin)

      assert_equal 0, status
      assert_includes stdout, "Pinned example to v1.2.0."
      assert_empty stderr
      refreshed = tap.registry.load["casks"]["example"]
      assert_equal "latest-stable", refreshed["release_policy"]
      assert_equal "v1.2.0", refreshed["requested_version"]
      assert_equal "v1.2.0", refreshed["release_tag"]
    end
  end

  def test_pin_preserves_prerelease_policy
    prerelease = entry(tag: "v2.0.0-beta.1", policy: "latest-prerelease")
    with_tap(prerelease) do |tap|
      status, stdout, stderr = run_manager(["example"], tap: tap, github: ExplodingGitHub.new, command: :pin)

      assert_equal 0, status
      assert_includes stdout, "Pinned example to v2.0.0-beta.1."
      assert_empty stderr
      refreshed = tap.registry.load["casks"]["example"]
      assert_equal "latest-prerelease", refreshed["release_policy"]
      assert_equal "v2.0.0-beta.1", refreshed["requested_version"]
    end
  end

  def test_unpin_clears_requested_version_and_preserves_policy
    specific = entry(policy: "latest-prerelease", requested_version: "v1.2.0")
    with_tap(specific) do |tap|
      status, stdout, stderr = run_manager(["example"], tap: tap, github: ExplodingGitHub.new, command: :unpin)

      assert_equal 0, status
      assert_includes stdout, "Unpinned example. It will follow latest-prerelease."
      assert_empty stderr
      refreshed = tap.registry.load["casks"]["example"]
      assert_equal "latest-prerelease", refreshed["release_policy"]
      assert_nil refreshed["requested_version"]
    end
  end

  def test_pin_rejects_direct_url_source
    with_tap(url_entry) do |tap|
      status, _stdout, stderr = run_manager(["example"], tap: tap, github: ExplodingGitHub.new, command: :pin)

      assert_equal 1, status
      assert_includes stderr, "pin is only supported for GitHub casks"
      assert_includes stderr, "brew ghcask reinstall example --url NEW_URL"
    end
  end

  def test_unpin_rejects_direct_url_source
    with_tap(url_entry) do |tap|
      status, _stdout, stderr = run_manager(["example"], tap: tap, github: ExplodingGitHub.new, command: :unpin)

      assert_equal 1, status
      assert_includes stderr, "unpin is only supported for GitHub casks"
      assert_includes stderr, "brew ghcask reinstall example --url NEW_URL"
    end
  end

  def test_info_accepts_repository_url
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))
      status, stdout, stderr = run_manager(["https://github.com/owner/repo"], tap: tap, github: github, command: :info)

      assert_equal 0, status
      assert_includes stdout, "Cask: example"
      refute_includes stdout, "Repository: owner/repo"
      assert_includes stdout, "Repository URL: https://github.com/owner/repo"
      assert_empty stderr
    end
  end

  def test_uninstall_accepts_repository_reference
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))
      status, stdout, _stderr, runner = run_manager(["owner/repo"], tap: tap, github: github, command: :uninstall)

      assert_equal 0, status
      assert_includes stdout, "Uninstalled example."
      assert_equal [["brew", "uninstall", "--cask", "ghcask/local/example"]], runner.commands
    end
  end

  def test_uninstall_dry_run_does_not_remove_app_or_metadata
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))
      cask_path = File.join(tap.casks_dir, "example.rb")

      status, stdout, stderr, runner = run_manager(["example", "--dry-run"], tap: tap, github: github, command: :uninstall)

      assert_equal 0, status
      assert_includes stdout, "Would uninstall example with Homebrew."
      assert_includes stdout, "Would remove ghcask metadata for example."
      assert_includes stdout, "Would remove generated cask file: #{cask_path}"
      assert_empty stderr
      assert_empty runner.commands
      assert_equal "owner/repo", tap.registry.load["casks"]["example"]["repo"]
      assert File.exist?(cask_path)
    end
  end

  def test_uninstall_dry_run_with_keep_installed_previews_metadata_only
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))

      status, stdout, stderr, runner = run_manager(["example", "--keep-installed", "--dry-run"], tap: tap, github: github, command: :uninstall)

      assert_equal 0, status
      assert_includes stdout, "Would keep installed app."
      refute_includes stdout, "Would uninstall example with Homebrew."
      assert_includes stdout, "Would remove ghcask metadata for example."
      assert_empty stderr
      assert_empty runner.commands
      refute_empty tap.registry.load["casks"]
    end
  end

  def test_uninstall_warns_and_removes_metadata_when_homebrew_cask_is_not_installed
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))
      runner = FakeRunner.new(stdout: {
        "brew uninstall --cask ghcask/local/example" => {
          stderr: "Error: Cask 'example' is not installed.\n",
          ok: false
        }
      })

      status, stdout, stderr, runner = run_manager(["example"], tap: tap, github: github, runner: runner, command: :uninstall)

      assert_equal 0, status
      assert_includes stderr, "Warning: Error: Cask 'example' is not installed."
      assert_includes stderr, "Removing ghcask metadata anyway."
      assert_includes stdout, "Uninstalled example."
      assert_equal [["brew", "uninstall", "--cask", "ghcask/local/example"]], runner.commands
      assert_empty tap.registry.load["casks"]
      refute File.exist?(File.join(tap.casks_dir, "example.rb"))
    end
  end

  def test_reinstall_rejects_unmanaged_cask
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))

      status, _stdout, stderr = run_manager(["missing"], tap: tap, github: github, command: :reinstall)

      assert_equal 1, status
      assert_includes stderr, "managed cask not found: missing"
    end
  end

  def test_cleanup_removes_registry_entries_for_deleted_cask_files
    with_tap(entry) do |tap|
      FileUtils.rm_f(File.join(tap.casks_dir, "example.rb"))
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))

      status, stdout, stderr = run_manager([], tap: tap, github: github, command: :cleanup)

      assert_equal 0, status
      assert_includes stdout, "Removed registry entry for deleted cask file: example"
      assert_empty stderr
      assert_empty tap.registry.load["casks"]
    end
  end

  def test_cleanup_dry_run_does_not_modify_registry
    with_tap(entry) do |tap|
      FileUtils.rm_f(File.join(tap.casks_dir, "example.rb"))
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))

      status, stdout, stderr = run_manager(["--dry-run"], tap: tap, github: github, command: :cleanup)

      assert_equal 0, status
      assert_includes stdout, "Would remove registry entry for deleted cask file: example"
      assert_empty stderr
      assert_equal ["example"], tap.registry.load["casks"].keys
    end
  end

  def test_cleanup_removes_cask_uninstalled_by_homebrew
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))
      runner = FakeRunner.new(stdout: {
        "brew list --cask" => {
          stdout: "other-cask\n"
        }
      })

      status, stdout, stderr = run_manager([], tap: tap, github: github, runner: runner, command: :cleanup)

      assert_equal 0, status
      assert_includes stdout, "Removed managed cask uninstalled by Homebrew: example"
      assert_empty stderr
      assert_empty tap.registry.load["casks"]
      refute File.exist?(File.join(tap.casks_dir, "example.rb"))
    end
  end

  def test_cleanup_keeps_generated_cask_that_was_never_installed
    generated = entry
    generated["install_state"] = "generated"
    with_tap(generated) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))
      runner = FakeRunner.new(stdout: {
        "brew list --cask" => {
          stdout: "other-cask\n"
        }
      })

      status, stdout, stderr = run_manager([], tap: tap, github: github, runner: runner, command: :cleanup)

      assert_equal 0, status
      assert_includes stdout, "No deleted local casks found."
      assert_empty stderr
      assert_equal ["example"], tap.registry.load["casks"].keys
      assert File.exist?(File.join(tap.casks_dir, "example.rb"))
    end
  end

  def test_cleanup_treats_legacy_registry_entries_as_installed
    legacy = entry
    legacy.delete("install_state")
    with_tap(legacy) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))
      runner = FakeRunner.new(stdout: {
        "brew list --cask" => {
          stdout: "other-cask\n"
        }
      })

      status, stdout, stderr = run_manager([], tap: tap, github: github, runner: runner, command: :cleanup)

      assert_equal 0, status
      assert_includes stdout, "Removed managed cask uninstalled by Homebrew: example"
      assert_empty stderr
      assert_empty tap.registry.load["casks"]
    end
  end

  def test_cleanup_reports_when_nothing_to_remove
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))
      runner = FakeRunner.new(stdout: {
        "brew list --cask" => {
          stdout: "example\n"
        }
      })

      status, stdout, stderr = run_manager([], tap: tap, github: github, runner: runner, command: :cleanup)

      assert_equal 0, status
      assert_includes stdout, "No deleted local casks found."
      assert_empty stderr
      assert_equal ["example"], tap.registry.load["casks"].keys
      assert_equal [["brew", "list", "--cask"]], runner.commands
    end
  end

  def test_cleanup_keeps_entries_when_homebrew_list_fails
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))
      runner = FakeRunner.new(stdout: {
        "brew list --cask" => {
          stderr: "brew failed",
          ok: false
        }
      })

      status, stdout, stderr = run_manager([], tap: tap, github: github, runner: runner, command: :cleanup)

      assert_equal 0, status
      assert_includes stdout, "No deleted local casks found."
      assert_empty stderr
      assert_equal ["example"], tap.registry.load["casks"].keys
    end
  end

  def test_reinstall_failure_does_not_repeat_full_homebrew_log
    with_tap(entry) do |tap|
      github = FakeGitHub.new("owner/repo" => release("v1.0.0"))
      runner = FakeRunner.new(ok: false, stderr: "line one\nError: useful failure\nsource snippet\n")

      status, _stdout, stderr = run_manager(["example"], tap: tap, github: github, runner: runner, command: :reinstall)

      assert_equal 1, status
      assert_includes stderr, "line one"
      assert_includes stderr, "source snippet"
      assert_includes stderr, "ghcask reinstall: Homebrew reinstall failed: Error: useful failure"
      assert_equal 1, stderr.scan("line one").length
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

require "ghcask/installer"

class InstallerTest < Minitest::Test
  FakeStatus = Struct.new(:ok) do
    def success?
      ok
    end
  end

  FakeResult = Struct.new(:stdout, :stderr, :ok, keyword_init: true) do
    def success?
      ok
    end
  end

  class FakeGitHub
    attr_reader :requests

    def initialize(release)
      @release = release
      @requests = []
    end

    def select_release(repo, policy:, requested_version:)
      @requests << [repo, policy, requested_version]
      @release
    end
  end

  class ExplodingGitHub
    def select_release(*)
      raise "GitHub should not be called"
    end
  end

  class FakePackage
    attr_reader :downloads

    def initialize(asset_path, sha: "abc123", app: "Example.app", version: nil)
      @asset_path = asset_path
      @sha = sha
      @app = app
      @version = version
      @downloads = []
    end

    def download(asset, destination_dir:, stdout: nil)
      stdout&.puts "==> Downloading #{asset.url}"
      @downloads << [asset, destination_dir]
      destination = File.join(destination_dir, File.basename(@asset_path))
      if File.exist?(@asset_path)
        FileUtils.cp(@asset_path, destination)
      else
        File.write(destination, "downloaded asset")
      end
      destination
    end

    def sha256(_path)
      @sha
    end

    def infer_app(_path, app_override: nil)
      app = app_override || @app
      Ghcask::Package::AppMetadata.new(app: app, name: app.sub(/\.app\z/, ""), version: @version)
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
        response = @stdout.fetch(command.join(" "), {})
        return FakeResult.new(stdout: response.fetch(:stdout, ""), stderr: response.fetch(:stderr, ""), ok: response.fetch(:ok, true))
      end

      FakeResult.new(stdout: @stdout, stderr: @ok ? @stderr : (@stderr.empty? ? "failed" : @stderr), ok: @ok)
    end
  end

  def release
    asset = Ghcask::GitHub::Asset.new(
      name: "Example-arm64.dmg",
      url: "https://github.com/owner/repo/releases/download/v1.2.3/Example-arm64.dmg"
    )
    Ghcask::GitHub::Release.new(
      tag_name: "v1.2.3",
      name: "Example",
      draft: false,
      prerelease: false,
      published_at: Time.parse("2026-01-01T00:00:00Z"),
      assets: [asset]
    )
  end

  def run_install(argv, tap:, github: FakeGitHub.new(release), package: nil, runner: FakeRunner.new)
    stdout = StringIO.new
    stderr = StringIO.new
    package ||= FakePackage.new(File.join(Dir.tmpdir, "Example.dmg"))
    status = Ghcask::Installer.new(argv, stdout: stdout, stderr: stderr, github: github, tap: tap, package: package, runner: runner).run
    [status, stdout.string, stderr.string, github, package, runner]
  end

  def with_tap
    Dir.mktmpdir do |homebrew|
      yield Ghcask::LocalTap.new(homebrew_repository: homebrew)
    end
  end

  def test_dry_run_prints_plan_without_writing
    with_tap do |tap|
      status, stdout, stderr = run_install(["owner/repo", "--dry-run", "--trust"], tap: tap)

      assert_equal 0, status
      assert_includes stdout, "Source: GitHub"
      assert_includes stdout, "Repository: owner/repo"
      assert_includes stdout, "Release policy: latest-stable"
      assert_includes stdout, "Release: v1.2.3"
      assert_includes stdout, "Version: 1.2.3"
      assert_includes stdout, "Asset: Example-arm64.dmg"
      assert_includes stdout, "Asset URL: https://github.com/owner/repo/releases/download/v1.2.3/Example-arm64.dmg"
      assert_includes stdout, "Architecture:"
      assert_includes stdout, "Cask: repo"
      assert_includes stdout, "Name: Example"
      assert_includes stdout, "App: (will infer during install)"
      assert_includes stdout, "sha256: (will calculate during install)"
      assert_includes stdout, "Would write cask: yes"
      assert_includes stdout, "Would update registry: yes"
      assert_includes stdout, "Would trust cask: yes"
      assert_includes stdout, "Would cache package for Homebrew: yes"
      assert_includes stdout, "Would install with Homebrew: yes"
      assert_includes stdout, "Would run: brew install --cask ghcask/local/repo"
      refute File.exist?(tap.registry_path)
      assert_empty stderr
    end
  end

  def test_full_github_url_is_normalized
    with_tap do |tap|
      github = FakeGitHub.new(release)
      status, stdout, stderr = run_install(["https://github.com/owner/repo", "--dry-run"], tap: tap, github: github)

      assert_equal 0, status
      assert_includes stdout, "Repository: owner/repo"
      assert_empty stderr
      assert_equal [["owner/repo", "latest-stable", nil]], github.requests
    end
  end

  def test_github_release_tag_url_installs_that_specific_version
    with_tap do |tap|
      github = FakeGitHub.new(release)
      status, stdout, stderr = run_install(["https://github.com/owner/repo/releases/tag/0.8.5", "--dry-run"], tap: tap, github: github)

      assert_equal 0, status
      assert_includes stdout, "Repository: owner/repo"
      assert_includes stdout, "Release policy: latest-stable"
      assert_includes stdout, "Requested version: 0.8.5"
      assert_empty stderr
      assert_equal [["owner/repo", "latest-stable", "0.8.5"]], github.requests
    end
  end

  def test_explicit_version_overrides_github_release_tag_url
    with_tap do |tap|
      github = FakeGitHub.new(release)
      status, stdout, stderr = run_install(
        ["https://github.com/owner/repo/releases/tag/0.8.5", "--version", "v1.2.3", "--dry-run"],
        tap: tap,
        github: github
      )

      assert_equal 0, status
      assert_includes stdout, "Requested version: v1.2.3"
      assert_empty stderr
      assert_equal [["owner/repo", "latest-stable", "v1.2.3"]], github.requests
    end
  end

  def test_dry_run_with_no_install_previews_no_homebrew_install
    with_tap do |tap|
      status, stdout, stderr = run_install(["owner/repo", "--dry-run", "--no-install"], tap: tap)

      assert_equal 0, status
      assert_includes stdout, "Would install with Homebrew: no"
      assert_includes stdout, "Would cache package for Homebrew: no"
      refute_includes stdout, "Would run: brew install --cask"
      refute File.exist?(tap.registry_path)
      assert_empty stderr
    end
  end

  def test_no_install_writes_cask_and_registry_without_running_brew
    with_tap do |tap|
      status, stdout, stderr, _github, _package, runner = run_install(["owner/repo", "--no-install"], tap: tap)

      assert_equal 0, status
      assert_includes stdout, "Generated local cask without installing."
      assert_empty stderr
      assert_empty runner.commands
      cask_path = File.join(tap.casks_dir, "example.rb")
      assert File.exist?(cask_path)
      cask = File.read(cask_path)
      assert_includes cask, 'cask "example"'
      refute_includes cask, "verified:"
      refute_includes cask, "livecheck"
      assert_equal "owner/repo", tap.registry.load["casks"]["example"]["repo"]
      assert_equal "github", tap.registry.load["casks"]["example"]["source_type"]
      assert_equal "generated", tap.registry.load["casks"]["example"]["install_state"]
    end
  end

  def test_no_install_with_trust_trusts_written_cask_without_installing
    with_tap do |tap|
      runner = FakeRunner.new(stdout: {
        "brew trust --cask ghcask/local/example" => {}
      })
      status, stdout, stderr, _github, _package, runner = run_install(["owner/repo", "--no-install", "--trust"], tap: tap, runner: runner)

      assert_equal 0, status
      assert_includes stdout, "Running: brew trust --cask ghcask/local/example"
      assert_includes stdout, "Generated local cask without installing."
      assert_empty stderr
      assert_equal [["brew", "trust", "--cask", "ghcask/local/example"]], runner.commands
      assert File.exist?(File.join(tap.casks_dir, "example.rb"))
    end
  end

  def test_direct_url_no_install_writes_cask_and_registry_without_github_lookup
    with_tap do |tap|
      url = "https://downloads.example.test/apps/Example-2.4.0.dmg"
      status, stdout, stderr, _github, _package, runner = run_install(
        ["example", "--url", url, "--no-install"],
        tap: tap,
        github: ExplodingGitHub.new
      )

      assert_equal 0, status
      assert_includes stdout, "Source: direct URL"
      assert_includes stdout, "URL: #{url}"
      assert_includes stdout, "Version: 2.4.0"
      assert_includes stdout, "Generated local cask without installing."
      assert_empty stderr
      assert_empty runner.commands

      cask_path = File.join(tap.casks_dir, "example.rb")
      cask = File.read(cask_path)
      assert_includes cask, 'cask "example"'
      assert_includes cask, 'url "https://downloads.example.test/apps/Example-2.4.0.dmg"'
      refute_includes cask, "verified:"
      assert_includes cask, 'homepage "https://downloads.example.test"'
      refute_includes cask, "livecheck"

      entry = tap.registry.load["casks"]["example"]
      assert_nil entry["repo"]
      assert_equal "url", entry["source_type"]
      assert_equal "url", entry["release_policy"]
      assert_equal "Example-2.4.0.dmg", entry["asset_name"]
      assert_equal url, entry["asset_url"]
      assert_equal "https://downloads.example.test", entry["homepage"]
      refute entry.key?("verified")
      assert_nil entry["requested_version"]
      assert_nil entry["asset_pattern"]
      assert_nil entry["arch"]
      assert_nil entry["release_tag"]
      assert_equal "2.4.0", entry["version"]
      assert_equal "abc123", entry["sha256"]
      assert_equal "generated", entry["install_state"]
    end
  end

  def test_direct_url_github_homepage_keeps_owner_and_repo
    with_tap do |tap|
      url = "https://github.com/owner/repo/releases/download/v1.2.3/Example.dmg"
      status, _stdout, stderr = run_install(
        ["example", "--url", url, "--no-install"],
        tap: tap,
        github: ExplodingGitHub.new
      )

      assert_equal 0, status
      assert_empty stderr
      entry = tap.registry.load["casks"]["example"]
      assert_equal "https://github.com/owner/repo", entry["homepage"]
      refute entry.key?("verified")
    end
  end

  def test_direct_url_uses_app_version_before_filename
    with_tap do |tap|
      status, _stdout, stderr = run_install(
        ["example", "--url", "https://downloads.example.test/Example-2.4.0.dmg", "--no-install"],
        tap: tap,
        github: ExplodingGitHub.new,
        package: FakePackage.new(File.join(Dir.tmpdir, "Example.dmg"), version: "9.8.7")
      )

      assert_equal 0, status
      assert_empty stderr
      assert_equal "9.8.7", tap.registry.load["casks"]["example"]["version"]
    end
  end

  def test_direct_url_explicit_version_wins
    with_tap do |tap|
      status, _stdout, stderr = run_install(
        ["example", "--url", "https://downloads.example.test/Example-2.4.0.dmg", "--version", "3.0.0", "--no-install"],
        tap: tap,
        github: ExplodingGitHub.new,
        package: FakePackage.new(File.join(Dir.tmpdir, "Example.dmg"), version: "9.8.7")
      )

      assert_equal 0, status
      assert_empty stderr
      assert_equal "3.0.0", tap.registry.load["casks"]["example"]["version"]
    end
  end

  def test_direct_url_dry_run_does_not_write_or_install
    with_tap do |tap|
      status, stdout, stderr, _github, package, runner = run_install(
        ["example", "--url", "https://downloads.example.test/Example.dmg", "--dry-run"],
        tap: tap,
        github: ExplodingGitHub.new
      )

      assert_equal 0, status
      assert_includes stdout, "Source: direct URL"
      assert_includes stdout, "URL: https://downloads.example.test/Example.dmg"
      assert_includes stdout, "Asset: Example.dmg"
      assert_includes stdout, "Cask: example"
      assert_includes stdout, "Name: Example"
      assert_includes stdout, "App: Example.app"
      assert_includes stdout, "Version: latest"
      assert_includes stdout, "Homepage: https://downloads.example.test"
      refute_includes stdout, "Verified:"
      assert_includes stdout, "sha256: abc123"
      assert_includes stdout, "Would write cask: yes"
      assert_includes stdout, "Would update registry: yes"
      assert_includes stdout, "Would cache package for Homebrew: yes"
      assert_includes stdout, "Would install with Homebrew: yes"
      assert_empty stderr
      assert_equal 1, package.downloads.length
      assert_empty runner.commands
      refute File.exist?(tap.registry_path)
      refute File.exist?(File.join(tap.casks_dir, "example.rb"))
    end
  end

  def test_direct_url_repeated_install_reuses_existing_local_cask
    with_tap do |tap|
      existing = url_entry
      tap.init
      tap.registry.save("version" => 1, "casks" => { "example" => existing })
      Ghcask::Cask.write(File.join(tap.casks_dir, "example.rb"), existing)
      runner = FakeRunner.new(stdout: {
        "brew install --cask ghcask/local/example" => {}
      })

      status, stdout, stderr, _github, package, runner = run_install(
        ["example", "--url", "https://downloads.example.test/Other.dmg"],
        tap: tap,
        github: ExplodingGitHub.new,
        runner: runner
      )

      assert_equal 0, status
      assert_includes stdout, "Using existing local cask."
      assert_includes stdout, "Skipping direct URL download."
      assert_empty stderr
      assert_empty package.downloads
      assert_equal [["brew", "install", "--cask", "ghcask/local/example"]], runner.commands
    end
  end

  def test_direct_url_requires_plain_cask_name
    with_tap do |tap|
      status, _stdout, stderr = run_install(
        ["owner/repo", "--url", "https://downloads.example.test/Example.dmg"],
        tap: tap,
        github: ExplodingGitHub.new
      )

      assert_equal 1, status
      assert_includes stderr, "Direct URL cask name must not look like a GitHub repository"
    end
  end

  def test_direct_url_rejects_github_only_options
    with_tap do |tap|
      status, _stdout, stderr = run_install(
        ["example", "--url", "https://downloads.example.test/Example.dmg", "--asset", "*arm64*"],
        tap: tap,
        github: ExplodingGitHub.new
      )

      assert_equal 1, status
      assert_includes stderr, "--asset is only available for GitHub source installs"
    end
  end

  def test_install_runs_homebrew_by_default
    with_tap do |tap|
      runner = FakeRunner.new(stdout: {
        "brew --cache --cask ghcask/local/example" => { stdout: File.join(Dir.tmpdir, "example-cache.dmg") },
        "brew install --cask ghcask/local/example" => {}
      })
      status, stdout, stderr, _github, _package, runner = run_install(["owner/repo"], tap: tap, runner: runner)

      assert_equal 0, status
      assert_includes stdout, "==> Downloading https://github.com/owner/repo/releases/download/v1.2.3/Example-arm64.dmg"
      assert_includes stdout, "Running: brew install --cask ghcask/local/example"
      assert_includes stdout, "Homebrew finished install for example."
      assert_empty stderr
      assert_equal [
        ["brew", "--cache", "--cask", "ghcask/local/example"],
        ["brew", "install", "--cask", "ghcask/local/example"]
      ], runner.commands
      assert_equal "installed", tap.registry.load["casks"]["example"]["install_state"]
    end
  end

  def test_install_trusts_generated_cask_after_writing_it
    with_tap do |tap|
      runner = FakeRunner.new(stdout: {
        "brew --cache --cask ghcask/local/example" => { stdout: File.join(Dir.tmpdir, "example-cache.dmg") },
        "brew trust --cask ghcask/local/example" => { stdout: "Trusted ghcask/local/example\n" },
        "brew install --cask ghcask/local/example" => {}
      })
      status, stdout, stderr, _github, _package, runner = run_install(["owner/repo", "--trust"], tap: tap, runner: runner)

      assert_equal 0, status
      assert_includes stdout, "Running: brew trust --cask ghcask/local/example"
      assert_includes stdout, "Trusted ghcask/local/example"
      assert_includes stdout, "Running: brew install --cask ghcask/local/example"
      assert_empty stderr
      assert_equal [
        ["brew", "trust", "--cask", "ghcask/local/example"],
        ["brew", "--cache", "--cask", "ghcask/local/example"],
        ["brew", "install", "--cask", "ghcask/local/example"]
      ], runner.commands
    end
  end

  def test_direct_url_install_trusts_generated_cask_after_writing_it
    with_tap do |tap|
      runner = FakeRunner.new(stdout: {
        "brew --cache --cask ghcask/local/example" => { stdout: File.join(Dir.tmpdir, "example-cache.dmg") },
        "brew trust --cask ghcask/local/example" => {},
        "brew install --cask ghcask/local/example" => {}
      })
      status, stdout, stderr, _github, _package, runner = run_install(
        ["example", "--url", "https://downloads.example.test/Example.dmg", "--trust"],
        tap: tap,
        github: ExplodingGitHub.new,
        runner: runner
      )

      assert_equal 0, status
      assert_includes stdout, "Running: brew trust --cask ghcask/local/example"
      assert_empty stderr
      assert_equal [
        ["brew", "trust", "--cask", "ghcask/local/example"],
        ["brew", "--cache", "--cask", "ghcask/local/example"],
        ["brew", "install", "--cask", "ghcask/local/example"]
      ], runner.commands
    end
  end

  def test_install_moves_downloaded_asset_into_homebrew_cache_before_install
    Dir.mktmpdir do |tmp|
      with_tap do |tap|
        source = File.join(tmp, "Example.dmg")
        File.write(source, "downloaded asset")
        cache_path = File.join(tmp, "downloads", "example-cache.dmg")
        runner = FakeRunner.new(stdout: {
          "brew --cache --cask ghcask/local/example" => { stdout: "#{cache_path}\n" },
          "brew install --cask ghcask/local/example" => {}
        })

        status, stdout, stderr, _github, _package, runner = run_install(
          ["owner/repo"],
          tap: tap,
          package: FakePackage.new(source),
          runner: runner
        )

        assert_equal 0, status
        assert_includes stdout, "Cached package for Homebrew: #{cache_path}"
        assert_empty stderr
        assert_equal "downloaded asset", File.read(cache_path)
        assert_equal [
          ["brew", "--cache", "--cask", "ghcask/local/example"],
          ["brew", "install", "--cask", "ghcask/local/example"]
        ], runner.commands
      end
    end
  end

  def test_repeated_install_treats_homebrew_success_warning_as_success
    with_tap do |tap|
      runner = FakeRunner.new(
        stdout: {
          "brew --cache --cask ghcask/local/example" => { stdout: File.join(Dir.tmpdir, "example-cache.dmg") },
          "brew install --cask ghcask/local/example" => {
            stderr: "Warning: Not upgrading example, the latest version is already installed\n"
          }
        }
      )
      status, stdout, stderr, _github, _package, _runner = run_install(["owner/repo"], tap: tap, runner: runner)

      assert_equal 0, status
      assert_includes stdout, "Running: brew install --cask ghcask/local/example"
      assert_includes stderr, "Warning: Not upgrading example"
      assert_includes stdout, "Homebrew finished install for example."
    end
  end

  def test_repeated_install_reuses_existing_local_cask_without_github_lookup
    with_tap do |tap|
      existing = existing_entry
      tap.init
      tap.registry.save("version" => 1, "casks" => { "example" => existing })
      Ghcask::Cask.write(File.join(tap.casks_dir, "example.rb"), existing)
      runner = FakeRunner.new(
        ok: true,
        stderr: "Warning: Not upgrading example, the latest version is already installed\n"
      )

      status, stdout, stderr, _github, package, runner = run_install(
        ["owner/repo"],
        tap: tap,
        github: ExplodingGitHub.new,
        runner: runner
      )

      assert_equal 0, status
      assert_includes stdout, "Using existing local cask."
      assert_includes stdout, "Skipping GitHub lookup."
      assert_includes stdout, "Running: brew install --cask ghcask/local/example"
      assert_includes stderr, "Warning: Not upgrading example"
      assert_empty package.downloads
      assert_equal [["brew", "install", "--cask", "ghcask/local/example"]], runner.commands
    end
  end

  def test_repeated_install_with_trust_reuses_existing_local_cask_without_trusting_again
    with_tap do |tap|
      existing = existing_entry
      tap.init
      tap.registry.save("version" => 1, "casks" => { "example" => existing })
      Ghcask::Cask.write(File.join(tap.casks_dir, "example.rb"), existing)
      runner = FakeRunner.new(stdout: {
        "brew install --cask ghcask/local/example" => {}
      })

      status, stdout, stderr, _github, package, runner = run_install(
        ["owner/repo", "--trust"],
        tap: tap,
        github: ExplodingGitHub.new,
        runner: runner
      )

      assert_equal 0, status
      assert_includes stdout, "Skipping GitHub lookup."
      refute_includes stdout, "Running: brew trust --cask ghcask/local/example"
      assert_empty stderr
      assert_empty package.downloads
      assert_equal [["brew", "install", "--cask", "ghcask/local/example"]], runner.commands
    end
  end

  def test_repeated_install_dry_run_reuses_existing_local_cask_without_github_lookup
    with_tap do |tap|
      existing = existing_entry
      tap.init
      tap.registry.save("version" => 1, "casks" => { "example" => existing })
      Ghcask::Cask.write(File.join(tap.casks_dir, "example.rb"), existing)

      status, stdout, stderr = run_install(
        ["owner/repo", "--dry-run", "--trust"],
        tap: tap,
        github: ExplodingGitHub.new
      )

      assert_equal 0, status
      assert_includes stdout, "Source: GitHub"
      assert_includes stdout, "Release policy: latest-stable"
      assert_includes stdout, "Version: 1.2.3"
      assert_includes stdout, "Asset URL: https://github.com/owner/repo/releases/download/v1.2.3/Example-arm64.dmg"
      assert_includes stdout, "App: Example.app"
      assert_includes stdout, "Would use existing local cask: yes"
      assert_includes stdout, "Would write cask: no"
      assert_includes stdout, "Would trust cask: no"
      assert_includes stdout, "Would cache package for Homebrew: no"
      assert_includes stdout, "Would install with Homebrew: yes"
      assert_includes stdout, "Would run: brew install --cask ghcask/local/example"
      assert_includes stdout, "Would use existing local cask without contacting GitHub."
      assert_empty stderr
    end
  end

  def test_direct_url_repeated_install_dry_run_reuses_existing_local_cask_without_download
    with_tap do |tap|
      existing = url_entry
      tap.init
      tap.registry.save("version" => 1, "casks" => { "example" => existing })
      Ghcask::Cask.write(File.join(tap.casks_dir, "example.rb"), existing)

      status, stdout, stderr, _github, package, runner = run_install(
        ["example", "--url", "https://downloads.example.test/Other.dmg", "--dry-run"],
        tap: tap,
        github: ExplodingGitHub.new
      )

      assert_equal 0, status
      assert_includes stdout, "Source: direct URL"
      assert_includes stdout, "URL: https://downloads.example.test/Example.dmg"
      assert_includes stdout, "App: Example.app"
      assert_includes stdout, "Would use existing local cask: yes"
      assert_includes stdout, "Would write cask: no"
      assert_includes stdout, "Would cache package for Homebrew: no"
      assert_includes stdout, "Would install with Homebrew: yes"
      assert_includes stdout, "Would use existing local cask without downloading the direct URL."
      assert_empty stderr
      assert_empty package.downloads
      assert_empty runner.commands
    end
  end

  def test_repeated_install_with_generation_option_refreshes_from_github
    with_tap do |tap|
      existing = existing_entry
      tap.init
      tap.registry.save("version" => 1, "casks" => { "example" => existing })
      Ghcask::Cask.write(File.join(tap.casks_dir, "example.rb"), existing)
      github = FakeGitHub.new(release)

      status, _stdout, _stderr = run_install(["owner/repo", "--version", "v1.2.3", "--no-install"], tap: tap, github: github)

      assert_equal 0, status
      assert_equal [["owner/repo", "latest-stable", "v1.2.3"]], github.requests
    end
  end

  def test_explicit_cask_name_overrides_app_inference
    with_tap do |tap|
      runner = FakeRunner.new(stdout: {
        "brew --cache --cask ghcask/local/custom-name" => { stdout: File.join(Dir.tmpdir, "custom-name-cache.dmg") },
        "brew install --cask ghcask/local/custom-name" => {}
      })
      status, _stdout, _stderr, _github, _package, runner = run_install(
        ["owner/repo", "--cask", "custom-name"],
        tap: tap,
        runner: runner
      )

      assert_equal 0, status
      assert_equal [
        ["brew", "--cache", "--cask", "ghcask/local/custom-name"],
        ["brew", "install", "--cask", "ghcask/local/custom-name"]
      ], runner.commands
      assert File.exist?(File.join(tap.casks_dir, "custom-name.rb"))
    end
  end

  def test_prerelease_records_policy
    with_tap do |tap|
      github = FakeGitHub.new(release)
      status, _stdout, _stderr = run_install(["owner/repo", "--prerelease", "--no-install"], tap: tap, github: github)

      assert_equal 0, status
      assert_equal [["owner/repo", "latest-prerelease", nil]], github.requests
      assert_equal "latest-prerelease", tap.registry.load["casks"]["example"]["release_policy"]
    end
  end

  def test_specific_version_records_requested_version_and_stable_policy
    with_tap do |tap|
      github = FakeGitHub.new(release)
      status, _stdout, _stderr = run_install(["owner/repo", "--version", "v1.2.3", "--no-install"], tap: tap, github: github)

      assert_equal 0, status
      assert_equal [["owner/repo", "latest-stable", "v1.2.3"]], github.requests
      entry = tap.registry.load["casks"]["example"]
      assert_equal "latest-stable", entry["release_policy"]
      assert_equal "v1.2.3", entry["requested_version"]
    end
  end

  def test_failed_homebrew_install_preserves_generated_files_and_prints_hint
    with_tap do |tap|
      runner = FakeRunner.new(stdout: {
        "brew --cache --cask ghcask/local/example" => { stdout: File.join(Dir.tmpdir, "example-cache.dmg") },
        "brew install --cask ghcask/local/example" => { stderr: "failed", ok: false }
      })
      status, _stdout, stderr = run_install(["owner/repo"], tap: tap, runner: runner)

      assert_equal 1, status
      assert_includes stderr, "Inspect with `brew cat --cask ghcask/local/example`"
      assert File.exist?(File.join(tap.casks_dir, "example.rb"))
    end
  end

  def test_failed_homebrew_trust_preserves_generated_files_and_prints_hint
    with_tap do |tap|
      runner = FakeRunner.new(stdout: {
        "brew --cache --cask ghcask/local/example" => { stdout: File.join(Dir.tmpdir, "example-cache.dmg") },
        "brew trust --cask ghcask/local/example" => { stderr: "trust failed", ok: false }
      })
      status, _stdout, stderr = run_install(["owner/repo", "--trust"], tap: tap, runner: runner)

      assert_equal 1, status
      assert_includes stderr, "Homebrew trust failed: trust failed"
      assert_includes stderr, "brew trust --cask ghcask/local/example"
      assert File.exist?(File.join(tap.casks_dir, "example.rb"))
    end
  end

  def existing_entry
    {
      "repo" => "owner/repo",
      "source_type" => "github",
      "cask" => "example",
      "name" => "Example",
      "app" => "Example.app",
      "release_policy" => "latest-stable",
      "requested_version" => nil,
      "asset_pattern" => nil,
      "arch" => "arm64",
      "version" => "1.2.3",
      "release_tag" => "v1.2.3",
      "asset_name" => "Example-arm64.dmg",
      "asset_url" => "https://github.com/owner/repo/releases/download/v1.2.3/Example-arm64.dmg",
      "sha256" => "abc123",
      "updated_at" => "2026-01-01T00:00:00Z"
    }
  end

  def url_entry
    {
      "repo" => nil,
      "source_type" => "url",
      "cask" => "example",
      "name" => "Example",
      "app" => "Example.app",
      "release_policy" => "url",
      "requested_version" => nil,
      "asset_pattern" => nil,
      "arch" => nil,
      "version" => "1.0.0",
      "release_tag" => nil,
      "asset_name" => "Example.dmg",
      "asset_url" => "https://downloads.example.test/Example.dmg",
      "homepage" => "https://downloads.example.test",
      "sha256" => "abc123",
      "install_state" => "installed",
      "updated_at" => "2026-01-01T00:00:00Z"
    }
  end
end

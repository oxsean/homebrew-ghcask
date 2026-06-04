# frozen_string_literal: true

require "test_helper"
require "tmpdir"

require "ghcask/archive"
require "ghcask/cask"

class ArchiveTest < Minitest::Test
  FakeResult = Struct.new(:stdout, :stderr, :ok, keyword_init: true) do
    def success?
      ok
    end
  end

  class FakeRunner
    attr_reader :commands

    def initialize(responses = {})
      @responses = responses
      @commands = []
    end
  end

  def entry(cask: "example", install_state: "installed")
    {
      "repo" => "owner/repo",
      "cask" => cask,
      "name" => "Example",
      "app" => "Example.app",
      "release_policy" => "latest-stable",
      "requested_version" => nil,
      "asset_pattern" => nil,
      "arch" => "arm64",
      "version" => "1.0.0",
      "release_tag" => "v1.0.0",
      "asset_name" => "Example.dmg",
      "asset_url" => "https://example.test/Example.dmg",
      "sha256" => "abc123",
      "install_state" => install_state,
      "updated_at" => "2026-01-01T00:00:00Z"
    }
  end

  def dump_payload(registry:, casks:)
    {
      "version" => Ghcask::Archive::FORMAT_VERSION,
      "registry" => registry,
      "casks" => casks
    }
  end

  def with_tap(entries = { "example" => entry })
    Dir.mktmpdir do |homebrew|
      tap = Ghcask::LocalTap.new(homebrew_repository: homebrew)
      tap.init
      tap.registry.save("version" => 1, "casks" => entries)
      entries.each_value do |item|
        Ghcask::Cask.write(File.join(tap.casks_dir, "#{item.fetch("cask")}.rb"), item)
      end
      yield tap
    end
  end

  def run_archive(argv, tap:, command:, runner: nil)
    stdout = StringIO.new
    stderr = StringIO.new
    archive = Ghcask::Archive.new(argv, stdout: stdout, stderr: stderr, tap: tap, runner: runner || Ghcask::CommandRunner.new)
    status = archive.public_send(command)
    [status, stdout.string, stderr.string]
  end

  def test_dump_writes_default_json_with_filtered_registry
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        entries = {
          "example" => entry(install_state: "generated"),
          "missing" => entry(cask: "missing"),
          "generated" => entry(cask: "generated", install_state: "generated")
        }
        with_tap(entries) do |tap|
          FileUtils.rm_f(File.join(tap.casks_dir, "missing.rb"))

          status, stdout, stderr = run_archive([], tap: tap, command: :dump)

          assert_equal 0, status
          assert_includes stdout, "Brewghcask.json"
          assert_empty stderr
          assert File.exist?("Brewghcask.json")

          payload = JSON.parse(File.read("Brewghcask.json"))
          assert_equal 1, payload["version"]
          assert_equal %w[example generated], payload.fetch("registry").fetch("casks").keys.sort
          assert_equal %w[example generated], payload.fetch("casks").keys.sort
          assert_includes payload.fetch("casks").fetch("example"), 'cask "example"'
        end
      end
    end
  end

  def test_dump_refuses_to_overwrite_without_force
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Brewghcask.json")
      File.write(path, "exists")
      with_tap do |tap|
        status, _stdout, stderr = run_archive(["--file", path], tap: tap, command: :dump)

        assert_equal 1, status
        assert_includes stderr, "dump file already exists"
      end
    end
  end

  def test_dump_dry_run_prints_plan_without_writing
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Brewghcask.json")
      entries = {
        "example" => entry(install_state: "generated"),
        "missing" => entry(cask: "missing")
      }
      with_tap(entries) do |tap|
        FileUtils.rm_f(File.join(tap.casks_dir, "missing.rb"))
        status, stdout, stderr = run_archive(["--file", path, "--dry-run"], tap: tap, command: :dump)

        assert_equal 0, status
        assert_includes stdout, "Would write #{path}"
        assert_includes stdout, "Registry entries to export: 1"
        assert_includes stdout, "Casks to export: 1"
        assert_empty stderr
        refute File.exist?(path)
      end
    end
  end

  def test_dump_dry_run_does_not_require_force_for_existing_output
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Brewghcask.json")
      File.write(path, "exists")
      with_tap do |tap|
        status, stdout, stderr = run_archive(["--file", path, "--dry-run"], tap: tap, command: :dump)

        assert_equal 0, status
        assert_includes stdout, "Would write #{path}"
        assert_empty stderr
        assert_equal "exists", File.read(path)
      end
    end
  end

  def test_restore_imports_json_dump
    Dir.mktmpdir do |dir|
      item = entry
      path = File.join(dir, "Brewghcask.json")
      File.write(path, JSON.pretty_generate(dump_payload(
        registry: { "version" => 1, "casks" => { "example" => item } },
        casks: { "example" => "cask \"example\" do\nend\n" }
      )) + "\n")

      Dir.mktmpdir do |homebrew|
        tap = Ghcask::LocalTap.new(homebrew_repository: homebrew)
        status, stdout, stderr = run_archive(["--file", path], tap: tap, command: :restore)

        assert_equal 0, status
        assert_includes stdout, "Restored"
        assert_empty stderr
        assert File.exist?(File.join(tap.casks_dir, "example.rb"))
        assert_equal "owner/repo", tap.registry.load["casks"]["example"]["repo"]
      end
    end
  end

  def test_restore_dry_run_validates_and_prints_plan_without_writing
    Dir.mktmpdir do |dir|
      item = entry
      path = File.join(dir, "Brewghcask.json")
      File.write(path, JSON.pretty_generate(dump_payload(
        registry: { "version" => 1, "casks" => { "example" => item } },
        casks: { "example" => "cask \"example\" do\nend\n" }
      )) + "\n")

      Dir.mktmpdir do |homebrew|
        tap = Ghcask::LocalTap.new(homebrew_repository: homebrew)
        status, stdout, stderr = run_archive(["--file", path, "--dry-run"], tap: tap, command: :restore)

        assert_equal 0, status
        assert_includes stdout, "Would restore #{path}"
        assert_includes stdout, "Casks in dump: 1"
        assert_includes stdout, "Registry entries in dump: 1"
        assert_includes stdout, "Would overwrite casks: none"
        assert_empty stderr
        refute File.exist?(tap.registry_path)
        refute File.exist?(File.join(tap.casks_dir, "example.rb"))
      end
    end
  end

  def test_restore_merges_registry_when_no_cask_conflicts
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Brewghcask.json")
      File.write(path, JSON.pretty_generate(dump_payload(
        registry: { "version" => 1, "casks" => { "example" => entry } },
        casks: { "example" => "cask \"example\" do\nend\n" }
      )) + "\n")

      with_tap("old" => entry(cask: "old")) do |tap|
        status, _stdout, stderr = run_archive(["--file", path], tap: tap, command: :restore)

        assert_equal 0, status
        assert_empty stderr
        assert File.exist?(File.join(tap.casks_dir, "example.rb"))
        assert File.exist?(File.join(tap.casks_dir, "old.rb"))
        assert_equal %w[example old], tap.registry.load["casks"].keys.sort
      end
    end
  end

  def test_restore_refuses_to_overwrite_existing_cask_without_force
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Brewghcask.json")
      File.write(path, JSON.pretty_generate(dump_payload(
        registry: { "version" => 1, "casks" => { "example" => entry } },
        casks: { "example" => "cask \"example\" do\nend\n" }
      )) + "\n")

      with_tap("example" => entry) do |tap|
        status, _stdout, stderr = run_archive(["--file", path], tap: tap, command: :restore)

        assert_equal 1, status
        assert_includes stderr, "local ghcask data already exists"
      end
    end
  end

  def test_restore_force_overwrites_same_cask_but_preserves_others
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Brewghcask.json")
      incoming = entry
      incoming["version"] = "2.0.0"
      incoming["release_tag"] = "v2.0.0"
      incoming["sha256"] = "def456"
      File.write(path, JSON.pretty_generate(dump_payload(
        registry: { "version" => 1, "casks" => { "example" => incoming } },
        casks: { "example" => "cask \"example\" do\nend\n" }
      )) + "\n")

      with_tap(
        "example" => entry,
        "old" => entry(cask: "old")
      ) do |tap|
        status, _stdout, stderr = run_archive(["--file", path, "--force"], tap: tap, command: :restore)

        assert_equal 0, status
        assert_empty stderr
        assert File.exist?(File.join(tap.casks_dir, "example.rb"))
        assert File.exist?(File.join(tap.casks_dir, "old.rb"))
        registry = tap.registry.load["casks"]
        assert_equal %w[example old], registry.keys.sort
        assert_equal "v2.0.0", registry.fetch("example").fetch("release_tag")
        assert_equal "def456", registry.fetch("example").fetch("sha256")
        assert_equal "v1.0.0", registry.fetch("old").fetch("release_tag")
      end
    end
  end

  def test_restore_force_dry_run_reports_same_name_overwrites_without_writing
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Brewghcask.json")
      incoming = entry
      incoming["release_tag"] = "v2.0.0"
      File.write(path, JSON.pretty_generate(dump_payload(
        registry: { "version" => 1, "casks" => { "example" => incoming } },
        casks: { "example" => "cask \"example\" do\nend\n" }
      )) + "\n")

      with_tap("example" => entry, "old" => entry(cask: "old")) do |tap|
        status, stdout, stderr = run_archive(["--file", path, "--force", "--dry-run"], tap: tap, command: :restore)

        assert_equal 0, status
        assert_includes stdout, "Would overwrite casks: example"
        assert_includes stdout, "Registry entries after merge: 2"
        assert_empty stderr
        assert_equal "v1.0.0", tap.registry.load["casks"]["example"]["release_tag"]
        assert_includes File.read(File.join(tap.casks_dir, "example.rb")), 'version "1.0.0"'
      end
    end
  end

  def test_restore_dry_run_reports_same_name_overwrites_without_force
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Brewghcask.json")
      incoming = entry
      incoming["release_tag"] = "v2.0.0"
      File.write(path, JSON.pretty_generate(dump_payload(
        registry: { "version" => 1, "casks" => { "example" => incoming } },
        casks: { "example" => "cask \"example\" do\n  version \"2.0.0\"\nend\n" }
      )) + "\n")

      with_tap("example" => entry) do |tap|
        status, stdout, stderr = run_archive(["--file", path, "--dry-run"], tap: tap, command: :restore)

        assert_equal 0, status
        assert_includes stdout, "Would overwrite casks: example"
        assert_empty stderr
        assert_equal "v1.0.0", tap.registry.load["casks"]["example"]["release_tag"]
        assert_includes File.read(File.join(tap.casks_dir, "example.rb")), 'version "1.0.0"'
      end
    end
  end

  def test_restore_rejects_invalid_cask_name
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad.json")
      File.write(path, JSON.pretty_generate(dump_payload(
        registry: { "version" => 1, "casks" => { "../bad" => entry(cask: "../bad") } },
        casks: { "../bad" => "nope" }
      )) + "\n")

      Dir.mktmpdir do |homebrew|
        tap = Ghcask::LocalTap.new(homebrew_repository: homebrew)
        status, _stdout, stderr = run_archive(["--file", path], tap: tap, command: :restore)

        assert_equal 1, status
        assert_includes stderr, "invalid cask name"
        refute File.exist?(tap.registry_path)
      end
    end
  end

  def test_restore_rejects_missing_cask_content_declared_in_registry
    Dir.mktmpdir do |dir|
      path = File.join(dir, "missing-cask.json")
      File.write(path, JSON.pretty_generate(dump_payload(
        registry: { "version" => 1, "casks" => { "example" => entry } },
        casks: {}
      )) + "\n")

      Dir.mktmpdir do |homebrew|
        tap = Ghcask::LocalTap.new(homebrew_repository: homebrew)
        status, _stdout, stderr = run_archive(["--file", path], tap: tap, command: :restore)

        assert_equal 1, status
        assert_includes stderr, "dump file is missing cask content for registry entry: example"
        refute File.exist?(tap.registry_path)
      end
    end
  end

  def test_file_and_global_are_mutually_exclusive
    with_tap do |tap|
      status, _stdout, stderr = run_archive(["--file", "x.json", "--global"], tap: tap, command: :dump)

      assert_equal 1, status
      assert_includes stderr, "--file and --global cannot be used together"
    end
  end

  def test_global_dump_uses_homebrew_style_home_path
    Dir.mktmpdir do |home|
      previous = ENV["HOME"]
      ENV["HOME"] = home
      with_tap("example" => entry(install_state: "generated")) do |tap|
        status, stdout, stderr = run_archive(["--global"], tap: tap, command: :dump)

        assert_equal 0, status
        assert_empty stderr
        path = File.join(home, ".homebrew", "Brewghcask.json")
        assert File.exist?(path)
        assert_includes stdout, path
      end
    ensure
      ENV["HOME"] = previous
    end
  end
end

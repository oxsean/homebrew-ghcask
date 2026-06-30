# frozen_string_literal: true

require "test_helper"

class ArchiveTest < GhcaskTest::Case
  def archiver(args, brew: nil)
    @brew = brew || GhcaskTest::FakeBrew.new
    Ghcask::Commands::Archive.new(args, stdout: @out, stderr: @err, tap: tap, brew: @brew, github: GhcaskTest::ExplodingGitHub.new)
  end

  def dump_path
    File.join(@tmp, "Brewghcask.json")
  end

  def test_dump_writes_registry_and_casks
    seed(entry("quarantine" => false))
    code = archiver(["--file", dump_path]).dump
    assert_equal 0, code

    payload = JSON.parse(File.read(dump_path))
    assert_equal 1, payload["version"]
    assert_equal false, payload["registry"]["casks"]["app"]["quarantine"]
    assert_includes payload["casks"]["app"], %(cask "app" do)
  end

  def test_dump_skips_uninstalled_entries
    seed(entry("install_state" => "uninstalled"))
    archiver(["--file", dump_path]).dump
    payload = JSON.parse(File.read(dump_path))
    assert_empty payload["registry"]["casks"]
  end

  def test_dump_refuses_to_overwrite_without_force
    seed(entry)
    File.write(dump_path, "{}")
    code = archiver(["--file", dump_path]).dump
    assert_equal 1, code
    assert_includes stderr, "Re-run with --force"
  end

  def test_dump_dry_run
    seed(entry)
    archiver(["--file", dump_path, "--dry-run"]).dump
    refute File.exist?(dump_path)
    assert_includes stdout, "Would write"
  end

  def test_restore_round_trip_preserves_quarantine
    seed(entry("quarantine" => false))
    archiver(["--file", dump_path]).dump

    # Wipe the tap, then restore from the dump.
    FileUtils.remove_entry(tap.root)
    @tap = nil
    code = archiver(["--file", dump_path]).restore
    assert_equal 0, code
    assert File.exist?(tap.cask_path("app"))
    refute catalog["app"].quarantine?
  end

  def test_restore_conflict_without_force
    seed(entry)
    archiver(["--file", dump_path]).dump
    code = archiver(["--file", dump_path]).restore
    assert_equal 1, code
    assert_includes stderr, "local casks already exist"
  end

  def test_restore_force_overwrites
    seed(entry)
    archiver(["--file", dump_path]).dump
    code = archiver(["--file", dump_path, "--force"]).restore
    assert_equal 0, code
    assert_includes stdout, "Restored"
  end

  def test_restore_install_installs_only_missing_casks
    seed(entry, url_entry)
    archiver(["--file", dump_path]).dump
    FileUtils.remove_entry(tap.root)
    @tap = nil

    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" }) # app present, directapp missing
    code = archiver(["--file", dump_path, "--install"], brew: brew).restore
    assert_equal 0, code
    assert_equal ["directapp"], brew.installs.map { |i| i[:name] }
    assert_includes stdout, "app: already installed"
    assert_includes stdout, "Installed directapp."
  end

  def test_restore_imports_as_generated_not_dumps_install_state
    seed(entry("install_state" => "installed")) # old machine had it installed
    archiver(["--file", dump_path]).dump
    FileUtils.remove_entry(tap.root)
    @tap = nil
    archiver(["--file", dump_path]).restore # no --install: nothing is installed yet
    assert_equal "generated", catalog["app"].install_state
  end

  def test_restore_install_persists_installed_state
    seed(entry("install_state" => "installed"))
    archiver(["--file", dump_path]).dump
    FileUtils.remove_entry(tap.root)
    @tap = nil
    archiver(["--file", dump_path, "--install"], brew: GhcaskTest::FakeBrew.new(installed_casks: [])).restore
    assert_equal "installed", catalog["app"].install_state # read back from disk, proving it was saved
  end

  def test_restore_install_dry_run_does_not_install
    seed(entry)
    archiver(["--file", dump_path]).dump
    code = archiver(["--file", dump_path, "--install", "--dry-run"]).restore
    assert_equal 0, code
    assert_includes stdout, "Would install restored casks"
    assert_empty @brew.installs
  end

  def test_restore_missing_file
    code = archiver(["--file", dump_path]).restore
    assert_equal 1, code
    assert_includes stderr, "dump file does not exist"
  end

  def test_file_and_global_conflict
    code = archiver(["--file", dump_path, "--global"]).dump
    assert_equal 1, code
    assert_includes stderr, "--file and --global cannot be used together"
  end
end

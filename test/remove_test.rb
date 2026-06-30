# frozen_string_literal: true

require "test_helper"

class RemoveTest < GhcaskTest::Case
  def remover(args, brew: nil)
    @brew = brew || GhcaskTest::FakeBrew.new
    Ghcask::Commands::Remove.new(args, stdout: @out, stderr: @err, tap: tap, brew: @brew, github: GhcaskTest::ExplodingGitHub.new)
  end

  def test_uninstall_marks_entry_and_delegates
    seed(entry)
    code = remover(%w[app]).uninstall
    assert_equal 0, code
    assert_equal "uninstalled", catalog["app"].install_state
    assert_equal [{ name: "app", force: false }], @brew.uninstalls
  end

  def test_uninstall_force
    seed(entry)
    remover(%w[app --force]).uninstall
    assert_equal [{ name: "app", force: true }], @brew.uninstalls
  end

  def test_uninstall_passes_through_after_dashdash
    seed(entry)
    remover(%w[app -- --zap]).uninstall
    assert_equal ["--zap"], @brew.uninstalls.first[:extra]
  end

  def test_uninstall_forwards_verbose_flag
    seed(entry)
    remover(%w[app -v]).uninstall
    assert_equal ["--verbose"], @brew.uninstalls.first[:extra]
  end

  def test_uninstall_dry_run_changes_nothing
    seed(entry)
    remover(%w[app --dry-run]).uninstall
    assert_equal "installed", catalog["app"].install_state
    assert_empty @brew.uninstalls
    assert_includes stdout, "Would uninstall app with Homebrew."
  end

  def test_uninstall_multiple_targets
    seed(entry, url_entry)
    remover(%w[app directapp]).uninstall
    assert_equal %w[app directapp], @brew.uninstalls.map { |u| u[:name] }
  end

  def test_uninstall_zap_forwards_to_brew
    seed(entry)
    remover(%w[app --zap]).uninstall
    assert_equal [{ name: "app", force: false, zap: true }], @brew.uninstalls
  end

  def test_cleanup_removes_entry_for_deleted_cask_file
    seed(entry)
    File.delete(tap.cask_path("app"))
    remover([]).cleanup
    refute_includes catalog.names, "app"
    assert_includes stdout, "registry entry for deleted cask file: app"
  end

  def test_cleanup_removes_uninstalled_entries
    seed(entry("install_state" => "uninstalled"))
    remover([]).cleanup
    refute_includes catalog.names, "app"
  end

  def test_cleanup_targeted_removes_regardless_of_state
    seed(entry("install_state" => "installed"))
    remover(%w[app]).cleanup
    refute_includes catalog.names, "app"
    refute File.exist?(tap.cask_path("app"))
  end

  def test_cleanup_removes_orphan_cask_file
    seed(entry)
    cat = tap.registry.load
    cat.delete("app")
    tap.registry.save(cat) # cask file remains, registry entry gone → orphan
    remover([]).cleanup
    refute File.exist?(tap.cask_path("app"))
    assert_includes stdout, "generated cask file without a registry entry: app"
  end

  def test_cleanup_dry_run_keeps_records
    seed(entry("install_state" => "uninstalled"))
    remover(%w[--dry-run]).cleanup
    assert_includes catalog.names, "app"
    assert_includes stdout, "Would remove"
  end

  def test_cleanup_reports_when_clean
    seed(entry("install_state" => "installed"))
    remover([], brew: GhcaskTest::FakeBrew.new(installed_casks: Set.new(%w[app]))).cleanup
    assert_includes stdout, "No stale local casks found."
  end
end

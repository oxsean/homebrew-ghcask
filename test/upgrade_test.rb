# frozen_string_literal: true

require "test_helper"

class UpgradeTest < GhcaskTest::Case
  def upgrader(args, github:, brew: nil, package: nil, quarantine: nil)
    @brew = brew || GhcaskTest::FakeBrew.new
    @quarantine = quarantine || GhcaskTest::FakeQuarantine.new
    Ghcask::Commands::Upgrade.new(
      args, stdout: @out, stderr: @err, github: github, tap: tap,
      package: package || GhcaskTest::FakePackage.new, brew: @brew, quarantine: @quarantine
    )
  end

  def gh(tag, assets: [["App-arm64.dmg", "https://example.com/App-#{tag}.dmg"]])
    GhcaskTest::FakeGitHub.new(release(tag: tag, assets: assets))
  end

  # --- update --------------------------------------------------------------

  def test_update_refreshes_metadata_without_upgrading
    seed(entry("version" => "1.0.0", "release_tag" => "v1.0.0"))
    code = upgrader([], github: gh("v2.0.0")).update
    assert_equal 0, code
    assert_equal "2.0.0", catalog["app"].version
    assert_includes stdout, "app: refreshed to v2.0.0"
    assert_empty @brew.upgrades
  end

  def test_update_already_current
    seed(entry("release_tag" => "v1.0.0", "asset_name" => "App-arm64.dmg"))
    upgrader([], github: gh("v1.0.0")).update
    assert_includes stdout, "app: already current"
    refute_includes stdout, "refreshed" # not re-fetched
  end

  def test_update_force_refetches_already_current
    seed(entry("release_tag" => "v1.0.0", "asset_name" => "App-arm64.dmg"))
    upgrader(%w[--force], github: gh("v1.0.0")).update
    assert_includes stdout, "app: refreshed to v1.0.0" # bypassed the already-current skip
    refute_includes stdout, "already current"
  end

  def test_update_skips_url_casks
    seed(url_entry)
    upgrader([], github: GhcaskTest::ExplodingGitHub.new).update
    assert_includes stdout, "directapp: direct URL cask, skipping source refresh"
  end

  def test_update_rejects_named_targets
    seed(entry)
    code = upgrader(%w[app], github: GhcaskTest::ExplodingGitHub.new).update
    assert_equal 1, code
    assert_includes stderr, "update does not accept cask names"
  end

  def test_update_dry_run_does_not_persist
    seed(entry("version" => "1.0.0", "release_tag" => "v1.0.0"))
    upgrader(%w[--dry-run], github: gh("v2.0.0")).update
    assert_equal "1.0.0", catalog["app"].version
  end

  # --- upgrade -------------------------------------------------------------

  def test_upgrade_runs_brew_when_version_differs
    seed(entry("version" => "1.0.0", "release_tag" => "v1.0.0", "install_state" => "installed"))
    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" })
    upgrader([], github: gh("v2.0.0"), brew: brew).upgrade
    assert_equal %w[app], brew.upgrades.map { |u| u[:name] }
  end

  def test_upgrade_skips_brew_when_already_at_generated_version
    seed(entry("version" => "1.0.0", "release_tag" => "v1.0.0"))
    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" })
    upgrader([], github: gh("v1.0.0"), brew: brew).upgrade
    assert_empty brew.upgrades
  end

  def test_upgrade_skips_pinned_cask
    seed(entry("requested_version" => "v1.0.0", "version" => "1.0.0", "release_tag" => "v1.0.0"))
    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" })
    upgrader([], github: gh("v1.0.0"), brew: brew).upgrade
    assert_includes stdout, "app: already current"
    assert_empty brew.upgrades
    assert catalog["app"].pinned?, "upgrade must leave the pin in place (unpin to move past it)"
  end

  def test_upgrade_passes_through_after_dashdash
    seed(entry("version" => "1.0.0", "release_tag" => "v1.0.0"))
    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" })
    upgrader(%w[app -- --verbose], github: gh("v2.0.0"), brew: brew).upgrade
    assert_equal ["--verbose"], brew.upgrades.first[:extra]
  end

  def test_upgrade_forwards_verbose_flag
    seed(entry("version" => "1.0.0", "release_tag" => "v1.0.0"))
    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" })
    upgrader(%w[app -v], github: gh("v2.0.0"), brew: brew).upgrade
    assert_equal ["--verbose"], brew.upgrades.first[:extra]
  end

  def test_upgrade_forwards_force_flag
    seed(entry("version" => "1.0.0", "release_tag" => "v1.0.0"))
    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" })
    upgrader(%w[app -f], github: gh("v2.0.0"), brew: brew).upgrade
    assert_equal true, brew.upgrades.first[:force]
  end

  def test_upgrade_force_does_not_reupgrade_current_cask
    seed(entry("version" => "1.0.0", "release_tag" => "v1.0.0"))
    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" })
    upgrader(%w[app --force], github: gh("v1.0.0"), brew: brew).upgrade
    assert_empty brew.upgrades, "force must not re-upgrade an already-current cask (that is reinstall --force)"
  end

  def test_upgrade_reapplies_quarantine_release_after_upgrade
    seed(entry("quarantine" => false, "version" => "1.0.0", "release_tag" => "v1.0.0"))
    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" }, app_paths: { "app" => ["/Applications/App.app"] })
    upgrader([], github: gh("v2.0.0"), brew: brew).upgrade
    assert_equal %w[app], brew.upgrades.map { |u| u[:name] }
    assert_equal [["/Applications/App.app"]], @quarantine.released
  end

  def test_upgrade_does_not_release_quarantine_for_quarantined_cask
    seed(entry("quarantine" => true, "version" => "1.0.0", "release_tag" => "v1.0.0"))
    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" }, app_paths: { "app" => ["/Applications/App.app"] })
    upgrader([], github: gh("v2.0.0"), brew: brew).upgrade
    assert_empty @quarantine.released
  end

  def test_update_skips_auto_updates_app
    seed(entry("auto_updates" => true))
    upgrader([], github: GhcaskTest::ExplodingGitHub.new).update
    assert_includes stdout, "app: self-updating app (auto_updates), skipping"
  end

  def test_upgrade_skips_auto_updates_app
    seed(entry("auto_updates" => true, "version" => "1.0.0", "release_tag" => "v1.0.0", "install_state" => "installed"))
    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" })
    upgrader([], github: GhcaskTest::ExplodingGitHub.new, brew: brew).upgrade
    assert_empty brew.upgrades
  end

  def test_upgrade_greedy_includes_auto_updates_app
    seed(entry("auto_updates" => true, "version" => "1.0.0", "release_tag" => "v1.0.0", "install_state" => "installed"))
    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" })
    upgrader(%w[--greedy], github: gh("v2.0.0"), brew: brew).upgrade
    assert_equal %w[app], brew.upgrades.map { |u| u[:name] }
  end

  # --- outdated ------------------------------------------------------------

  def test_outdated_compares_installed_against_latest
    seed(entry("version" => "1.0.0", "release_tag" => "v1.0.0"))
    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" })
    upgrader([], github: gh("v2.0.0"), brew: brew).outdated
    assert_includes stdout, "app: 1.0.0 -> 2.0.0"
  end

  def test_outdated_skips_auto_updates_without_greedy
    seed(entry("auto_updates" => true, "version" => "1.0.0", "release_tag" => "v1.0.0"))
    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" })
    upgrader([], github: gh("v2.0.0"), brew: brew).outdated
    assert_empty stdout
  end

  def test_outdated_greedy_includes_auto_updates
    seed(entry("auto_updates" => true, "version" => "1.0.0", "release_tag" => "v1.0.0"))
    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" })
    upgrader(%w[--greedy], github: gh("v2.0.0"), brew: brew).outdated
    assert_includes stdout, "app: 1.0.0 -> 2.0.0"
  end

  def test_outdated_silent_when_current
    seed(entry("version" => "1.0.0", "release_tag" => "v1.0.0"))
    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" })
    upgrader([], github: gh("v1.0.0"), brew: brew).outdated
    assert_empty stdout # brew prints nothing for up-to-date casks
  end

  def test_outdated_silent_when_not_installed
    seed(entry("release_tag" => "v1.0.0"))
    upgrader([], github: GhcaskTest::ExplodingGitHub.new).outdated
    assert_empty stdout # not installed is skipped before the GitHub lookup
  end

  def test_outdated_flags_app_behind_an_updated_cask
    # cask was advanced to v2 (e.g. via `update`) but the app is still v1:
    # outdated must still report the app as behind, unlike the old cask-tag check.
    seed(entry("version" => "2.0.0", "release_tag" => "v2.0.0"))
    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" })
    upgrader([], github: gh("v2.0.0"), brew: brew).outdated
    assert_includes stdout, "app: 1.0.0 -> 2.0.0"
  end

  def test_outdated_lists_pinned_cask_against_track_with_annotation
    # Like brew: a pinned cask behind the latest is listed (not skipped), annotated.
    seed(entry("requested_version" => "v1.0.0", "version" => "1.0.0", "release_tag" => "v1.0.0"))
    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" })
    upgrader([], github: gh("v2.0.0"), brew: brew).outdated
    assert_includes stdout, "app: 1.0.0 -> 2.0.0 [pinned at v1.0.0]"
  end

  def test_outdated_all_lists_not_installed_casks
    seed(entry("release_tag" => "v1.0.0")) # generated, not installed
    upgrader(%w[--all], github: GhcaskTest::ExplodingGitHub.new).outdated # no fetch for not-installed
    assert_includes stdout, "app: not installed"
  end

  def test_outdated_all_lists_current_casks
    seed(entry("version" => "1.0.0", "release_tag" => "v1.0.0"))
    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" })
    upgrader(%w[--all], github: gh("v1.0.0"), brew: brew).outdated
    assert_includes stdout, "app: current 1.0.0"
  end

  def test_outdated_skips_auto_updates_by_default
    seed(entry("auto_updates" => true))
    upgrader([], github: GhcaskTest::ExplodingGitHub.new).outdated
    refute_includes stdout, "app:"
  end

  def test_outdated_all_includes_auto_updates
    seed(entry("auto_updates" => true, "version" => "1.0.0", "release_tag" => "v1.0.0"))
    brew = GhcaskTest::FakeBrew.new(installed_versions: { "app" => "1.0.0" })
    upgrader(%w[--all], github: gh("v2.0.0"), brew: brew).outdated
    assert_includes stdout, "app: 1.0.0 -> 2.0.0"
  end

  def test_outdated_skips_url_by_default
    seed(url_entry)
    upgrader([], github: GhcaskTest::ExplodingGitHub.new).outdated
    refute_includes stdout, "directapp"
  end

  def test_outdated_all_reports_url_not_checkable
    seed(url_entry)
    upgrader(%w[--all], github: GhcaskTest::ExplodingGitHub.new).outdated
    assert_includes stdout, "directapp: direct URL cask, not checkable"
  end
end

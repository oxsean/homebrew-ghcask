# frozen_string_literal: true

require "test_helper"

class AssetSelectorTest < GhcaskTest::Case
  def select(names, arch: "arm64", pattern: nil)
    assets = names.map { |n| asset(n) }
    Ghcask::AssetSelector.new(assets, arch: arch).select(pattern: pattern)
  end

  def test_prefers_matching_arch
    chosen = select(%w[App-arm64.dmg App-x86_64.dmg], arch: "arm64")
    assert_equal "App-arm64.dmg", chosen.name
  end

  def test_prefers_dmg_over_zip_when_arch_ties
    chosen = select(%w[App-arm64.zip App-arm64.dmg], arch: "arm64")
    assert_equal "App-arm64.dmg", chosen.name
  end

  def test_universal_is_accepted
    chosen = select(%w[App-universal.dmg], arch: "arm64")
    assert_equal "App-universal.dmg", chosen.name
  end

  def test_single_plausible_asset_wins_without_arch_marker
    chosen = select(%w[App.dmg], arch: "arm64")
    assert_equal "App.dmg", chosen.name
  end

  def test_selects_pkg_installer
    assert_equal "Foo.pkg", select(%w[Foo.pkg], arch: "arm64").name
  end

  def test_dmg_preferred_over_pkg_on_tie
    chosen = select(%w[Foo-arm64.pkg Foo-arm64.dmg], arch: "arm64")
    assert_equal "Foo-arm64.dmg", chosen.name
  end

  def test_excludes_non_macos_assets
    assert_raises(Ghcask::NoAssetMatchError) { select(%w[App-linux.tar.gz App.exe App-windows.zip], arch: "arm64") }
  end

  def test_ambiguous_raises_with_candidates
    error = assert_raises(Ghcask::AmbiguousAssetError) { select(%w[App-one.dmg App-two.dmg], arch: "arm64") }
    assert_equal 2, error.candidates.length
    assert_includes error.message, "--asset 'App-one.dmg'" # actionable hint, not just names
  end

  def test_pattern_override
    chosen = select(%w[App-one.dmg App-two.dmg], pattern: "*two*")
    assert_equal "App-two.dmg", chosen.name
  end

  def test_pattern_no_match
    assert_raises(Ghcask::NoAssetMatchError) { select(%w[App.dmg], pattern: "*nope*") }
  end

  def test_macos_candidate_filters_non_macos
    selector = Ghcask::AssetSelector.new([], arch: "arm64")
    assert selector.macos_candidate?(asset("App-arm64.dmg"))
    assert selector.macos_candidate?(asset("App-x86_64.dmg")) # mac, other arch, still a candidate
    assert selector.macos_candidate?(asset("tool-aarch64-apple-darwin")) # bare mac binary
    refute selector.macos_candidate?(asset("App-x86_64-unknown-linux-gnu.tar.gz"))
    refute selector.macos_candidate?(asset("App.exe"))
    refute selector.macos_candidate?(asset("App_amd64.deb"))
    refute selector.macos_candidate?(asset("checksums.txt"))
  end

  def test_wrong_arch_is_rejected_when_correct_exists
    chosen = select(%w[App-x86_64.dmg App-arm64.dmg], arch: "arm64")
    assert_equal "App-arm64.dmg", chosen.name
  end

  def test_selects_xz_tarball
    assert_equal "tool-arm64.tar.xz", select(%w[tool-arm64.tar.xz], arch: "arm64").name
  end

  def test_selects_bare_macos_binary
    chosen = select(%w[tool-aarch64-apple-darwin tool-x86_64-apple-darwin], arch: "arm64")
    assert_equal "tool-aarch64-apple-darwin", chosen.name
  end

  def test_bare_binary_without_macos_marker_is_rejected
    assert_raises(Ghcask::NoAssetMatchError) { select(%w[tool-linux-amd64 tool-amd64], arch: "x86_64") }
  end

  def test_excludes_other_os_packages_missed_by_substrings
    selector = Ghcask::AssetSelector.new([], arch: "arm64")
    refute selector.macos_candidate?(asset("tool-win-arm64.zip")) # Windows ARM, not "win32/win64/windows"
    refute selector.macos_candidate?(asset("tool-freebsd-arm64.tar.gz"))
    refute selector.macos_candidate?(asset("tool-android-arm64.tar.gz"))
    assert selector.macos_candidate?(asset("tool-arm64-apple-darwin.tar.gz")) # "win" inside darwin survives
    assert selector.macos_candidate?(asset("Wine-arm64.dmg")) # macOS app whose name merely starts with "win"
  end

  def test_skips_other_os_asset_when_selecting
    chosen = select(%w[tool-arm64-apple-darwin.tar.gz tool-win-arm64.zip], arch: "arm64")
    assert_equal "tool-arm64-apple-darwin.tar.gz", chosen.name
  end

  def test_x86_64_underscore_marker_scores_as_local_arch
    # x86_64 normalizes to x86-64; the marker must normalize too, or this asset earns
    # no local-arch bonus and ties with the unmarked dmg (AmbiguousAssetError).
    chosen = select(%w[tool-x86_64.dmg tool.dmg], arch: "x86_64")
    assert_equal "tool-x86_64.dmg", chosen.name
  end

  def test_installer_preferred_over_bare_binary
    chosen = select(%w[App-arm64.dmg tool-arm64-darwin], arch: "arm64")
    assert_equal "App-arm64.dmg", chosen.name
  end
end

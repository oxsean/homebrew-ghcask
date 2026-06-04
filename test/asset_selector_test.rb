# frozen_string_literal: true

require "test_helper"

require "ghcask/asset_selector"
require "ghcask/github"

class AssetSelectorTest < Minitest::Test
  def asset(name)
    Ghcask::GitHub::Asset.new(name: name, url: "https://example.test/#{name}")
  end

  def select(names, arch: "arm64", pattern: nil)
    Ghcask::AssetSelector.new(names.map { |name| asset(name) }, arch: arch).select(pattern: pattern)
  end

  def test_arm64_prefers_exact_arch_dmg
    selected = select(["Example-x64.dmg", "Example-arm64.dmg", "Example-universal.zip"], arch: "arm64")

    assert_equal "Example-arm64.dmg", selected.name
  end

  def test_x86_64_prefers_intel_marker
    selected = select(["Example-arm64.dmg", "Example-intel.dmg"], arch: "x86_64")

    assert_equal "Example-intel.dmg", selected.name
  end

  def test_universal_is_compatible
    selected = select(["Example-universal.dmg", "Example-arm64.zip"], arch: "x86_64")

    assert_equal "Example-universal.dmg", selected.name
  end

  def test_asset_type_priority_prefers_dmg_over_zip
    selected = select(["Example-arm64.zip", "Example-arm64.dmg"], arch: "arm64")

    assert_equal "Example-arm64.dmg", selected.name
  end

  def test_single_plausible_asset_without_arch_marker_is_allowed
    selected = select(["Example.dmg"], arch: "arm64")

    assert_equal "Example.dmg", selected.name
  end

  def test_single_zip_without_platform_marker_is_allowed
    selected = select(["Example.zip"], arch: "arm64")

    assert_equal "Example.zip", selected.name
  end

  def test_single_tarball_without_platform_marker_is_allowed
    selected = select(["Example.tar.gz"], arch: "arm64")

    assert_equal "Example.tar.gz", selected.name
  end

  def test_zip_is_preferred_over_tarball
    selected = select(["Example-arm64.tgz", "Example-arm64.zip"], arch: "arm64")

    assert_equal "Example-arm64.zip", selected.name
  end

  def test_pkg_is_not_selected
    error = assert_raises(Ghcask::AssetSelector::NoMatchError) do
      select(["Example.pkg"], arch: "arm64")
    end

    assert_includes error.message, "No compatible"
  end

  def test_windows_zip_is_excluded
    selected = select(["Example-macOS-arm64.zip", "Example-windows-arm64.zip"], arch: "arm64")

    assert_equal "Example-macOS-arm64.zip", selected.name
  end

  def test_excludes_source_and_checksum_assets
    selected = select(["Example-arm64.dmg", "Example-source.zip", "Example_checksums.txt"], arch: "arm64")

    assert_equal "Example-arm64.dmg", selected.name
  end

  def test_pattern_override_selects_matching_asset
    selected = select(["Example-arm64.dmg", "Example-x64.dmg"], arch: "arm64", pattern: "*x64*")

    assert_equal "Example-x64.dmg", selected.name
  end

  def test_ambiguous_candidates_raise_clear_error
    error = assert_raises(Ghcask::AssetSelector::AmbiguousError) do
      select(["Example-arm64.dmg", "Other-arm64.dmg"], arch: "arm64")
    end

    assert_includes error.message, "Multiple plausible"
    assert_equal ["Example-arm64.dmg", "Other-arm64.dmg"], error.candidates.map(&:name)
  end

  def test_no_match_raises_clear_error
    error = assert_raises(Ghcask::AssetSelector::NoMatchError) do
      select(["Example_checksums.txt", "Source code.zip"], arch: "arm64")
    end

    assert_includes error.message, "No compatible"
  end
end

# frozen_string_literal: true

require "test_helper"

class PackageFormatTest < GhcaskTest::Case
  def test_type_maps_extension_to_artifact
    assert_equal :dmg, Ghcask::PackageFormat.type("App.dmg")
    assert_equal :pkg, Ghcask::PackageFormat.type("App.pkg")
    assert_equal :zip, Ghcask::PackageFormat.type("App.zip")
    assert_equal :tar, Ghcask::PackageFormat.type("App.tar.gz")
    assert_equal :tar, Ghcask::PackageFormat.type("App.tgz")
    assert_equal :tar, Ghcask::PackageFormat.type("App.tar.zst")
    assert_nil Ghcask::PackageFormat.type("App.exe")
    assert_nil Ghcask::PackageFormat.type("tool-darwin-arm64")
  end

  def test_extension_prefers_longest_match
    assert_equal ".tar.gz", Ghcask::PackageFormat.extension("App-1.2.tar.gz")
    assert_equal ".tgz", Ghcask::PackageFormat.extension("App.tgz")
  end

  def test_package_predicate
    assert Ghcask::PackageFormat.package?("App.dmg")
    refute Ghcask::PackageFormat.package?("App.exe")
  end
end

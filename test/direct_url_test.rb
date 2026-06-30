# frozen_string_literal: true

require "test_helper"

class DirectUrlTest < GhcaskTest::Case
  def test_accepts_supported_extensions
    %w[
      https://example.com/App.dmg
      https://example.com/App.zip
      https://example.com/App.tar.gz
      https://example.com/App.tgz
    ].each { |url| assert_equal url, Ghcask::DirectUrl.package_url(url) }
  end

  def test_accepts_pkg
    assert_equal "https://example.com/App.pkg", Ghcask::DirectUrl.package_url("https://example.com/App.pkg")
  end

  def test_rejects_unsupported_extension
    error = assert_raises(Ghcask::SourceError) { Ghcask::DirectUrl.package_url("https://example.com/App.exe") }
    assert_includes error.message, ".tar.zst" # error lists the currently supported formats
  end

  def test_rejects_non_http
    assert_raises(Ghcask::SourceError) { Ghcask::DirectUrl.package_url("ftp://example.com/App.dmg") }
    assert_raises(Ghcask::SourceError) { Ghcask::DirectUrl.package_url("not a url") }
  end

  def test_homepage_for_github
    assert_equal "https://github.com/o/r", Ghcask::DirectUrl.homepage("https://github.com/o/r/releases/download/v1/App.dmg")
  end

  def test_homepage_for_generic_host
    assert_equal "https://downloads.example.com", Ghcask::DirectUrl.homepage("https://downloads.example.com/path/App.dmg")
  end

  def test_asset_name
    assert_equal "App.dmg", Ghcask::DirectUrl.asset_name("https://example.com/path/App.dmg")
  end

  def test_version_from_filename
    assert_equal "1.2.3", Ghcask::DirectUrl.version_from_filename("App-1.2.3.dmg")
    assert_equal "1.2.3", Ghcask::DirectUrl.version_from_filename("App-v1.2.3-arm64.dmg")
    assert_equal "2.0.0-beta.1", Ghcask::DirectUrl.version_from_filename("App-2.0.0-beta.1.dmg")
    assert_nil Ghcask::DirectUrl.version_from_filename("App.dmg")
  end

  def test_github_host
    assert Ghcask::DirectUrl.github_host?("https://github.com/acme/app/releases/download/v1/App.dmg")
    assert Ghcask::DirectUrl.github_host?("https://raw.githubusercontent.com/acme/app/main/App.dmg")
    refute Ghcask::DirectUrl.github_host?("https://example.com/App.dmg")
    refute Ghcask::DirectUrl.github_host?("not a url")
  end

  def test_version_from_filename_handles_double_extensions
    # File.extname only strips `.gz`; the full package extension must be removed.
    assert_equal "1.2.3", Ghcask::DirectUrl.version_from_filename("App-1.2.3.tar.gz")
    assert_equal "1.2.3", Ghcask::DirectUrl.version_from_filename("App-1.2.3.tgz")
    assert_equal "2.0.0", Ghcask::DirectUrl.version_from_filename("Foo-2.0.0.pkg")
  end
end

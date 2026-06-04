# frozen_string_literal: true

require "test_helper"

require "ghcask/direct_url"

class DirectUrlTest < Minitest::Test
  def test_package_url_accepts_supported_http_package_urls
    assert_equal "https://example.test/Example.dmg", Ghcask::DirectUrl.package_url("https://example.test/Example.dmg")
    assert_equal "http://example.test/Example.zip", Ghcask::DirectUrl.package_url("http://example.test/Example.zip")
    assert_equal "https://example.test/Example.tar.gz", Ghcask::DirectUrl.package_url("https://example.test/Example.tar.gz")
    assert_equal "https://example.test/Example.tgz", Ghcask::DirectUrl.package_url("https://example.test/Example.tgz")
  end

  def test_package_url_rejects_invalid_or_unsupported_urls
    assert_raises(Ghcask::DirectUrl::Error) { Ghcask::DirectUrl.package_url("not a url") }
    assert_raises(Ghcask::DirectUrl::Error) { Ghcask::DirectUrl.package_url("ftp://example.test/Example.dmg") }
    assert_raises(Ghcask::DirectUrl::Error) { Ghcask::DirectUrl.package_url("https://example.test/Example.pkg") }
  end

  def test_homepage_for_github_release_url
    url = "https://github.com/owner/repo/releases/download/v1.2.3/Example.dmg"

    assert_equal "https://github.com/owner/repo", Ghcask::DirectUrl.homepage(url)
  end

  def test_homepage_for_non_github_url
    assert_equal "https://downloads.example.test", Ghcask::DirectUrl.homepage("https://downloads.example.test/apps/Example.dmg")
  end

  def test_asset_name
    assert_equal "Example.dmg", Ghcask::DirectUrl.asset_name("https://example.test/downloads/Example.dmg")
  end

  def test_version_from_filename
    assert_equal "2.4.0", Ghcask::DirectUrl.version_from_filename("Example-2.4.0-arm64.dmg")
    assert_equal "1.0.0-beta.1", Ghcask::DirectUrl.version_from_filename("Example_v1.0.0_beta.1.zip")
    assert_nil Ghcask::DirectUrl.version_from_filename("Example.dmg")
  end
end

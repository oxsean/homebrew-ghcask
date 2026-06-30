# frozen_string_literal: true

require "test_helper"

class CaskFileTest < GhcaskTest::Case
  def test_normalize_name
    assert_equal "my-app", Ghcask::CaskFile.normalize_name("My App.app")
    assert_equal "foo-bar", Ghcask::CaskFile.normalize_name("foo_bar")
    assert_equal "app", Ghcask::CaskFile.normalize_name("--App!!--")
    assert_equal "", Ghcask::CaskFile.normalize_name("")
  end

  def test_render_github_entry
    rendered = Ghcask::CaskFile.render(entry)
    assert_includes rendered, %(cask "app" do)
    assert_includes rendered, %(version "1.0.0")
    assert_includes rendered, %(sha256 "deadbeef")
    assert_includes rendered, %(url "https://example.com/app.dmg")
    assert_includes rendered, %(app "App.app")
    assert_includes rendered, %(homepage "https://github.com/acme/app")
    assert_includes rendered, "Generated from GitHub Releases"
  end

  def test_render_url_entry
    rendered = Ghcask::CaskFile.render(url_entry)
    assert_includes rendered, "Generated from a direct package URL"
    assert_includes rendered, %(homepage "https://example.com")
  end

  def test_render_uses_repo_description_when_present
    rendered = Ghcask::CaskFile.render(entry("desc" => "Fast grep"))
    assert_includes rendered, %(desc "Fast grep")
    refute_includes rendered, "Generated from GitHub Releases"
  end

  def test_render_pkg_entry_with_uninstall
    rendered = Ghcask::CaskFile.render(entry("asset_name" => "Foo.pkg", "app" => nil, "pkg_id" => "com.foo.bar"))
    assert_includes rendered, %(pkg "Foo.pkg")
    assert_includes rendered, %(uninstall pkgutil: "com.foo.bar")
    refute_match(/^\s+app /, rendered)
  end

  def test_render_pkg_entry_without_id_omits_uninstall
    rendered = Ghcask::CaskFile.render(entry("asset_name" => "Foo.pkg", "app" => nil, "pkg_id" => nil))
    assert_includes rendered, %(pkg "Foo.pkg")
    refute_includes rendered, "uninstall"
  end

  def test_render_app_includes_zap_keyed_on_bundle_id
    rendered = Ghcask::CaskFile.render(entry("bundle_id" => "com.acme.app"))
    assert_includes rendered, %(zap quit:  "com.acme.app")
    assert_includes rendered, %("~/Library/Caches/com.acme.app")
    assert_includes rendered, %("~/Library/Preferences/com.acme.app.plist")
    assert_includes rendered, %("~/Library/Saved Application State/com.acme.app.savedState")
  end

  def test_render_includes_auto_updates_when_self_updating
    assert_includes Ghcask::CaskFile.render(entry("auto_updates" => true)), "auto_updates true"
  end

  def test_render_omits_auto_updates_by_default
    refute_includes Ghcask::CaskFile.render(entry), "auto_updates"
  end

  def test_render_omits_zap_without_bundle_id
    refute_includes Ghcask::CaskFile.render(entry("bundle_id" => nil)), "zap"
  end

  def test_render_omits_zap_for_invalid_bundle_id
    refute_includes Ghcask::CaskFile.render(entry("bundle_id" => "notadomain")), "zap" # no dot
    refute_includes Ghcask::CaskFile.render(entry("bundle_id" => "....")), "zap" # empty segments
    refute_includes Ghcask::CaskFile.render(entry("bundle_id" => "com.acme app")), "zap" # whitespace
    refute_includes Ghcask::CaskFile.render(entry("bundle_id" => "com.a/../b")), "zap" # path chars
  end

  def test_render_omits_zap_for_pkg_and_binary
    pkg = entry("asset_name" => "Foo.pkg", "app" => nil, "bundle_id" => "com.acme.app")
    refute_includes Ghcask::CaskFile.render(pkg), "zap"
    bin = entry("app" => nil, "binary" => "rg", "bundle_id" => "com.acme.app")
    refute_includes Ghcask::CaskFile.render(bin), "zap"
  end

  def test_render_binary_omits_target_when_command_matches_filename
    rendered = Ghcask::CaskFile.render(entry("asset_name" => "rg-arm64.tar.gz", "app" => nil, "binary" => "ripgrep-1.0/rg", "command" => "rg"))
    assert_includes rendered, %(binary "ripgrep-1.0/rg")
    refute_match(/^\s+app /, rendered)
    refute_includes rendered, "target:"
  end

  def test_render_binary_targets_resolved_command
    rendered = Ghcask::CaskFile.render(entry("asset_name" => "mytool-darwin-arm64", "app" => nil, "binary" => "mytool-darwin-arm64", "command" => "mytool"))
    assert_includes rendered, %(binary "mytool-darwin-arm64", target: "mytool")
  end

  def test_render_binary_includes_manpage_and_completions
    rendered = Ghcask::CaskFile.render(entry(
      "asset_name" => "rg.tar.gz", "app" => nil, "binary" => "rg-1.0/rg", "command" => "rg",
      "extras" => { "manpage" => "rg-1.0/doc/rg.1", "bash" => "rg-1.0/complete/rg.bash",
                    "zsh" => "rg-1.0/complete/_rg", "fish" => "rg-1.0/complete/rg.fish" }
    ))
    assert_includes rendered, %(binary "rg-1.0/rg")
    assert_includes rendered, %(manpage "rg-1.0/doc/rg.1")
    assert_includes rendered, %(bash_completion "rg-1.0/complete/rg.bash")
    assert_includes rendered, %(zsh_completion "rg-1.0/complete/_rg")
    assert_includes rendered, %(fish_completion "rg-1.0/complete/rg.fish")
  end

  def test_render_binary_without_extras_has_no_completion_stanzas
    rendered = Ghcask::CaskFile.render(entry("asset_name" => "rg.tar.gz", "app" => nil, "binary" => "rg", "command" => "rg"))
    refute_includes rendered, "completion"
    refute_includes rendered, "manpage"
  end

  def test_quarantine_is_not_expressed_in_the_cask
    refute_includes Ghcask::CaskFile.render(entry("quarantine" => false)), "quarantine"
  end

  def test_quotes_dangerous_values
    rendered = Ghcask::CaskFile.render(entry("name" => %(weird"name)))
    assert_includes rendered, %(name "weird\\"name")
  end

  def test_write_yields_for_trust
    yielded = false
    path = File.join(@tmp, "x.rb")
    Ghcask::CaskFile.write(path, entry) { yielded = true }
    assert yielded
    assert File.exist?(path)
  end
end

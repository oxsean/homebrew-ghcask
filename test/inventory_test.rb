# frozen_string_literal: true

require "test_helper"
require "json"

class InventoryTest < GhcaskTest::Case
  def inventory(args, brew: nil, github: GhcaskTest::ExplodingGitHub.new)
    @brew = brew || GhcaskTest::FakeBrew.new
    Ghcask::Commands::Inventory.new(args, stdout: @out, stderr: @err, tap: tap, brew: @brew, github: github)
  end

  def cask_info(installed: "1.0.0", target: "/Applications/App.app")
    Ghcask::Homebrew::CaskInfo.new("installed" => installed, "artifacts" => [{ "target" => target }])
  end

  def test_list_shows_name_version_source
    seed(entry, url_entry)
    inventory([]).list
    assert_includes stdout, "app\t1.0.0\tacme/app"
    assert_includes stdout, "directapp\t1.0.0\tdirectapp"
  end

  def test_info_shows_quarantine_enabled
    seed(entry("quarantine" => true))
    inventory(%w[app], brew: GhcaskTest::FakeBrew.new(info: { "app" => cask_info })).info
    assert_includes stdout, "Quarantine: enabled"
    assert_includes stdout, "Installed: yes"
    assert_includes stdout, "Installed version: 1.0.0"
    assert_includes stdout, "Installed path: /Applications/App.app"
  end

  def test_info_shows_quarantine_disabled
    seed(entry("quarantine" => false))
    inventory(%w[app]).info
    assert_includes stdout, "Quarantine: disabled"
  end

  def test_info_reports_pinned
    seed(entry("requested_version" => "v1.0.0"))
    inventory(%w[app]).info
    assert_includes stdout, "Pinned: yes (v1.0.0)"
  end

  def test_info_url_cask_has_no_duplicate_asset_url
    seed(url_entry)
    inventory(%w[directapp]).info
    assert_includes stdout, "URL: https://example.com/Direct-1.2.0.dmg"
    refute_includes stdout, "Asset URL:"
  end

  def test_info_shows_binary_and_command
    seed(entry("asset_name" => "rg.tar.gz", "app" => nil, "binary" => "rg-1.0/rg", "command" => "rg"))
    inventory(%w[app]).info
    assert_includes stdout, "Binary: rg-1.0/rg"
    assert_includes stdout, "Command: rg"
    refute_includes stdout, "App:"
  end

  def test_info_shows_updated_timestamp
    seed(entry("updated_at" => "2024-01-01T00:00:00Z"))
    inventory(%w[app]).info
    assert_includes stdout, "Updated: 2024-01-01T00:00:00Z"
  end

  def test_info_resolves_by_repo
    seed(entry("repo" => "acme/app"))
    code = inventory(%w[acme/app]).info
    assert_equal 0, code
    assert_includes stdout, "Cask: app"
  end

  def test_info_unknown_target
    seed(entry)
    code = inventory(%w[nope]).info
    assert_equal 1, code
    assert_includes stderr, "managed cask not found: nope"
  end

  def test_search_lists_repositories_by_stars
    repos = [
      Ghcask::Repo.new(full_name: "cli/cli", stars: 38_000, description: "GitHub's official CLI"),
      Ghcask::Repo.new(full_name: "junegunn/fzf", stars: 60_000, description: nil)
    ]
    gh = GhcaskTest::FakeGitHub.new(nil, repos: repos)
    code = inventory(%w[github cli], github: gh).search
    assert_equal 0, code
    assert_includes stdout, "cli/cli  ★38000  GitHub's official CLI"
    assert_includes stdout, "junegunn/fzf  ★60000" # nil description renders cleanly
    assert_includes stdout, "Install one with: brew ghcask install"
  end

  def test_search_reports_no_results
    gh = GhcaskTest::FakeGitHub.new(nil, repos: [])
    inventory(%w[nonexistent-xyz], github: gh).search
    assert_includes stdout, "No repositories found"
  end

  def test_search_requires_query
    code = inventory([]).search
    assert_equal 1, code
    assert_includes stderr, "search query is required"
  end

  def test_info_help_prints_usage
    code = inventory(%w[--help]).info
    assert_equal 0, code
    assert_includes stdout, "Usage: brew ghcask info"
  end

  def test_info_rejects_extra_argument
    seed(entry)
    code = inventory(%w[app extra]).info
    assert_equal 1, code
    assert_includes stderr, "unknown argument: extra"
  end

  def test_list_rejects_extra_argument
    code = inventory(%w[bogus]).list
    assert_equal 1, code
    assert_includes stderr, "unknown argument: bogus"
  end

  def test_search_help_prints_usage
    code = inventory(%w[--help]).search
    assert_equal 0, code
    assert_includes stdout, "Usage: brew ghcask search"
  end

  def test_pin_sets_requested_version
    seed(entry("requested_version" => nil, "release_tag" => "v1.0.0"))
    inventory(%w[app]).pin
    assert_equal "v1.0.0", catalog["app"].requested_version
    assert_includes stdout, "Pinned app to v1.0.0."
  end

  def test_unpin_clears_requested_version
    seed(entry("requested_version" => "v1.0.0"))
    inventory(%w[app]).unpin
    assert_nil catalog["app"].requested_version
    assert_includes stdout, "Unpinned app."
  end

  def test_pin_rejected_for_url_cask
    seed(url_entry)
    code = inventory(%w[directapp]).pin
    assert_equal 1, code
    assert_includes stderr, "pin is only supported for GitHub casks"
  end

  def test_list_json_outputs_array
    seed(entry, url_entry)
    code = inventory(%w[--json]).list
    assert_equal 0, code
    data = JSON.parse(stdout)
    assert_equal 2, data.length
    app = data.find { |cask| cask["name"] == "app" }
    assert_equal "github", app["source_type"]
    assert_equal "acme/app", app["source"]
    refute app["pinned"]
    direct = data.find { |cask| cask["name"] == "directapp" }
    assert_equal "url", direct["source_type"]
    assert_equal "https://example.com/Direct-1.2.0.dmg", direct["source"]
  end

  def test_info_json_outputs_object
    seed(entry("requested_version" => "v1.0.0"))
    code = inventory(%w[app --json], brew: GhcaskTest::FakeBrew.new(info: { "app" => cask_info })).info
    assert_equal 0, code
    data = JSON.parse(stdout)
    assert_equal "app", data["cask"]
    assert_equal "ghcask/local/app", data["full_token"]
    assert data["pinned"]
    assert_equal "1.0.0", data["version"]
    assert data["installed"]
    assert_equal "1.0.0", data["installed_version"]
  end
end

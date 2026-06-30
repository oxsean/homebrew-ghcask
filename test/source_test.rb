# frozen_string_literal: true

require "test_helper"

class SourceTest < GhcaskTest::Case
  # FakeGitHub returns +desc+ from repo_description; if resolve reuses the stored desc
  # it never appears in the result, which is how these tests tell reuse from re-fetch.
  def gh(desc:)
    GhcaskTest::FakeGitHub.new(
      release(tag: "v2.0.0", assets: [["App-arm64.dmg", "https://x/App.dmg"]]),
      repo_description: desc
    )
  end

  def github_source(existing:, force: false)
    Ghcask::GithubSource.new(
      repo: "acme/app", release_policy: "latest-stable",
      existing: existing, arch_override: "arm64", force: force
    )
  end

  def test_resolve_reuses_stored_desc_without_force
    res = github_source(existing: entry("desc" => "Stored")).resolve(gh(desc: "Upstream"))
    assert_equal "Stored", res.repo_description
  end

  def test_resolve_refetches_desc_on_force
    res = github_source(existing: entry("desc" => "Stored"), force: true).resolve(gh(desc: "Upstream"))
    assert_equal "Upstream", res.repo_description
  end

  def test_resolve_skips_desc_fetch_when_not_requested
    # dry-run path: no stored desc and fetch suppressed → no GitHub round-trip, stays empty.
    res = github_source(existing: entry("desc" => nil)).resolve(gh(desc: "Upstream"), fetch_description: false)
    assert_nil res.repo_description
  end
end

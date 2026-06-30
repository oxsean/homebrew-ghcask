# frozen_string_literal: true

require "test_helper"

class RepoRefTest < GhcaskTest::Case
  def test_owner_repo
    parsed = Ghcask::RepoRef.parse("cli/cli")
    assert_equal "cli/cli", parsed.repo
    assert_nil parsed.version
  end

  def test_https_url
    assert_equal "cli/cli", Ghcask::RepoRef.parse("https://github.com/cli/cli").repo
  end

  def test_git_suffix_stripped
    assert_equal "cli/cli", Ghcask::RepoRef.parse("https://github.com/cli/cli.git").repo
  end

  def test_release_tag_url_yields_version
    parsed = Ghcask::RepoRef.parse("https://github.com/cli/cli/releases/tag/v2.0.0")
    assert_equal "cli/cli", parsed.repo
    assert_equal "v2.0.0", parsed.version
  end

  def test_rejects_blank
    assert_raises(Ghcask::SourceError) { Ghcask::RepoRef.parse("") }
  end

  def test_rejects_non_repo_shape
    assert_raises(Ghcask::SourceError) { Ghcask::RepoRef.parse("just-a-name") }
  end

  def test_rejects_non_github_host
    assert_raises(Ghcask::SourceError) { Ghcask::RepoRef.parse("https://gitlab.com/a/b") }
  end
end

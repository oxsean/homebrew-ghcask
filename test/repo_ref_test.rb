# frozen_string_literal: true

require "test_helper"

require "ghcask/repo_ref"

class RepoRefTest < Minitest::Test
  def test_owner_repo_passes_through
    assert_equal "owner/repo", Ghcask::RepoRef.normalize("owner/repo")
  end

  def test_https_github_url
    assert_equal "owner/repo", Ghcask::RepoRef.normalize("https://github.com/owner/repo")
  end

  def test_https_github_url_with_git_suffix
    assert_equal "owner/repo", Ghcask::RepoRef.normalize("https://github.com/owner/repo.git")
  end

  def test_https_github_url_with_extra_path
    assert_equal "owner/repo", Ghcask::RepoRef.normalize("https://github.com/owner/repo/releases/tag/v1.2.3")
  end

  def test_parse_extracts_release_tag_from_github_release_url
    parsed = Ghcask::RepoRef.parse("https://github.com/owner/repo/releases/tag/0.8.5")

    assert_equal "owner/repo", parsed.repo
    assert_equal "0.8.5", parsed.version
  end

  def test_rejects_non_github_url
    error = assert_raises(Ghcask::RepoRef::Error) do
      Ghcask::RepoRef.normalize("https://example.com/owner/repo")
    end

    assert_includes error.message, "only https://github.com"
  end

  def test_rejects_invalid_shape
    error = assert_raises(Ghcask::RepoRef::Error) do
      Ghcask::RepoRef.normalize("just-one-part")
    end

    assert_includes error.message, "owner/repo"
  end
end

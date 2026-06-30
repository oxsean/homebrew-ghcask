# frozen_string_literal: true

require "test_helper"

class GitHubTest < GhcaskTest::Case
  def rel(tag, prerelease: false, draft: false, at: "2024-01-01T00:00:00Z", assets: [])
    Ghcask::GitHub.normalize_release(
      "tagName" => tag, "name" => tag, "isDraft" => draft,
      "isPrerelease" => prerelease, "publishedAt" => at, "assets" => assets
    )
  end

  # --- ReleaseSelector -----------------------------------------------------

  def test_latest_stable_skips_prerelease
    releases = [rel("v2.0.0", prerelease: true, at: "2024-03-01T00:00:00Z"), rel("v1.0.0", at: "2024-01-01T00:00:00Z")]
    chosen = Ghcask::GitHub::ReleaseSelector.new(releases).select(policy: "latest-stable")
    assert_equal "v1.0.0", chosen.tag_name
  end

  def test_latest_prerelease_takes_newest
    releases = [rel("v1.0.0", at: "2024-01-01T00:00:00Z"), rel("v2.0.0", prerelease: true, at: "2024-03-01T00:00:00Z")]
    assert_equal "v2.0.0", Ghcask::GitHub::ReleaseSelector.new(releases).select(policy: "latest-prerelease").tag_name
  end

  def test_specific_version_matches_with_or_without_v
    releases = [rel("v1.2.3"), rel("v2.0.0")]
    assert_equal "v1.2.3", Ghcask::GitHub::ReleaseSelector.new(releases).select(policy: "latest-stable", requested_version: "1.2.3").tag_name
  end

  def test_drafts_are_ignored
    releases = [rel("v3.0.0", draft: true, at: "2024-09-01T00:00:00Z"), rel("v1.0.0")]
    assert_equal "v1.0.0", Ghcask::GitHub::ReleaseSelector.new(releases).select(policy: "latest-stable").tag_name
  end

  def test_no_stable_release_error
    releases = [rel("v2.0.0", prerelease: true)]
    assert_raises(Ghcask::NoStableReleaseError) { Ghcask::GitHub::ReleaseSelector.new(releases).select(policy: "latest-stable") }
  end

  def test_gh_latest_stable_falls_back_when_latest_release_has_no_assets
    runner = GhcaskTest::FakeRunner.new
    runner.on("gh", "auth", "token", stdout: "tok\n")
    runner.on("gh", "release", "view", stdout: JSON.generate("tagName" => "v2.0.0", "assets" => [])) # latest, no assets
    runner.on("gh", "release", "view", "v1.0.0", stdout: JSON.generate("tagName" => "v1.0.0", "assets" => [{ "name" => "App-arm64.dmg", "url" => "https://x/a.dmg" }]))
    runner.on("gh", "release", "list", stdout: JSON.generate([
      { "tagName" => "v2.0.0", "isDraft" => false, "isPrerelease" => false, "publishedAt" => "2024-02-01T00:00:00Z" },
      { "tagName" => "v1.0.0", "isDraft" => false, "isPrerelease" => false, "publishedAt" => "2024-01-01T00:00:00Z" }
    ]))

    release = Ghcask::GitHub::Client.new(runner: runner, env: {}).select_release("a/b", policy: "latest-stable")
    assert_equal "v1.0.0", release.tag_name # walked past the asset-less latest
    refute_empty release.assets
  end

  def test_gh_search_repos_returns_starred_repos
    runner = GhcaskTest::FakeRunner.new
    runner.on("gh", "auth", "token", stdout: "tok\n")
    runner.on("gh", "search", "repos", stdout: JSON.generate([{ "fullName" => "cli/cli", "stargazersCount" => 38_000, "description" => "GitHub CLI" }]))
    repos = Ghcask::GitHub::Client.new(runner: runner, env: {}).search_repos("github cli")
    assert_equal "cli/cli", repos.first.full_name
    assert_equal 38_000, repos.first.stars
    assert_equal "GitHub CLI", repos.first.description
  end

  def test_curl_search_repos_returns_starred_repos
    runner = GhcaskTest::FakeRunner.new
    runner.executable("gh", present: false)
    body = JSON.generate("items" => [{ "full_name" => "cli/cli", "stargazers_count" => 38_000, "description" => "GitHub CLI" }])
    runner.on("curl", stdout: "HTTP/2 200\r\n\r\n#{body}")
    repos = Ghcask::GitHub::Client.new(runner: runner, env: {}).search_repos("github cli")
    assert_equal "cli/cli", repos.first.full_name
    assert_equal 38_000, repos.first.stars
  end

  def test_requested_version_not_found
    assert_raises(Ghcask::RequestedVersionNotFoundError) do
      Ghcask::GitHub::ReleaseSelector.new([rel("v1.0.0")]).select(policy: "latest-stable", requested_version: "9.9.9")
    end
  end

  # --- normalization accepts both spellings --------------------------------

  def test_normalize_release_snake_case
    release = Ghcask::GitHub.normalize_release(
      "tag_name" => "v1", "draft" => false, "prerelease" => true,
      "published_at" => "2024-01-01T00:00:00Z",
      "assets" => [{ "name" => "A.dmg", "browser_download_url" => "https://x/A.dmg" }]
    )
    assert_equal "v1", release.tag_name
    assert release.prerelease
    assert_equal "https://x/A.dmg", release.assets.first.url
  end

  def test_normalize_asset_camel_case
    asset = Ghcask::GitHub.normalize_asset("name" => "A.dmg", "url" => "https://api/A", "apiUrl" => "https://api/A")
    assert_equal "https://api/A", asset.api_url
  end

  def test_malformed_json_raises
    assert_raises(Ghcask::MalformedResponseError) { Ghcask::GitHub.parse_json("{nope") }
  end

  def test_parse_time_handles_non_string_and_blank
    assert_nil Ghcask::GitHub.parse_time(nil)
    assert_nil Ghcask::GitHub.parse_time(1_234_567_890) # numeric timestamp must not crash
    assert_nil Ghcask::GitHub.parse_time("")
  end

  # --- error mapping -------------------------------------------------------

  def test_error_mapper_status_codes
    mapper = Ghcask::GitHub::ErrorMapper
    assert_nil mapper.from_status!(200, "", {})
    assert_raises(Ghcask::UnauthorizedError) { mapper.from_status!(401, "", {}) }
    assert_raises(Ghcask::NotFoundError) { mapper.from_status!(404, "", {}, repo: "a/b") }
    assert_raises(Ghcask::NetworkError) { mapper.from_status!(500, "oops", {}) }
    assert_raises(Ghcask::NetworkError) { mapper.from_status!(0, "", {}) }
  end

  def test_error_mapper_rate_limit_includes_reset
    error = assert_raises(Ghcask::RateLimitError) do
      Ghcask::GitHub::ErrorMapper.from_status!(403, "", { "x-ratelimit-reset" => "1700000000" })
    end
    refute_nil error.reset_at
    assert_includes error.message, "Try again after"
  end

  def test_error_mapper_from_text
    mapper = Ghcask::GitHub::ErrorMapper
    assert_raises(Ghcask::UnauthorizedError) { mapper.from_text!("Bad credentials") }
    assert_raises(Ghcask::NotFoundError) { mapper.from_text!("Not Found", repo: "a/b") }
    assert_raises(Ghcask::NetworkError) { mapper.from_text!("Could not connect to host") }
    assert_raises(Ghcask::RateLimitError) { mapper.from_text!("API rate limit exceeded") }
    assert_raises(Ghcask::GitHubError) { mapper.from_text!("some other failure") }
  end

  # --- Client backend selection --------------------------------------------

  def test_client_uses_curl_when_gh_absent
    runner = GhcaskTest::FakeRunner.new
    runner.executable("gh", present: false)
    body = JSON.generate("tag_name" => "v1.0.0", "assets" => [{ "name" => "A-arm64.dmg", "browser_download_url" => "https://x/A.dmg" }])
    runner.on("curl", stdout: "HTTP/2 200\r\ncontent-type: application/json\r\n\r\n#{body}")

    client = Ghcask::GitHub::Client.new(runner: runner, env: {})
    release = client.select_release("acme/app", policy: "latest-stable")
    assert_equal "v1.0.0", release.tag_name
    assert(runner.commands.any? { |c| c.first == "curl" })
  end

  # --- authenticated asset download ---------------------------------------

  def test_normalize_asset_captures_api_url_from_rest
    asset = Ghcask::GitHub.normalize_asset(
      "name" => "A.dmg",
      "url" => "https://api.github.com/repos/o/r/releases/assets/1",
      "browser_download_url" => "https://github.com/o/r/releases/download/v1/A.dmg"
    )
    assert_equal "https://github.com/o/r/releases/download/v1/A.dmg", asset.url
    assert_equal "https://api.github.com/repos/o/r/releases/assets/1", asset.api_url
  end

  def test_normalize_asset_captures_api_url_from_gh
    asset = Ghcask::GitHub.normalize_asset(
      "name" => "A.dmg",
      "url" => "https://github.com/o/r/releases/download/v1/A.dmg",
      "apiUrl" => "https://api.github.com/repos/o/r/releases/assets/1"
    )
    assert_equal "https://api.github.com/repos/o/r/releases/assets/1", asset.api_url
  end

  def test_curl_download_uses_api_endpoint_and_auth_header_with_token
    backend = Ghcask::GitHub::CurlBackend.new(GhcaskTest::FakeRunner.new, { "GH_TOKEN" => "secret" }, "github.com")
    asset = Ghcask::Asset.new(name: "A.dmg", url: "https://github.com/o/r/releases/download/v1/A.dmg", api_url: "https://api.github.com/repos/o/r/releases/assets/1")
    url, headers = backend.download_target(asset)
    assert_equal "https://api.github.com/repos/o/r/releases/assets/1", url
    assert_includes headers, "Accept: application/octet-stream"
    assert_includes headers, "Authorization: Bearer secret"
  end

  def test_curl_download_falls_back_to_browser_url_without_token
    backend = Ghcask::GitHub::CurlBackend.new(GhcaskTest::FakeRunner.new, {}, "github.com")
    asset = Ghcask::Asset.new(name: "A.dmg", url: "https://github.com/o/r/releases/download/v1/A.dmg", api_url: "https://api.github.com/x")
    url, headers = backend.download_target(asset)
    assert_equal "https://github.com/o/r/releases/download/v1/A.dmg", url
    assert_empty headers
  end

  def test_auth_token_prefers_env
    client = Ghcask::GitHub::Client.new(runner: GhcaskTest::FakeRunner.new, env: { "GH_TOKEN" => "envtok" })
    assert_equal "envtok", client.auth_token
  end

  def test_auth_token_falls_back_to_gh
    runner = GhcaskTest::FakeRunner.new
    runner.on("gh", "auth", "token", stdout: "ghtok\n")
    assert_equal "ghtok", Ghcask::GitHub::Client.new(runner: runner, env: {}).auth_token
  end

  def test_auth_token_nil_when_unavailable
    runner = GhcaskTest::FakeRunner.new
    runner.executable("gh", present: false)
    assert_nil Ghcask::GitHub::Client.new(runner: runner, env: {}).auth_token
  end

  def test_download_honors_homebrew_github_api_token
    backend = Ghcask::GitHub::CurlBackend.new(GhcaskTest::FakeRunner.new, { "HOMEBREW_GITHUB_API_TOKEN" => "brewtok" }, "github.com")
    asset = Ghcask::Asset.new(name: "A.dmg", url: "https://x/A.dmg", api_url: "https://api/x")
    _url, headers = backend.download_target(asset)
    assert_includes headers, "Authorization: Bearer brewtok"
  end

  def test_metadata_request_honors_homebrew_github_api_token
    runner = GhcaskTest::FakeRunner.new
    runner.executable("gh", present: false)
    body = JSON.generate("tag_name" => "v1", "assets" => [{ "name" => "A-arm64.dmg", "browser_download_url" => "https://x/A.dmg" }])
    runner.on("curl", stdout: "HTTP/2 200\r\n\r\n#{body}")

    Ghcask::GitHub::Client.new(runner: runner, env: { "HOMEBREW_GITHUB_API_TOKEN" => "brewtok" }).select_release("acme/app", policy: "latest-stable")
    curl = runner.commands.find { |c| c.first == "curl" }
    assert_includes curl, "Authorization: Bearer brewtok"
  end

  def test_gh_download_command_targets_the_tag_and_asset
    backend = Ghcask::GitHub::GhBackend.new(GhcaskTest::FakeRunner.new, include_list: false)
    asset = Ghcask::Asset.new(name: "A.dmg", url: "x")
    command = backend.gh_download_command("o/r", "v1.2.3", asset, "/tmp/dl")
    assert_equal %w[gh release download v1.2.3 -R o/r --pattern A.dmg --dir /tmp/dl --clobber], command
  end

  def test_gh_token_is_probed_at_most_once_per_client
    runner = GhcaskTest::FakeRunner.new
    runner.on("gh", "auth", "token", stdout: "tok\n")
    runner.on("gh", "release", "view", stdout: JSON.generate("tagName" => "v1.0.0", "assets" => [{ "name" => "A-arm64.dmg", "url" => "https://x/A.dmg" }]))
    runner.on("gh", "repo", "view", stdout: JSON.generate("description" => "desc"))

    client = Ghcask::GitHub::Client.new(runner: runner, env: {})
    client.select_release("a/b", policy: "latest-stable")
    client.repo_description("a/b") # second backend_for must NOT re-probe the token

    probes = runner.commands.count { |c| c[0, 3] == %w[gh auth token] }
    assert_equal 1, probes
  end

  def test_client_uses_gh_when_authenticated
    runner = GhcaskTest::FakeRunner.new
    runner.on("gh", "auth", "token", stdout: "tok\n")
    view = JSON.generate("tagName" => "v2.0.0", "assets" => [{ "name" => "A-arm64.dmg", "url" => "https://x/A.dmg" }])
    runner.on("gh", "release", "view", stdout: view)

    client = Ghcask::GitHub::Client.new(runner: runner, env: {})
    release = client.select_release("acme/app", policy: "latest-stable")
    assert_equal "v2.0.0", release.tag_name
  end
end

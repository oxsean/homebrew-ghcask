# frozen_string_literal: true

require "test_helper"

require "ghcask/github"

class GithubTest < Minitest::Test
  FakeStatus = Struct.new(:ok) do
    def success?
      ok
    end
  end

  FakeResult = Struct.new(:stdout, :stderr, :ok, keyword_init: true) do
    def success?
      ok
    end
  end

  class FakeRunner
    attr_reader :commands

    def initialize(executables: {}, responses: {})
      @executables = executables
      @responses = responses
      @commands = []
    end

    def executable?(name)
      !!@executables[name]
    end

    def capture(command)
      @commands << command
      key = command.join(" ")
      @responses.fetch(key) do
        FakeResult.new(stdout: "", stderr: "missing fake response: #{key}", ok: false)
      end
    end
  end

  def result(stdout, stderr: "", ok: true)
    FakeResult.new(stdout: stdout, stderr: stderr, ok: ok)
  end

  def release_json(tag:, prerelease: false, published_at: "2026-01-01T00:00:00Z")
    {
      "tagName" => tag,
      "name" => tag,
      "isDraft" => false,
      "isPrerelease" => prerelease,
      "publishedAt" => published_at,
      "assets" => [
        {
          "name" => "Example.dmg",
          "url" => "https://github.com/owner/repo/releases/download/#{tag}/Example.dmg",
          "size" => 123,
          "contentType" => "application/octet-stream"
        }
      ]
    }
  end

  def auth_json(state: "success")
    JSON.dump(
      "hosts" => {
        "github.com" => [
          {
            "active" => true,
            "state" => state
          }
        ]
      }
    )
  end

  def test_authenticated_gh_is_preferred
    runner = FakeRunner.new(
      executables: { "gh" => true },
      responses: {
        "gh auth status --active --hostname github.com --json hosts" => result(auth_json),
        "gh release view -R owner/repo --json tagName,name,isDraft,isPrerelease,publishedAt,assets" => result(JSON.dump(release_json(tag: "v1.2.3")))
      }
    )

    client = Ghcask::GitHub::Client.new(runner: runner)
    releases = client.releases("owner/repo")

    assert_equal "v1.2.3", releases.first.tag_name
    assert_includes runner.commands.first, "auth"
    assert_includes runner.commands.last, "view"
  end

  def test_authenticated_gh_select_release_lists_then_views_only_selected_tag
    summary = release_json(tag: "v2.0.0-beta", prerelease: true, published_at: "2026-02-01T00:00:00Z")
    summary.delete("assets")
    older = release_json(tag: "v1.0.0", published_at: "2026-01-01T00:00:00Z")
    older.delete("assets")
    runner = FakeRunner.new(
      executables: { "gh" => true },
      responses: {
        "gh auth status --active --hostname github.com --json hosts" => result(auth_json),
        "gh release list -R owner/repo --limit 100 --json tagName,name,isDraft,isPrerelease,publishedAt" => result(JSON.dump([summary, older])),
        "gh release view v2.0.0-beta -R owner/repo --json tagName,name,isDraft,isPrerelease,publishedAt,assets" => result(JSON.dump(release_json(tag: "v2.0.0-beta", prerelease: true)))
      }
    )

    client = Ghcask::GitHub::Client.new(runner: runner)
    release = client.select_release("owner/repo", policy: "latest-prerelease")

    assert_equal "v2.0.0-beta", release.tag_name
    assert_equal "gh release list -R owner/repo --limit 100 --json tagName,name,isDraft,isPrerelease,publishedAt", runner.commands[1].join(" ")
    assert_equal "gh release view v2.0.0-beta -R owner/repo --json tagName,name,isDraft,isPrerelease,publishedAt,assets", runner.commands[2].join(" ")
    assert_equal 3, runner.commands.length
  end

  def test_unauthenticated_gh_falls_back_to_curl
    raw = "HTTP/2 200\nx-ratelimit-remaining: 50\n\n#{JSON.dump(release_json(tag: "v1.0.0"))}"
    runner = FakeRunner.new(
      executables: { "gh" => true },
      responses: {
        "gh auth status --active --hostname github.com --json hosts" => result(auth_json(state: "failure")),
        "curl --fail-with-body --location --silent --show-error --connect-timeout 10 --max-time 30 --dump-header - --header Accept: application/vnd.github+json --header X-GitHub-Api-Version: 2022-11-28 https://api.github.com/repos/owner/repo/releases/latest" => result(raw)
      }
    )

    client = Ghcask::GitHub::Client.new(runner: runner, env: {})
    releases = client.releases("owner/repo")

    assert_equal "v1.0.0", releases.first.tag_name
    assert_equal "curl", runner.commands.last.first
  end

  def test_curl_uses_token_environment
    raw = "HTTP/2 200\n\n#{JSON.dump(release_json(tag: "v1.0.0"))}"
    runner = FakeRunner.new(
      executables: {},
      responses: {
        "curl --fail-with-body --location --silent --show-error --connect-timeout 10 --max-time 30 --dump-header - --header Authorization: Bearer abc --header Accept: application/vnd.github+json --header X-GitHub-Api-Version: 2022-11-28 https://api.github.com/repos/owner/repo/releases/latest" => result(raw)
      }
    )

    Ghcask::GitHub::Client.new(runner: runner, env: { "GH_TOKEN" => "abc" }).releases("owner/repo")

    assert_includes runner.commands.last, "Authorization: Bearer abc"
  end

  def test_latest_stable_skips_prereleases
    releases = [
      Ghcask::GitHub::Release.new(tag_name: "v2.0.0-beta", draft: false, prerelease: true, published_at: Time.parse("2026-02-01")),
      Ghcask::GitHub::Release.new(tag_name: "v1.0.0", draft: false, prerelease: false, published_at: Time.parse("2026-01-01"))
    ]

    selected = Ghcask::GitHub::ReleaseSelector.new(releases).select(policy: "latest-stable")

    assert_equal "v1.0.0", selected.tag_name
  end

  def test_prerelease_policy_selects_newest_release
    releases = [
      Ghcask::GitHub::Release.new(tag_name: "v2.0.0-beta", draft: false, prerelease: true, published_at: Time.parse("2026-02-01")),
      Ghcask::GitHub::Release.new(tag_name: "v1.0.0", draft: false, prerelease: false, published_at: Time.parse("2026-01-01"))
    ]

    selected = Ghcask::GitHub::ReleaseSelector.new(releases).select(policy: "latest-prerelease")

    assert_equal "v2.0.0-beta", selected.tag_name
  end

  def test_specific_version_matches_exact_tag
    releases = [
      Ghcask::GitHub::Release.new(tag_name: "v1.2.3", draft: false, prerelease: false, published_at: Time.parse("2026-01-01"))
    ]

    selected = Ghcask::GitHub::ReleaseSelector.new(releases).select(policy: "latest-stable", requested_version: "v1.2.3")

    assert_equal "v1.2.3", selected.tag_name
  end

  def test_specific_version_matches_normalized_version
    releases = [
      Ghcask::GitHub::Release.new(tag_name: "v1.2.3", draft: false, prerelease: false, published_at: Time.parse("2026-01-01"))
    ]

    selected = Ghcask::GitHub::ReleaseSelector.new(releases).select(policy: "latest-stable", requested_version: "1.2.3")

    assert_equal "v1.2.3", selected.tag_name
  end

  def test_missing_specific_version_raises_clear_error
    releases = [
      Ghcask::GitHub::Release.new(tag_name: "v1.2.3", draft: false, prerelease: false, published_at: Time.parse("2026-01-01"))
    ]

    error = assert_raises(Ghcask::GitHub::RequestedVersionNotFoundError) do
      Ghcask::GitHub::ReleaseSelector.new(releases).select(policy: "latest-stable", requested_version: "9.9.9")
    end
    assert_includes error.message, "Requested version 9.9.9"
  end

  def test_error_mapping_for_unauthorized
    assert_raises(Ghcask::GitHub::UnauthorizedError) do
      Ghcask::GitHub::ErrorMapper.from_status!(401, "")
    end
  end

  def test_error_mapping_for_not_found_includes_repository_hint
    error = assert_raises(Ghcask::GitHub::NotFoundError) do
      Ghcask::GitHub::ErrorMapper.from_status!(404, "", {}, repo: "owner/missing")
    end

    assert_includes error.message, "owner/missing"
    assert_includes error.message, "Check the repository name"
    assert_includes error.message, "private"
    assert_includes error.message, "GH_TOKEN/GITHUB_TOKEN"
  end

  def test_gh_not_found_includes_repository_hint
    runner = FakeRunner.new(
      executables: { "gh" => true },
      responses: {
        "gh auth status --active --hostname github.com --json hosts" => result(auth_json),
        "gh release view -R owner/missing --json tagName,name,isDraft,isPrerelease,publishedAt,assets" => result("", stderr: "repository not found", ok: false)
      }
    )

    error = assert_raises(Ghcask::GitHub::NotFoundError) do
      Ghcask::GitHub::Client.new(runner: runner).releases("owner/missing")
    end

    assert_includes error.message, "owner/missing"
    assert_includes error.message, "Check the repository name"
  end

  def test_error_mapping_for_rate_limit_reset
    error = assert_raises(Ghcask::GitHub::RateLimitError) do
      Ghcask::GitHub::ErrorMapper.from_status!(403, "", { "x-ratelimit-reset" => "1893456000" })
    end

    refute_nil error.reset_at
    assert_includes error.message, "Try again after"
  end

  def test_error_mapping_for_network_without_http_response
    error = assert_raises(Ghcask::GitHub::NetworkError) do
      Ghcask::GitHub::ErrorMapper.from_status!(0, "")
    end

    assert_includes error.message, "before an HTTP response"
  end

  def test_malformed_json_raises_clear_error
    assert_raises(Ghcask::GitHub::MalformedResponseError) do
      Ghcask::GitHub.parse_json("{ nope")
    end
  end
end

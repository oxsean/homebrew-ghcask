# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "uri"

require "ghcask/command_runner"
require "ghcask/errors"
require "ghcask/release"

module Ghcask
  # GitHub Release lookup over two backends: `GhBackend` (gh installed + authed) else
  # `CurlBackend` (anonymous or `GH_TOKEN`/`GITHUB_TOKEN`). Both normalize via
  # `normalize_release`/`normalize_asset`, which accept gh camelCase AND REST snake_case.
  module GitHub
    class Client
      def initialize(runner: CommandRunner.new, env: ENV, host: "github.com")
        @runner = runner
        @env = env
        @host = host
      end

      def select_release(repo, policy:, requested_version: nil)
        include_prerelease = policy == "latest-prerelease" || !requested_version.to_s.empty?
        backend = backend_for(include_prerelease: include_prerelease)
        backend.select_release(repo, policy: policy, requested_version: requested_version)
      end

      def download(repo:, tag:, asset:, destination_dir:, stdout: nil)
        backend_for(include_prerelease: false).download(
          repo: repo, tag: tag, asset: asset, destination_dir: destination_dir, stdout: stdout
        )
      end

      def repo_description(repo)
        backend_for(include_prerelease: false).repo_description(repo)
      end

      def search_repos(query, limit: 20)
        backend_for(include_prerelease: false).search_repos(query, limit: limit)
      end

      def backend_for(include_prerelease:)
        if gh_usable?
          GhBackend.new(@runner, include_list: include_prerelease)
        else
          CurlBackend.new(@runner, @env, @host)
        end
      end

      def auth_token
        env = GitHub.env_token(@env)
        return env if env
        return nil unless @runner.executable?("gh")

        result = @runner.capture(["gh", "auth", "token"])
        result.success? && !result.stdout.strip.empty? ? result.stdout.strip : nil
      end

      private

      def gh_usable?
        return @gh_usable unless @gh_usable.nil?

        @gh_usable = @runner.executable?("gh") && !auth_token.nil?
      end
    end

    # Picks the release matching a policy/requested_version from an in-memory list.
    class ReleaseSelector
      def initialize(releases)
        @releases = releases.reject(&:draft)
      end

      def select(policy:, requested_version: nil)
        return specific(requested_version) unless requested_version.to_s.empty?

        case policy
        when "latest-stable" then latest_stable
        when "latest-prerelease" then latest_any
        else
          raise GitHubError, "unknown release policy: #{policy}"
        end
      end

      def ordered
        @releases.sort_by { |release| release.published_at || Time.at(0) }.reverse
      end

      private

      def latest_stable
        release = ordered.reject(&:prerelease).first
        raise NoStableReleaseError, "No stable GitHub Release was found." unless release

        release
      end

      def latest_any
        release = ordered.first
        raise NoReleasesError, "No GitHub Releases were found." unless release

        release
      end

      def specific(requested_version)
        normalized = Ghcask.strip_v(requested_version)
        release = ordered.find do |candidate|
          candidate.tag_name == requested_version || Ghcask.strip_v(candidate.tag_name) == normalized
        end
        raise RequestedVersionNotFoundError, "Requested version #{requested_version} was not found in GitHub Releases." unless release

        release
      end
    end

    # Shared "prefer the newest release that actually has assets" walk used by both
    # backends once they have a list of release summaries.
    module Newest
      module_function

      def with_assets(summaries, policy:, fetch_full:)
        candidates = summaries.reject(&:draft)
        candidates = candidates.reject(&:prerelease) if policy == "latest-stable"
        candidates = candidates.sort_by { |release| release.published_at || Time.at(0) }.reverse

        candidates.each do |summary|
          full = fetch_full.call(summary)
          return full unless full.assets.empty?
        end

        ReleaseSelector.new(summaries).select(policy: policy)
      end
    end

    class GhBackend
      VIEW_FIELDS = "tagName,name,isDraft,isPrerelease,publishedAt,assets"
      LIST_FIELDS = "tagName,name,isDraft,isPrerelease,publishedAt"

      def initialize(runner, include_list:)
        @runner = runner
        @include_list = include_list
      end

      def select_release(repo, policy:, requested_version: nil)
        unless requested_version.to_s.empty? && !@include_list
          summaries = list_summaries(repo)
          return view_release(repo, ReleaseSelector.new(summaries).select(policy: policy, requested_version: requested_version).tag_name) unless requested_version.to_s.empty?

          return Newest.with_assets(summaries, policy: policy, fetch_full: ->(s) { view_release(repo, s.tag_name) })
        end

        release = view_release(repo, nil)
        return release unless release.assets.empty?

        Newest.with_assets(list_summaries(repo), policy: policy, fetch_full: ->(s) { view_release(repo, s.tag_name) })
      end

      def download(repo:, tag:, asset:, destination_dir:, stdout: nil)
        FileUtils.mkdir_p(destination_dir)
        stdout&.puts "==> Downloading #{asset.name} via gh (#{repo} #{tag})"
        target = File.join(destination_dir, File.basename(asset.name.to_s))
        return target if system(*gh_download_command(repo, tag, asset, destination_dir)) && File.exist?(target)

        raise DownloadError,
              "Failed to download #{asset.name} from #{repo} (#{tag}) with gh. " \
              "Check `gh auth status` and your access to the repository."
      end

      def gh_download_command(repo, tag, asset, dir)
        ["gh", "release", "download", tag, "-R", repo, "--pattern", asset.name.to_s, "--dir", dir, "--clobber"]
      end

      def repo_description(repo)
        result = @runner.capture(["gh", "repo", "view", repo, "--json", "description"])
        return nil unless result.success?

        GitHub.parse_json(result.stdout)["description"]
      rescue StandardError
        nil
      end

      def search_repos(query, limit:)
        result = @runner.capture(["gh", "search", "repos", query, "--sort", "stars", "--order", "desc", "--limit", limit.to_s, "--json", "fullName,stargazersCount,description"])
        map_error!(result, repo: nil)
        GitHub.parse_json(result.stdout).map do |item|
          Repo.new(full_name: item["fullName"], stars: item["stargazersCount"].to_i, description: item["description"])
        end
      end

      private

      def list_summaries(repo)
        result = @runner.capture(["gh", "release", "list", "-R", repo, "--limit", "100", "--json", LIST_FIELDS])
        map_error!(result, repo: repo)
        GitHub.normalize_release_array(GitHub.parse_json(result.stdout))
      end

      def view_release(repo, tag)
        command = %w[gh release view]
        command << tag if tag
        command += ["-R", repo, "--json", VIEW_FIELDS]
        result = @runner.capture(command)
        map_error!(result, repo: repo)
        GitHub.normalize_release(GitHub.parse_json(result.stdout))
      end

      def map_error!(result, repo:)
        return if result.success?

        ErrorMapper.from_text!(result.stderr.empty? ? result.stdout : result.stderr, repo: repo)
      end
    end

    class CurlBackend
      API_ROOT = "https://api.github.com"

      def initialize(runner, env, host)
        @runner = runner
        @env = env
        @host = host
      end

      def select_release(repo, policy:, requested_version: nil)
        prerelease = prerelease_needed?(policy, requested_version)
        releases = fetch(repo, include_prerelease: prerelease)
        return ReleaseSelector.new(releases).select(policy: policy, requested_version: requested_version) unless requested_version.to_s.empty?

        releases = fetch(repo, include_prerelease: true) if !prerelease && releases.length == 1 && releases.first.assets.empty?

        return ReleaseSelector.new(releases).select(policy: policy) if releases.length == 1

        Newest.with_assets(releases, policy: policy, fetch_full: ->(summary) { summary })
      end

      def download(repo:, tag:, asset:, destination_dir:, stdout: nil)
        FileUtils.mkdir_p(destination_dir)
        target = File.join(destination_dir, File.basename(asset.name.to_s))
        url, headers = download_target(asset)
        stdout&.puts "==> Downloading #{url}"
        return target if system(*curl_download_command(url, headers, target)) && File.exist?(target)

        FileUtils.rm_f(target)
        raise DownloadError,
              "Failed to download #{asset.name}. For a private repository, " \
              "run `gh auth login` or set GH_TOKEN/GITHUB_TOKEN with access."
      end

      def download_target(asset)
        token = token_value
        if token && asset.api_url
          [asset.api_url, ["Accept: application/octet-stream", "Authorization: Bearer #{token}"]]
        else
          [asset.url, []]
        end
      end

      def repo_description(repo)
        result = @runner.capture(curl_command("#{API_ROOT}/repos/#{repo}"))
        return nil unless result.success?

        response = CurlResponse.parse(result.stdout)
        return nil unless response.status == 200

        GitHub.parse_json(response.body)["description"]
      rescue StandardError
        nil
      end

      def search_repos(query, limit:)
        url = "#{API_ROOT}/search/repositories?q=#{URI.encode_www_form_component(query)}&sort=stars&order=desc&per_page=#{limit}"
        result = @runner.capture(curl_command(url))
        response = CurlResponse.parse(result.stdout)
        ErrorMapper.from_status!(response.status, response.body, response.headers)
        GitHub.parse_json(response.body).fetch("items", []).map do |item|
          Repo.new(full_name: item["full_name"], stars: item["stargazers_count"].to_i, description: item["description"])
        end
      end

      def curl_download_command(url, headers, target)
        command = [
          "curl", "--fail-with-body", "--location", "--show-error", "--progress-bar",
          "--connect-timeout", "10", "--max-time", "300", "--output", target
        ]
        headers.each { |header| command += ["--header", header] }
        command << url
      end

      private

      def token_value
        GitHub.env_token(@env)
      end

      def prerelease_needed?(policy, requested_version)
        policy == "latest-prerelease" || !requested_version.to_s.empty?
      end

      def fetch(repo, include_prerelease:)
        path = include_prerelease ? "/repos/#{repo}/releases?per_page=100" : "/repos/#{repo}/releases/latest"
        result = @runner.capture(curl_command("#{API_ROOT}#{path}"))
        ErrorMapper.from_text!(result.stderr, repo: repo) unless result.success?
        response = CurlResponse.parse(result.stdout)
        ErrorMapper.from_status!(response.status, response.body, response.headers, repo: repo)

        if include_prerelease
          GitHub.normalize_release_array(GitHub.parse_json(response.body))
        else
          [GitHub.normalize_release(GitHub.parse_json(response.body))]
        end
      rescue URI::InvalidURIError
        raise GitHubError, "Invalid GitHub repository: #{repo}"
      end

      def curl_command(url)
        command = [
          "curl", "--fail-with-body", "--location", "--silent", "--show-error",
          "--connect-timeout", "10", "--max-time", "30", "--dump-header", "-", url
        ]
        token = token_value
        command.insert(-2, "--header", "Authorization: Bearer #{token}") if token
        command.insert(-2, "--header", "Accept: application/vnd.github+json")
        command.insert(-2, "--header", "X-GitHub-Api-Version: 2022-11-28")
        command
      end
    end

    class CurlResponse
      attr_reader :status, :headers, :body

      def self.parse(raw)
        sections = raw.split(/\r?\n\r?\n/)
        header_block = sections.shift || ""
        header_block = sections.shift while sections.first&.start_with?("HTTP/")

        status = header_block.lines.first.to_s.split[1].to_i
        headers = {}
        header_block.lines.drop(1).each do |line|
          key, value = line.split(":", 2)
          headers[key.downcase] = value.strip if key && value
        end

        new(status, headers, sections.join("\n\n"))
      end

      def initialize(status, headers, body)
        @status = status
        @headers = headers
        @body = body
      end
    end

    module ErrorMapper
      module_function

      def from_status!(status, body, headers = {}, repo: nil)
        case status
        when 200..299 then nil
        when 0 then raise NetworkError, "GitHub network request failed before an HTTP response was received."
        when 401 then raise UnauthorizedError, "GitHub authentication failed. Run `gh auth login` or set GH_TOKEN/GITHUB_TOKEN."
        when 403
          reset_at = reset_time(headers)
          message = "GitHub API rate limit was exhausted."
          message += " Try again after #{reset_at}." if reset_at
          raise RateLimitError.new(message, reset_at: reset_at)
        when 404 then raise NotFoundError, not_found_message(repo)
        else
          raise NetworkError, "GitHub request failed with HTTP #{status}: #{body.to_s.strip}"
        end
      end

      def from_text!(text, repo: nil)
        case text.to_s.downcase
        when /unauthorized|bad credentials|authentication/
          raise UnauthorizedError, "GitHub authentication failed. Run `gh auth login` or set GH_TOKEN/GITHUB_TOKEN."
        when /rate limit|api rate limit/
          raise RateLimitError, "GitHub API rate limit was exhausted."
        when /not found|could not resolve|no release/
          raise NotFoundError, not_found_message(repo)
        when /timed out|timeout|could not connect|failed to connect/
          raise NetworkError, "GitHub network request failed: #{text.strip}"
        else
          raise GitHubError, text.to_s.strip.empty? ? "GitHub request failed." : text.strip
        end
      end

      def reset_time(headers)
        value = headers["x-ratelimit-reset"]
        return nil unless value

        Time.at(value.to_i).getlocal.strftime("%Y-%m-%d %H:%M:%S %Z")
      end

      def not_found_message(repo)
        target = repo.to_s.empty? ? "the requested repository or release" : repo.to_s
        "GitHub repository or release was not found for #{target}. " \
          "Check the repository name. If it is private, run `gh auth login` or set GH_TOKEN/GITHUB_TOKEN with access."
      end
    end

    module_function

    def env_token(env)
      token = env["GH_TOKEN"] || env["GITHUB_TOKEN"] || env["HOMEBREW_GITHUB_API_TOKEN"]
      token unless token.to_s.empty?
    end

    def parse_json(text)
      JSON.parse(text)
    rescue JSON::ParserError => e
      raise MalformedResponseError, "GitHub returned malformed JSON: #{e.message}"
    end

    def normalize_release_array(data)
      raise MalformedResponseError, "GitHub release list must be an array" unless data.is_a?(Array)

      releases = data.map { |item| normalize_release(item) }
      raise NoReleasesError, "No GitHub Releases were found." if releases.empty?

      releases
    end

    def normalize_release(data)
      raise MalformedResponseError, "GitHub release must be an object" unless data.is_a?(Hash)

      Release.new(
        tag_name: data.fetch("tagName") { data.fetch("tag_name") },
        name: data["name"],
        draft: !!(data["isDraft"] || data["draft"]),
        prerelease: !!(data["isPrerelease"] || data["prerelease"]),
        published_at: parse_time(data["publishedAt"] || data["published_at"]),
        assets: Array(data["assets"]).map { |asset| normalize_asset(asset) }
      )
    rescue KeyError => e
      raise MalformedResponseError, "GitHub release is missing #{e.key}"
    end

    def normalize_asset(data)
      browser = data["browser_download_url"]
      Asset.new(
        name: data["name"],
        url: browser || data["url"],
        api_url: data["apiUrl"] || (browser ? data["url"] : nil)
      )
    end

    def parse_time(value)
      return nil if value.to_s.empty?

      Time.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end

# frozen_string_literal: true

require "json"
require "open3"
require "time"
require "uri"

module Ghcask
  module GitHub
    class Error < StandardError; end
    class UnauthorizedError < Error; end
    class RateLimitError < Error
      attr_reader :reset_at

      def initialize(message, reset_at: nil)
        @reset_at = reset_at
        super(message)
      end
    end
    class NotFoundError < Error; end
    class NoReleasesError < Error; end
    class NoStableReleaseError < Error; end
    class RequestedVersionNotFoundError < Error; end
    class MalformedResponseError < Error; end
    class NetworkError < Error; end

    Release = Struct.new(:tag_name, :name, :draft, :prerelease, :published_at, :assets, keyword_init: true)
    Asset = Struct.new(:name, :url, :size, :content_type, keyword_init: true)

    class Client
      def initialize(runner: CommandRunner.new, env: ENV, host: "github.com")
        @runner = runner
        @env = env
        @host = host
      end

      def releases(repo, include_prerelease: false)
        backend = backend_for(repo, include_prerelease: include_prerelease)
        backend.releases(repo, include_prerelease: include_prerelease)
      end

      def select_release(repo, policy:, requested_version: nil)
        include_prerelease = policy == "latest-prerelease" || !requested_version.to_s.empty?
        backend = backend_for(repo, include_prerelease: include_prerelease)
        return backend.select_release(repo, policy: policy, requested_version: requested_version) if backend.respond_to?(:select_release)

        ReleaseSelector.new(backend.releases(repo, include_prerelease: include_prerelease)).select(
          policy: policy,
          requested_version: requested_version
        )
      end

      def backend_for(_repo, include_prerelease:)
        if @runner.executable?("gh") && gh_authenticated?
          GhBackend.new(@runner, include_list: include_prerelease)
        else
          CurlBackend.new(@runner, @env, @host)
        end
      end

      private

      def gh_authenticated?
        result = @runner.capture(["gh", "auth", "status", "--active", "--hostname", @host, "--json", "hosts"])
        return false unless result.success?

        data = GitHub.parse_json(result.stdout)
        accounts = Array(data.fetch("hosts", {}).fetch(@host, []))
        accounts.any? { |account| account["active"] && account["state"] == "success" }
      rescue MalformedResponseError
        false
      end
    end

    class ReleaseSelector
      def initialize(releases)
        @releases = releases.reject(&:draft)
      end

      def select(policy:, requested_version: nil)
        return specific(requested_version) unless requested_version.to_s.empty?

        case policy
        when "latest-stable"
          latest_stable
        when "latest-prerelease"
          latest_any
        else
          raise Error, "unknown release policy: #{policy}"
        end
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
        normalized = normalize_version(requested_version)
        release = ordered.find do |candidate|
          candidate.tag_name == requested_version || normalize_version(candidate.tag_name) == normalized
        end
        unless release
          raise RequestedVersionNotFoundError,
                "Requested version #{requested_version} was not found in GitHub Releases."
        end

        release
      end

      def ordered
        @releases.sort_by { |release| release.published_at || Time.at(0) }.reverse
      end

      def normalize_version(version)
        version.to_s.sub(/\Av/i, "")
      end
    end

    class GhBackend
      VIEW_FIELDS = "tagName,name,isDraft,isPrerelease,publishedAt,assets"
      LIST_FIELDS = "tagName,name,isDraft,isPrerelease,publishedAt"

      def initialize(runner, include_list:)
        @runner = runner
        @include_list = include_list
      end

      def releases(repo, include_prerelease:)
        if @include_list || include_prerelease
          result = @runner.capture(["gh", "release", "list", "-R", repo, "--limit", "100", "--json", LIST_FIELDS])
          map_error!(result, repo: repo)
          summaries = GitHub.normalize_release_array(GitHub.parse_json(result.stdout))
          summaries.map { |release| view_release(repo, release.tag_name) }
        else
          [view_release(repo, nil)]
        end
      end

      def select_release(repo, policy:, requested_version: nil)
        if policy == "latest-stable" && requested_version.to_s.empty?
          return ReleaseSelector.new([view_release(repo, nil)]).select(policy: policy, requested_version: requested_version)
        end

        result = @runner.capture(["gh", "release", "list", "-R", repo, "--limit", "100", "--json", LIST_FIELDS])
        map_error!(result, repo: repo)
        summary = ReleaseSelector.new(GitHub.normalize_release_array(GitHub.parse_json(result.stdout))).select(
          policy: policy,
          requested_version: requested_version
        )
        view_release(repo, summary.tag_name)
      end

      private

      def view_release(repo, tag)
        command = ["gh", "release", "view"]
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

      def releases(repo, include_prerelease:)
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
        raise Error, "Invalid GitHub repository: #{repo}"
      end

      def select_release(repo, policy:, requested_version: nil)
        include_prerelease = policy == "latest-prerelease" || !requested_version.to_s.empty?
        ReleaseSelector.new(releases(repo, include_prerelease: include_prerelease)).select(
          policy: policy,
          requested_version: requested_version
        )
      end

      private

      def curl_command(url)
        command = [
          "curl",
          "--fail-with-body",
          "--location",
          "--silent",
          "--show-error",
          "--connect-timeout",
          "10",
          "--max-time",
          "30",
          "--dump-header",
          "-",
          url
        ]
        token = @env["GH_TOKEN"] || @env["GITHUB_TOKEN"]
        command.insert(-2, "--header", "Authorization: Bearer #{token}") if token && !token.empty?
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
        while sections.first && sections.first.start_with?("HTTP/")
          header_block = sections.shift
        end

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

    class CommandRunner
      Result = Struct.new(:stdout, :stderr, :status, keyword_init: true) do
        def success?
          status.success?
        end
      end

      def executable?(name)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
          path = File.join(dir, name)
          File.file?(path) && File.executable?(path)
        end
      end

      def capture(command)
        stdout, stderr, status = Open3.capture3(*command)
        Result.new(stdout: stdout, stderr: stderr, status: status)
      rescue Errno::ENOENT => e
        Result.new(stdout: "", stderr: e.message, status: FailureStatus.new)
      end
    end

    class FailureStatus
      def success?
        false
      end
    end

    module ErrorMapper
      module_function

      def from_status!(status, body, headers = {}, repo: nil)
        case status
        when 200..299
          nil
        when 0
          raise NetworkError, "GitHub network request failed before an HTTP response was received."
        when 401
          raise UnauthorizedError, "GitHub authentication failed. Run `gh auth login` or set GH_TOKEN/GITHUB_TOKEN."
        when 403
          reset_at = reset_time(headers)
          message = "GitHub API rate limit was exhausted."
          message += " Try again after #{reset_at}." if reset_at
          raise RateLimitError.new(message, reset_at: reset_at)
        when 404
          raise NotFoundError, not_found_message(repo)
        else
          raise NetworkError, "GitHub request failed with HTTP #{status}: #{body.to_s.strip}"
        end
      end

      def from_text!(text, repo: nil)
        normalized = text.to_s.downcase
        case normalized
        when /unauthorized|bad credentials|authentication/
          raise UnauthorizedError, "GitHub authentication failed. Run `gh auth login` or set GH_TOKEN/GITHUB_TOKEN."
        when /rate limit|api rate limit/
          raise RateLimitError, "GitHub API rate limit was exhausted."
        when /not found|could not resolve|no release/
          raise NotFoundError, not_found_message(repo)
        when /timed out|timeout|could not connect|failed to connect/
          raise NetworkError, "GitHub network request failed: #{text.strip}"
        else
          raise Error, text.to_s.strip.empty? ? "GitHub request failed." : text.strip
        end
      end

      def reset_time(headers)
        value = headers["x-ratelimit-reset"]
        return nil unless value

        Time.at(value.to_i).getlocal.strftime("%Y-%m-%d %H:%M:%S %Z")
      end

      def not_found_message(repo)
        target = repo.to_s.empty? ? "the requested repository or release" : "#{repo}"
        "GitHub repository or release was not found for #{target}. " \
          "Check the repository name. If it is private, run `gh auth login` or set GH_TOKEN/GITHUB_TOKEN with access."
      end
    end

    module_function

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
        tag_name: data.fetch("tagName"),
        name: data["name"],
        draft: !!data["isDraft"],
        prerelease: !!data["isPrerelease"],
        published_at: parse_time(data["publishedAt"]),
        assets: Array(data["assets"]).map { |asset| normalize_asset(asset) }
      )
    rescue KeyError => e
      raise MalformedResponseError, "GitHub release is missing #{e.key}"
    end

    def normalize_asset(data)
      Asset.new(
        name: data["name"],
        url: data["url"] || data["browserDownloadUrl"] || data["downloadUrl"],
        size: data["size"],
        content_type: data["contentType"]
      )
    end

    def parse_time(value)
      return nil if value.nil? || value.empty?

      Time.parse(value)
    rescue ArgumentError
      nil
    end
  end
end

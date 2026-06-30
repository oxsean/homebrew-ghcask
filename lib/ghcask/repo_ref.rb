# frozen_string_literal: true

require "uri"

require "ghcask/errors"

module Ghcask
  # Parses the GitHub repository references the CLI accepts: `owner/repo`,
  # `https://github.com/owner/repo`, and release-tag URLs
  # (`.../releases/tag/v1.2.3`, which also yields the pinned version).
  module RepoRef
    Parsed = Struct.new(:repo, :version, keyword_init: true)

    module_function

    def parse(value)
      raw = value.to_s.strip
      raise SourceError, "repository is required. Usage: brew ghcask <command> owner/repo" if raw.empty?

      parsed = raw.start_with?("http://", "https://") ? parse_url(raw) : Parsed.new(repo: raw, version: nil)
      parsed.repo = parsed.repo.sub(/\.git\z/i, "")

      unless parsed.repo.match?(%r{\A[^/\s]+/[^/\s]+\z})
        raise SourceError, "repository must look like owner/repo or https://github.com/owner/repo"
      end

      parsed
    end

    def parse_url(raw)
      uri = URI.parse(raw)
      unless uri.scheme == "https" && uri.host == "github.com"
        raise SourceError, "only https://github.com/owner/repo URLs are supported"
      end

      parts = uri.path.split("/").reject(&:empty?)
      raise SourceError, "repository URL must include owner and repo" if parts.length < 2

      Parsed.new(repo: "#{parts[0]}/#{parts[1]}", version: release_tag_from_parts(parts))
    rescue URI::InvalidURIError
      raise SourceError, "invalid GitHub repository URL"
    end

    def release_tag_from_parts(parts)
      tag_index = parts.each_cons(2).with_index.find { |pair, _index| pair == %w[releases tag] }&.last
      return nil unless tag_index

      parts[tag_index + 2]
    end
  end
end

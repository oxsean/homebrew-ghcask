# frozen_string_literal: true

require "uri"

module Ghcask
  module RepoRef
    class Error < StandardError; end
    Parsed = Struct.new(:repo, :version, keyword_init: true)

    module_function

    def normalize(value)
      parse(value).repo
    end

    def parse(value)
      raw = value.to_s.strip
      raise Error, "repository is required. Usage: brew ghcask install owner/repo" if raw.empty?

      parsed = raw.start_with?("http://", "https://") ? parse_url(raw) : Parsed.new(repo: raw, version: nil)
      repo = parsed.repo
      repo = repo.sub(/\.git\z/i, "")
      parsed.repo = repo

      unless repo.match?(%r{\A[^/\s]+/[^/\s]+\z})
        raise Error, "repository must look like owner/repo or https://github.com/owner/repo"
      end

      parsed
    end

    def normalize_url(raw)
      parse_url(raw).repo
    end

    def parse_url(raw)
      uri = URI.parse(raw)
      unless uri.scheme == "https" && uri.host == "github.com"
        raise Error, "only https://github.com/owner/repo URLs are supported"
      end

      parts = uri.path.split("/").reject(&:empty?)
      raise Error, "repository URL must include owner and repo" if parts.length < 2

      Parsed.new(
        repo: "#{parts[0]}/#{parts[1]}",
        version: release_tag_from_parts(parts)
      )
    rescue URI::InvalidURIError
      raise Error, "invalid GitHub repository URL"
    end

    def release_tag_from_parts(parts)
      tag_index = parts.each_cons(2).with_index.find { |pair, _index| pair == %w[releases tag] }&.last
      return nil unless tag_index

      parts[tag_index + 2]
    end
  end
end

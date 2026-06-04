# frozen_string_literal: true

require "uri"

module Ghcask
  module DirectUrl
    class Error < StandardError; end
    ARCH_VERSION_SUFFIX = /\A(?:aarch64|amd64|arm64|darwin|intel|mac|macos|universal|x64|x86-64)\z/i

    module_function

    def package_url(raw)
      uri = URI.parse(raw.to_s)
      raise URI::InvalidURIError unless uri.is_a?(URI::HTTP) && uri.host && !uri.path.to_s.empty?
      raise Error, "Direct URL package type is not supported yet. Use a .dmg, .zip, .tar.gz, or .tgz URL." unless package_path?(uri.path)

      uri.to_s
    rescue URI::InvalidURIError
      raise Error, "Invalid direct package URL: #{raw.inspect}"
    end

    def homepage(url)
      uri = URI.parse(url)
      if uri.host&.downcase == "github.com"
        parts = uri.path.split("/").reject(&:empty?)
        return "https://github.com/#{parts[0]}/#{parts[1]}" if parts.length >= 2
      end

      "#{uri.scheme}://#{uri.host}"
    end

    def asset_name(url)
      File.basename(URI.parse(url).path)
    end

    def package_path?(path)
      path.to_s.downcase.end_with?(".dmg", ".zip", ".tar.gz", ".tgz")
    end

    def version_from_filename(filename)
      base = File.basename(filename.to_s, File.extname(filename.to_s))
      match = base.match(/(?:^|[-_])v?(\d+(?:\.\d+)+(?:[-_][0-9A-Za-z.-]+)?)(?:$|[-_])/)
      return nil unless match

      version = match[1].tr("_", "-")
      parts = version.split("-")
      parts.pop if parts.length > 1 && parts.last.match?(ARCH_VERSION_SUFFIX)
      parts.join("-")
    end
  end
end

# frozen_string_literal: true

require "uri"

require "ghcask/errors"
require "ghcask/package_format"

module Ghcask
  # Validates and inspects direct package URLs (the extensions in PackageFormat)
  # and derives the homepage, asset name, and a best-effort version from the
  # filename when the package is not behind a GitHub Release.
  module DirectUrl
    ARCH_VERSION_SUFFIX = /\A(?:aarch64|amd64|arm64|darwin|intel|mac|macos|universal|x64|x86-64)\z/i.freeze

    module_function

    def package_url(raw)
      uri = URI.parse(raw.to_s)
      raise URI::InvalidURIError unless uri.is_a?(URI::HTTP) && uri.host && !uri.path.to_s.empty?
      raise SourceError, "Unsupported direct URL package type. Use one of: #{PackageFormat::EXTENSIONS.sort.join(", ")}." unless package_path?(uri.path)

      uri.to_s
    rescue URI::InvalidURIError
      raise SourceError, "Invalid direct package URL: #{raw.inspect}"
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
      PackageFormat.package?(path)
    end

    def github_host?(url)
      host = URI.parse(url.to_s).host&.downcase
      host == "github.com" || host == "raw.githubusercontent.com"
    rescue URI::InvalidURIError
      false
    end

    def version_from_filename(filename)
      base = File.basename(filename.to_s)
      ext = PackageFormat.extension(base)
      base = base[0...-ext.length] if ext
      match = base.match(/(?:^|[-_])v?(\d+(?:\.\d+)+(?:[-_][0-9A-Za-z.-]+)?)(?:$|[-_])/)
      return nil unless match

      version = match[1].tr("_", "-")
      parts = version.split("-")
      parts.pop if parts.length > 1 && parts.last.match?(ARCH_VERSION_SUFFIX)
      parts.join("-")
    end
  end
end

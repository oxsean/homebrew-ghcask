# frozen_string_literal: true

require "ghcask/errors"
require "ghcask/package_format"

module Ghcask
  # Scores GitHub Release assets to pick the right macOS package for an
  # architecture, excluding obvious non-macOS / non-installer files. `--asset`
  # bypasses scoring with a case-insensitive glob.
  class AssetSelector
    ARCH_MARKERS = {
      "arm64" => %w[arm64 aarch64 apple-silicon apple_silicon universal],
      "x86_64" => %w[x64 x86_64 amd64 intel universal]
    }.freeze

    OTHER_ARCH_MARKERS = {
      "arm64" => %w[x64 x86_64 amd64 intel],
      "x86_64" => %w[arm64 aarch64 apple-silicon apple_silicon]
    }.freeze

    TYPE_SCORE = { dmg: 30, pkg: 25, zip: 20, tar: 15 }.freeze

    EXCLUDED_RE = /
      checksum|checksums|sha256|sha512|\.sig\z|\.asc\z|
      source|src|symbols?|debug|dSYM|
      windows|win32|win64|\.exe\z|\.msi\z|linux|ubuntu|debian|rpm|\.deb\z|\.rpm\z
    /ix.freeze

    MACOS_MARKERS = %w[darwin macos osx mac apple].freeze

    FOREIGN_OS_RE = /(?:^|[^a-z0-9])(?:win(?=-)|freebsd|openbsd|netbsd|android)/.freeze

    BARE_BINARY_TAIL = /(?:^|[-.])(?:arm64|aarch64|x86-64|x64|amd64|universal|darwin|macos|osx|mac|apple)\z/.freeze

    ScoredAsset = Struct.new(:asset, :score)

    attr_reader :assets, :arch

    def self.local_arch
      raw = `uname -m`.strip
      raw.empty? ? "x86_64" : raw
    end

    def initialize(assets, arch: self.class.local_arch)
      @assets = assets
      @arch = arch
    end

    def select(pattern: nil)
      return select_by_pattern(pattern) if pattern && !pattern.empty?

      scored = assets.map { |asset| ScoredAsset.new(asset, score(asset)) }
                     .select { |entry| entry.score.positive? }
                     .sort_by { |entry| [-entry.score, entry.asset.name] }

      if scored.empty?
        names = assets.map(&:name).reject { |name| name.to_s.empty? }
        listing = names.empty? ? "" : " Available assets: #{names.join(", ")}. Pass --asset to pick one."
        raise NoAssetMatchError, "No compatible macOS release asset was found.#{listing}"
      end

      top_score = scored.first.score
      winners = scored.select { |entry| entry.score == top_score }.map(&:asset)
      raise AmbiguousAssetError, winners if winners.length > 1

      winners.first
    end

    def macos_candidate?(asset)
      name = asset.name.to_s
      normalized = normalize_name(name)
      return false if excluded?(normalized)
      return true if PackageFormat.package?(name)

      bare_binary?(normalized)
    end

    def score(asset)
      name = asset.name.to_s
      normalized = normalize_name(name)
      return -100 if excluded?(normalized)

      type = PackageFormat.type(name)
      base = type ? TYPE_SCORE.fetch(type) : 0
      if base.zero?
        return -100 unless bare_binary?(normalized)

        base = 10
      end

      score = base
      local_markers = ARCH_MARKERS.fetch(arch, [arch])
      other_markers = OTHER_ARCH_MARKERS.fetch(arch, [])

      if marker_match?(normalized, local_markers - ["universal"])
        score += 100
      elsif marker_match?(normalized, ["universal"])
        score += 70
      elsif marker_match?(normalized, other_markers)
        score -= 100
      elsif plausible_macos_assets.length == 1
        score += 40
      end

      score
    end

    private

    def select_by_pattern(pattern)
      matches = assets.select { |asset| File.fnmatch?(pattern, asset.name.to_s, File::FNM_CASEFOLD) }
      raise NoAssetMatchError, "No release asset matched --asset #{pattern.inspect}." if matches.empty?
      raise AmbiguousAssetError, matches if matches.length > 1

      matches.first
    end

    def plausible_macos_assets
      @plausible_macos_assets ||= assets.select { |asset| plausible?(asset) }
    end

    def plausible?(asset)
      name = asset.name.to_s
      return false if excluded?(normalize_name(name))

      PackageFormat.package?(name)
    end

    def excluded?(normalized)
      normalized.match?(EXCLUDED_RE) || normalized.match?(FOREIGN_OS_RE)
    end

    def bare_binary?(normalized)
      marker_match?(normalized, MACOS_MARKERS) && normalized.match?(BARE_BINARY_TAIL)
    end

    def marker_match?(normalized, markers)
      markers.any? do |marker|
        normalized.match?(/(^|[^a-z0-9])#{Regexp.escape(marker.downcase.tr("_", "-"))}([^a-z0-9]|\z)/)
      end
    end

    def normalize_name(name)
      name.downcase.tr("_", "-")
    end
  end
end

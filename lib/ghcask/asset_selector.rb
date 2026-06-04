# frozen_string_literal: true

module Ghcask
  class AssetSelector
    class Error < StandardError; end
    class NoMatchError < Error; end
    class AmbiguousError < Error
      attr_reader :candidates

      def initialize(candidates)
        @candidates = candidates
        super("Multiple plausible macOS assets matched: #{candidates.map(&:name).join(", ")}")
      end
    end

    ARCH_MARKERS = {
      "arm64" => %w[arm64 aarch64 apple-silicon apple_silicon universal],
      "x86_64" => %w[x64 x86_64 amd64 intel universal]
    }.freeze

    OTHER_ARCH_MARKERS = {
      "arm64" => %w[x64 x86_64 amd64 intel],
      "x86_64" => %w[arm64 aarch64 apple-silicon apple_silicon]
    }.freeze

    EXTENSION_SCORE = {
      ".dmg" => 30,
      ".zip" => 20,
      ".tar.gz" => 15,
      ".tgz" => 15
    }.freeze

    EXCLUDED_RE = /
      checksum|checksums|sha256|sha512|\.sig\z|\.asc\z|
      source|src|symbols?|debug|dSYM|\.tar\.xz\z|
      windows|win32|win64|\.exe\z|\.msi\z|linux|ubuntu|debian|rpm|\.deb\z|\.rpm\z
    /ix.freeze

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

      raise NoMatchError, "No compatible macOS release asset was found." if scored.empty?

      top_score = scored.first.score
      winners = scored.select { |entry| entry.score == top_score }.map(&:asset)
      raise AmbiguousError, winners if winners.length > 1

      winners.first
    end

    def score(asset)
      name = asset.name.to_s
      normalized = normalize_name(name)
      return -100 if excluded?(normalized)

      extension_score = EXTENSION_SCORE.fetch(extension(name), 0)
      return -100 if extension_score.zero?

      score = extension_score
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

    ScoredAsset = Struct.new(:asset, :score)

    def select_by_pattern(pattern)
      matches = assets.select { |asset| File.fnmatch?(pattern, asset.name.to_s, File::FNM_CASEFOLD) }
      raise NoMatchError, "No release asset matched --asset #{pattern.inspect}." if matches.empty?
      raise AmbiguousError, matches if matches.length > 1

      matches.first
    end

    def plausible_macos_assets
      @plausible_macos_assets ||= assets.select do |asset|
        score_without_single_asset_bonus(asset).positive?
      end
    end

    def score_without_single_asset_bonus(asset)
      name = asset.name.to_s
      normalized = normalize_name(name)
      return -100 if excluded?(normalized)

      extension_score = EXTENSION_SCORE.fetch(extension(name), 0)
      return -100 if extension_score.zero?

      extension_score
    end

    def excluded?(normalized)
      normalized.match?(EXCLUDED_RE)
    end

    def marker_match?(normalized, markers)
      markers.any? do |marker|
        normalized.match?(/(^|[^a-z0-9])#{Regexp.escape(marker.downcase)}([^a-z0-9]|\z)/)
      end
    end

    def extension(name)
      lower = name.downcase
      return ".dmg" if lower.end_with?(".dmg")
      return ".zip" if lower.end_with?(".zip")
      return ".tar.gz" if lower.end_with?(".tar.gz")
      return ".tgz" if lower.end_with?(".tgz")

      File.extname(lower)
    end

    def normalize_name(name)
      name.downcase.tr("_", "-")
    end
  end
end

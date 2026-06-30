# frozen_string_literal: true

module Ghcask
  # Base class for every expected, user-facing error. Command handlers rescue this
  # single type, print "Error: <message>" to stderr, and return 1.
  class Error < StandardError; end

  class UsageError < Error; end

  class RegistryError < Error; end
  class CorruptRegistryError < RegistryError; end

  class HomebrewError < Error; end
  class QuarantineError < Error; end
  class SourceError < Error; end

  class GitHubError < Error; end
  class UnauthorizedError < GitHubError; end
  class NotFoundError < GitHubError; end
  class NoReleasesError < GitHubError; end
  class NoStableReleaseError < GitHubError; end
  class RequestedVersionNotFoundError < GitHubError; end
  class MalformedResponseError < GitHubError; end
  class NetworkError < GitHubError; end

  class RateLimitError < GitHubError
    attr_reader :reset_at

    def initialize(message, reset_at: nil)
      @reset_at = reset_at
      super(message)
    end
  end

  class NoAssetMatchError < Error; end

  class AmbiguousAssetError < Error
    attr_reader :candidates

    def initialize(candidates)
      @candidates = candidates
      names = candidates.map(&:name)
      super("Multiple macOS assets tie for the best match: #{names.join(", ")}. " \
            "Re-run with --asset to pick one, e.g. --asset '#{names.first}'.")
    end
  end

  class DownloadError < Error; end
  class AppInferenceError < Error; end
end

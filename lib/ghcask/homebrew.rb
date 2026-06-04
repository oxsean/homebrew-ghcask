# frozen_string_literal: true

require "fileutils"
require "open3"

module Ghcask
  module Homebrew
    class Error < StandardError; end

    class Cache
      def initialize(runner:, stdout:, stderr:)
        @runner = runner
        @stdout = stdout
        @stderr = stderr
      end

      def cache_cask(cask_name, asset_path)
        cache_path = cask_cache_path(cask_name)
        return unless cache_path

        FileUtils.mkdir_p(File.dirname(cache_path))
        FileUtils.rm_f(cache_path)
        FileUtils.mv(asset_path, cache_path)
        @stdout.puts "Cached package for Homebrew: #{cache_path}"
        cache_path
      rescue StandardError => e
        @stderr.puts "Warning: Could not cache package for Homebrew. Homebrew may download again. #{e.message}"
        nil
      end

      private

      def cask_cache_path(cask_name)
        command = ["brew", "--cache", "--cask", "ghcask/local/#{cask_name}"]
        result = @runner.capture(command)
        return result.stdout.lines.map(&:strip).reject(&:empty?).last if result.success?

        message = error_summary(result.stderr.strip.empty? ? result.stdout : result.stderr)
        @stderr.puts "Warning: Could not determine Homebrew cache path. Homebrew may download again. #{message}"
        nil
      end

      def error_summary(text)
        lines = text.lines.map(&:strip).reject(&:empty?)
        lines.find { |line| line.start_with?("Error:") } ||
          lines.reverse.find { |line| line.match?(/\berror:/i) } ||
          lines.last ||
          "command failed"
      end
    end

    module_function

    def repository
      override = ENV["GHCASK_BREW_REPOSITORY"]
      return File.expand_path(override) if override && !override.empty?

      stdout, stderr, status = Open3.capture3("brew", "--repository")
      unless status.success?
        message = stderr.strip.empty? ? "brew --repository failed" : stderr.strip
        raise Error, message
      end

      path = stdout.strip
      raise Error, "brew --repository returned an empty path" if path.empty?

      path
    rescue Errno::ENOENT
      raise Error, "Homebrew is required but `brew` was not found in PATH"
    end
  end
end

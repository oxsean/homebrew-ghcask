# frozen_string_literal: true

require "ghcask/command_runner"
require "ghcask/errors"

module Ghcask
  # The quarantine xattr on installed app bundles: strips it after a `--no-quarantine`
  # install, else warns if Gatekeeper would block an unsigned app. Paths come from
  # Homebrew's real artifact targets (not a hardcoded /Applications/<App>.app).
  class Quarantine
    def initialize(runner: CommandRunner.new, stdout: $stdout, stderr: $stderr)
      @runner = runner
      @stdout = stdout
      @stderr = stderr
    end

    def release(paths)
      targets = Array(paths).map(&:to_s).reject(&:empty?).select { |path| File.exist?(path) }
      if targets.empty?
        @stderr.puts "Warning: Could not find an installed app bundle to clear quarantine from."
        return []
      end

      targets.each { |path| release_path(path) }
      @stdout.puts "Cleared quarantine: #{targets.join(", ")}"
      targets
    end

    def warn_if_blocked(paths)
      Array(paths).map(&:to_s).reject(&:empty?).each do |path|
        next unless File.exist?(path)
        next if gatekeeper_ok?(path)

        @stderr.puts "Warning: #{File.basename(path)} is not signed/notarized and is quarantined; macOS may refuse to open it."
        @stderr.puts "  Allow it with: xattr -dr com.apple.quarantine #{path.inspect}"
      end
    end

    private

    def gatekeeper_ok?(path)
      return true unless @runner.executable?("spctl")

      @runner.capture(["spctl", "--assess", "--type", "execute", path]).success?
    end

    def release_path(path)
      result = @runner.capture(["xattr", "-dr", "com.apple.quarantine", path])
      return if result.success?

      message = result.stderr.strip.empty? ? result.stdout.strip : result.stderr.strip
      return if message.match?(/no such xattr/i)

      raise QuarantineError,
            "Failed to clear quarantine for #{path}: #{message}. " \
            "Try `xattr -dr com.apple.quarantine #{path.inspect}` manually."
    end
  end
end

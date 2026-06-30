# frozen_string_literal: true

require "open3"

module Ghcask
  # The seam for external processes we capture; injected so tests use a fake. Package
  # (unpack) and the GitHub download path shell out directly for TTY progress and are
  # faked via the `package:` / `github:` injections instead.
  class CommandRunner
    Result = Struct.new(:stdout, :stderr, :status, keyword_init: true) do
      def success?
        status.success?
      end
    end

    # Stands in for a Process::Status when the executable is missing entirely.
    class Failure
      def success?
        false
      end
    end

    def capture(command)
      stdout, stderr, status = Open3.capture3(*command)
      Result.new(stdout: stdout, stderr: stderr, status: status)
    rescue Errno::ENOENT => e
      Result.new(stdout: "", stderr: e.message, status: Failure.new)
    end

    def executable?(name)
      !which(name).nil?
    end

    def which(name)
      if name.include?(File::SEPARATOR)
        return name if File.file?(name) && File.executable?(name)

        return nil
      end

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir, name)
        return path if File.file?(path) && File.executable?(path)
      end
      nil
    end
  end
end

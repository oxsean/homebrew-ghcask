# frozen_string_literal: true

module Ghcask
  class Doctor
    REQUIRED_TOOLS = %w[brew curl hdiutil ditto tar shasum plutil].freeze
    OPTIONAL_TOOLS = %w[gh].freeze

    def initialize(argv, stdout:, stderr:)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
    end

    def run
      return help if help_requested?

      unknown = @argv.reject { |arg| arg == "--dry-run" }
      unless unknown.empty?
        @stderr.puts "ghcask doctor: unknown option #{unknown.first}"
        return 1
      end

      @stdout.puts "ghcask doctor"
      @stdout.puts "Dry run: #{dry_run? ? "yes" : "no"}"
      @stdout.puts
      report_tools("Required tools", REQUIRED_TOOLS)
      @stdout.puts
      report_tools("Optional tools", OPTIONAL_TOOLS)
      0
    end

    private

    def help_requested?
      @argv.include?("-h") || @argv.include?("--help")
    end

    def dry_run?
      @argv.include?("--dry-run")
    end

    def help
      @stdout.puts <<~HELP
        Usage:
          brew ghcask doctor [--dry-run]

        Diagnose Homebrew, GitHub access, and local generated cask state.
      HELP
      0
    end

    def report_tools(title, tools)
      @stdout.puts "#{title}:"
      tools.each do |tool|
        path = find_executable(tool)
        status = path ? "ok #{path}" : "missing"
        @stdout.puts "  #{tool}: #{status}"
      end
    end

    def find_executable(name)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir, name)
        return path if File.file?(path) && File.executable?(path)
      end
      nil
    end
  end
end

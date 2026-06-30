# frozen_string_literal: true

require "ghcask/commands/base"

module Ghcask
  module Commands
    # `doctor` — reports whether the external tools ghcask shells out to are
    # present. It only uses the command runner (never the tap), so it works even
    # when Homebrew itself is missing. `xattr` is required because of
    # `--no-quarantine`.
    class Doctor < Base
      REQUIRED_TOOLS = %w[brew curl hdiutil ditto tar plutil xattr xar file].freeze
      OPTIONAL_TOOLS = %w[gh spctl].freeze

      def run
        return help if help_requested?

        unknown = @argv.reject { |arg| arg == "--dry-run" }
        unless unknown.empty?
          stderr.puts "Error: unknown option #{unknown.first}"
          return 1
        end

        stdout.puts "ghcask doctor"
        stdout.puts "Dry run: #{dry_run? ? "yes" : "no"}"
        stdout.puts
        report_tools("Required tools", REQUIRED_TOOLS)
        stdout.puts
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
        stdout.puts <<~HELP
          Usage:
            brew ghcask doctor [--dry-run]

          Report whether the external tools ghcask shells out to are installed.
        HELP
        0
      end

      def report_tools(title, tools)
        stdout.puts "#{title}:"
        tools.each do |tool|
          path = runner.which(tool)
          stdout.puts "  #{tool}: #{path ? "ok #{path}" : "missing"}"
        end
      end
    end
  end
end

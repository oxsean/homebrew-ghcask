# frozen_string_literal: true

require "ghcask/commands/base"

module Ghcask
  module Commands
    # `init` — prepare or repair the generated local tap. Normal commands create
    # it on demand; this is the explicit setup/repair entry point.
    class Init < Base
      def run
        guard do
          if @argv.include?("-h") || @argv.include?("--help")
            stdout.puts <<~HELP
              Usage:
                brew ghcask init

              Prepare or repair local generated cask storage.
            HELP
            next 0
          end
          raise UsageError, "unknown option #{@argv.first}" unless @argv.empty?

          tap.init
          stdout.puts "Initialized ghcask local tap:"
          stdout.puts "  tap: #{tap.root}"
          stdout.puts "  casks: #{tap.casks_dir}"
          stdout.puts "  registry: #{tap.registry_path}"
          0
        end
      end
    end
  end
end

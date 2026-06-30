# frozen_string_literal: true

require "optparse"
require "time"

require "ghcask/catalog"
require "ghcask/command_runner"
require "ghcask/errors"
require "ghcask/github"
require "ghcask/homebrew"
require "ghcask/local_tap"
require "ghcask/package"
require "ghcask/quarantine"
require "ghcask/repo_ref"

module Ghcask
  module Commands
    # Shared wiring for command handlers: DI collaborators (built lazily so `doctor`
    # never shells out to resolve the Homebrew repo), the `guard` error→exit funnel,
    # and cask-resolution helpers. Subcommand methods call `guard { ...; 0 }`.
    class Base
      def initialize(argv, stdout:, stderr:, github: nil, tap: nil, package: Package,
                     runner: nil, brew: nil, quarantine: nil)
        @argv = argv.dup
        @stdout = stdout
        @stderr = stderr
        @package = package
        @runner = runner
        @github = github
        @tap = tap
        @brew = brew
        @quarantine = quarantine
      end

      private

      attr_reader :argv, :stdout, :stderr, :package

      def runner
        @runner ||= CommandRunner.new
      end

      def github
        @github ||= GitHub::Client.new(runner: runner)
      end

      def tap
        @tap ||= LocalTap.new
      end

      def brew
        @brew ||= Homebrew::Brew.new(runner: runner, stdout: @stdout, stderr: @stderr)
      end

      def quarantine_tool
        @quarantine ||= Quarantine.new(runner: runner, stdout: @stdout, stderr: @stderr)
      end

      def guard
        yield
      rescue OptionParser::ParseError, Ghcask::Error => e
        @stderr.puts "Error: #{e.message}"
        1
      end

      def resolve_entry(catalog, target)
        entry = catalog[target]
        return [target, entry] if entry

        repo = repo_ref_or_nil(target)&.repo
        match = catalog.find_by_repo(repo) if repo
        return match if match

        raise Error, "managed cask not found: #{target}"
      end

      def target_names(catalog, targets)
        return catalog.names if targets.empty?

        targets.map { |target| resolve_entry(catalog, target).first }
      end

      def repo_ref_or_nil(target)
        RepoRef.parse(target)
      rescue SourceError
        nil
      end

      def apply_quarantine_policy(entry)
        return if entry.pkg? # pkg installers have no app bundle to clear/check

        paths = brew.installed_app_paths(entry.cask)
        if entry.quarantine?
          quarantine_tool.warn_if_blocked(paths)
        else
          quarantine_tool.release(paths)
        end
      end

      def split_passthrough(argv)
        index = argv.index("--")
        return [argv.dup, []] unless index

        [argv[0...index], argv[(index + 1)..]]
      end

      def forward_brew_flags(opts, into)
        opts.on("-v", "--verbose", "Pass --verbose to Homebrew") { into << "--verbose" }
        opts.on("-d", "--debug", "Pass --debug to Homebrew") { into << "--debug" }
        opts.on("-q", "--quiet", "Pass --quiet to Homebrew") { into << "--quiet" }
      end
    end
  end
end

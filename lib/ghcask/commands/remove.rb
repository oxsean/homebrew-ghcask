# frozen_string_literal: true

require "fileutils"
require "set"

require "ghcask/commands/base"

module Ghcask
  module Commands
    # `uninstall`/`remove`/`rm` and `cleanup`. Uninstall delegates to brew (warning
    # but continuing if the app is already gone) and marks the entry uninstalled;
    # cleanup prunes stale records or force-removes a named generated cask.
    class Remove < Base
      def uninstall
        guard do
          options = parse_uninstall
          raise UsageError, "cask name or repository is required" if options[:targets].empty?

          catalog = tap.registry.ensure_exists
          names = options[:targets].map { |target| resolve_entry(catalog, target).first }

          if options[:dry_run]
            names.each do |name|
              stdout.puts "Would uninstall #{name} with Homebrew."
              stdout.puts "Would mark #{name} as uninstalled in the ghcask registry."
            end
            next 0
          end

          names.each do |name|
            brew.uninstall(name, force: options[:force], zap: options[:zap], extra: options[:passthrough])
            catalog[name].install_state = Entry::STATE_UNINSTALLED
            stdout.puts "Uninstalled #{name}."
          end
          tap.registry.save(catalog)
          0
        end
      end

      def cleanup
        guard do
          options = parse_cleanup
          catalog = tap.registry.ensure_exists
          removed = cleanup_candidates(catalog, options[:targets])

          if removed.empty?
            stdout.puts "No stale local casks found."
            next 0
          end

          removed.each do |name, reason|
            stdout.puts "#{options[:dry_run] ? "Would remove" : "Removed"} #{reason}: #{name}"
            next if options[:dry_run]

            catalog.delete(name)
            FileUtils.rm_f(tap.cask_path(name))
          end
          tap.registry.save(catalog) unless options[:dry_run]
          0
        end
      end

      private

      def cleanup_candidates(catalog, targets)
        unless targets.empty?
          return targets.map { |target| [resolve_entry(catalog, target).first, "targeted managed cask"] }
        end

        local = tap.cask_names.to_set
        installed = brew.installed_casks
        candidates = []
        catalog.each do |name, entry|
          if !local.include?(name)
            candidates << [name, "registry entry for deleted cask file"]
          elsif entry.uninstalled?
            candidates << [name, "managed cask marked as uninstalled"]
          elsif !entry.generated? && installed && !installed.include?(name)
            candidates << [name, "managed cask uninstalled by Homebrew"]
          end
        end
        (local - catalog.names.to_set).each do |name|
          candidates << [name, "generated cask file without a registry entry"]
        end
        candidates
      end

      def parse_uninstall
        options = { dry_run: false, force: false, zap: false, passthrough: [] }
        args, options[:passthrough] = split_passthrough(@argv)
        OptionParser.new do |opts|
          opts.banner = "Usage: brew ghcask uninstall|remove|rm cask-name|owner/repo [...] [options]"
          opts.on("-n", "--dry-run", "Preview without uninstalling or changing the registry") { options[:dry_run] = true }
          opts.on("-f", "--force", "Pass --force to brew uninstall") { options[:force] = true }
          opts.on("--zap", "Also trash app data (brew uninstall --zap)") { options[:zap] = true }
          forward_brew_flags(opts, options[:passthrough])
        end.parse!(args)
        options[:targets] = args
        options
      end

      def parse_cleanup
        options = { dry_run: false, targets: [] }
        OptionParser.new do |opts|
          opts.banner = "Usage: brew ghcask cleanup [cask-name|owner/repo ...] [options]"
          opts.on("-n", "--dry-run", "Report stale records without removing them") { options[:dry_run] = true }
        end.parse!(@argv)
        options[:targets] = @argv.dup
        options
      end
    end
  end
end

# frozen_string_literal: true

require "tmpdir"

require "ghcask/cask_file"
require "ghcask/commands/base"
require "ghcask/source"

module Ghcask
  module Commands
    # `update`, `upgrade`, `outdated` — re-check GitHub sources. Direct-URL casks are
    # not checkable (skipped, or reported with `--all`). After a `brew upgrade`, a
    # `--no-quarantine` cask gets its xattr stripped again.
    class Upgrade < Base
      def update
        run_refresh("update", upgrade: false)
      end

      def upgrade
        run_refresh("upgrade", upgrade: true)
      end

      def outdated
        guard do
          options = parse_outdated
          catalog = tap.registry.ensure_exists
          names = target_names(catalog, options[:targets])
          installed = brew.installed_versions(names)
          names.each do |name|
            report_outdated(catalog[name], name, installed[name], all: options[:all], greedy: options[:greedy])
          end
          0
        end
      end

      private

      def run_refresh(command, upgrade:)
        guard do
          options = parse_update(command)
          catalog = tap.registry.ensure_exists
          raise UsageError, "update does not accept cask names. Use `brew ghcask upgrade cask-name` to target one app." if !upgrade && !options[:targets].empty?

          names = upgrade ? target_names(catalog, options[:targets]) : catalog.names
          names.each { |name| refresh(catalog, name, options) }
          tap.registry.save(catalog) unless options[:dry_run]

          upgrade_casks(catalog, names, options) if upgrade && !options[:dry_run]
          0
        end
      end

      def refresh(catalog, name, options)
        entry = catalog[name]
        if entry.url?
          stdout.puts "#{name}: direct URL cask, skipping source refresh"
        elsif entry.auto_updates? && !options[:greedy]
          stdout.puts "#{name}: self-updating app (auto_updates), skipping (use --greedy)"
        else
          refresh_github(catalog, name, entry, options)
        end
      end

      def refresh_github(catalog, name, entry, options)
        source = github_source(entry)
        resolution = source.resolve(github)
        release = resolution.release
        asset = resolution.asset

        if !options[:force] && entry.release_tag == release.tag_name && entry.asset_name == asset.name
          stdout.puts "#{name}: already current"
          return
        end

        refreshed = entry.merge(
          "version" => Ghcask.strip_v(release.tag_name),
          "release_tag" => release.tag_name,
          "asset_name" => asset.name,
          "asset_url" => asset.url,
          "updated_at" => Ghcask.now
        )

        if options[:dry_run]
          catalog[name] = refreshed
        else
          Dir.mktmpdir("ghcask-update-") do |dir|
            path = source.download(resolution, github: github, package: package, destination_dir: dir, stdout: stdout)
            final = refreshed.merge(sha256: package.sha256(path))
            catalog[name] = final
            CaskFile.write(tap.cask_path(name), final)
            brew.cache_package(name, path)
          end
        end
        stdout.puts "#{name}: refreshed to #{release.tag_name}"
      end

      def upgrade_casks(catalog, names, options)
        installed = brew.installed_versions(names)
        names.each do |name|
          next if catalog[name].auto_updates? && !options[:greedy]

          installed_version = installed[name]
          next unless installed_version
          next if Ghcask.strip_v(installed_version) == Ghcask.strip_v(catalog[name].version)

          brew.upgrade(name, force: options[:force], extra: options[:passthrough])
          apply_quarantine_policy(catalog[name])
        end
      end

      def report_outdated(entry, name, installed_version, all:, greedy:)
        unless entry.checkable?
          stdout.puts "#{name}: direct URL cask, not checkable" if all
          return
        end
        return if entry.auto_updates? && !all && !greedy

        pinned = entry.pinned? ? " [pinned at #{entry.requested_version}]" : ""
        if installed_version.nil?
          stdout.puts "#{name}: not installed#{pinned}" if all
          return
        end

        latest = Ghcask.strip_v(github.select_release(entry.repo, policy: entry.release_policy, requested_version: nil).tag_name)
        if Ghcask.strip_v(installed_version) == latest
          stdout.puts "#{name}: current #{latest}#{pinned}" if all
          return
        end

        stdout.puts "#{name}: #{Ghcask.strip_v(installed_version)} -> #{latest}#{pinned}"
      end

      def github_source(entry)
        GithubSource.new(
          repo: entry.repo,
          release_policy: entry.release_policy,
          requested_version: entry.requested_version,
          asset_pattern: entry.asset_pattern,
          existing: entry
        )
      end

      def parse_update(command)
        options = { dry_run: false, force: false, greedy: false, targets: [], passthrough: [] }
        args, options[:passthrough] = split_passthrough(@argv)
        parser = OptionParser.new do |opts|
          opts.banner = command == "upgrade" ? "Usage: brew ghcask upgrade [cask-name ...] [options]" : "Usage: brew ghcask update [options]"
          opts.on("-n", "--dry-run", "Refresh metadata in memory without saving or upgrading") { options[:dry_run] = true }
          opts.on("-f", "--force", "Re-fetch even an already-current cask (upgrade also passes --force to brew)") { options[:force] = true }
          opts.on("-g", "--greedy", "Also include auto_updates casks") { options[:greedy] = true }
          forward_brew_flags(opts, options[:passthrough])
        end
        parser.parse!(args)
        options[:targets] = args.dup
        options
      end

      def parse_outdated
        options = { all: false, greedy: false, targets: [] }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: brew ghcask outdated [cask-name|owner/repo ...] [options]"
          opts.on("--all", "Show every managed cask, not just installed ones behind the latest") { options[:all] = true }
          opts.on("-g", "--greedy", "Also include auto_updates casks") { options[:greedy] = true }
        end
        parser.parse!(@argv)
        options[:targets] = @argv.dup
        options
      end
    end
  end
end

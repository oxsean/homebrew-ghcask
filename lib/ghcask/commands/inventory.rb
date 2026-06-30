# frozen_string_literal: true

require "json"

require "ghcask/commands/base"

module Ghcask
  module Commands
    # Read/metadata commands: `list`, `info`, `search`, `pin`, `unpin`. Pinning is
    # implicit (a non-empty requested_version), so pin/unpin just toggle that field.
    class Inventory < Base
      def list
        guard do
          return usage("brew ghcask list [--json]") if help_flag?
          json = !@argv.delete("--json").nil?
          raise UsageError, "unknown argument: #{@argv.first}. Usage: brew ghcask list [--json]" unless @argv.empty?

          catalog = tap.registry.ensure_exists
          if json
            entries = []
            catalog.each { |name, entry| entries << list_entry_json(name, entry) }
            stdout.puts JSON.pretty_generate(entries)
          else
            catalog.each do |name, entry|
              source = entry.url? ? entry.cask : entry.repo
              stdout.puts "#{name}\t#{entry.version}\t#{source}"
            end
          end
          0
        end
      end

      def info
        guard do
          return usage("brew ghcask info <cask-name|owner/repo> [--json]") if help_flag?
          json = !@argv.delete("--json").nil?
          target = @argv.shift
          raise UsageError, "cask name or repository is required" if target.to_s.empty?
          raise UsageError, "unknown argument: #{@argv.first}" unless @argv.empty?

          catalog = tap.registry.ensure_exists
          name, entry = resolve_entry(catalog, target)
          if json
            stdout.puts JSON.pretty_generate(info_json(name, entry))
          else
            print_info(name, entry)
          end
          0
        end
      end

      def search
        guard do
          return usage("brew ghcask search QUERY") if help_flag?
          query = @argv.join(" ").strip
          raise UsageError, "search query is required. Usage: brew ghcask search QUERY" if query.empty?

          repos = github.search_repos(query)
          if repos.empty?
            stdout.puts "No repositories found for #{query.inspect}."
            next 0
          end

          repos.each do |repo|
            desc = repo.description.to_s.strip
            stdout.puts "#{repo.full_name}  ★#{repo.stars}#{desc.empty? ? "" : "  #{desc}"}"
          end
          stdout.puts "Install one with: brew ghcask install OWNER/REPO"
          0
        end
      end

      def pin
        toggle_pin("pin")
      end

      def unpin
        toggle_pin("unpin")
      end

      private

      def help_flag?
        @argv.include?("-h") || @argv.include?("--help")
      end

      def usage(text)
        stdout.puts "Usage: #{text}"
        0
      end

      def toggle_pin(command)
        guard do
          return usage("brew ghcask #{command} <cask-name|owner/repo>") if help_flag?
          target = @argv.shift
          raise UsageError, "cask name or repository is required" if target.to_s.empty?
          raise UsageError, "unknown option #{@argv.first}" unless @argv.empty?

          catalog = tap.registry.ensure_exists
          name, entry = resolve_entry(catalog, target)
          raise UsageError, "#{command} is only supported for GitHub casks. Direct URL casks are changed with `brew ghcask reinstall #{name} --url NEW_URL`." if entry.url?

          if command == "pin"
            entry.requested_version = entry.release_tag
          else
            entry.requested_version = nil
          end
          entry.updated_at = Ghcask.now
          tap.registry.save(catalog)

          if command == "pin"
            stdout.puts "Pinned #{name} to #{entry.release_tag}."
          else
            stdout.puts "Unpinned #{name}. It will follow #{entry.release_policy}."
          end
          0
        end
      end

      def print_info(name, entry)
        stdout.puts "Cask: #{name}"
        stdout.puts "Full cask: ghcask/local/#{name}"
        stdout.puts "Source type: #{entry.source_type}"
        if entry.url?
          stdout.puts "URL: #{entry.asset_url}"
        else
          stdout.puts "Repository URL: https://github.com/#{entry.repo}"
        end
        stdout.puts "Release policy: #{entry.release_policy}"
        stdout.puts "Pinned: #{entry.pinned? ? "yes (#{entry.requested_version})" : "no"}"
        stdout.puts "Version: #{entry.version}"
        stdout.puts "Updated: #{entry.updated_at}" if entry.updated_at
        stdout.puts "Asset URL: #{entry.asset_url}" unless entry.url?
        stdout.puts "sha256: #{entry.sha256}"
        if entry.pkg?
          stdout.puts "Package: #{entry.asset_name}"
          stdout.puts "Pkg id: #{entry.pkg_id}" if entry.pkg_id
        elsif entry.binary?
          stdout.puts "Binary: #{entry.binary}"
          stdout.puts "Command: #{entry.command}"
        else
          stdout.puts "App: #{entry.app}"
        end
        stdout.puts "Quarantine: #{entry.quarantine? ? "enabled" : "disabled"}"
        stdout.puts "Cask path: #{tap.cask_path(name)}"
        print_install_info(name)
      end

      def print_install_info(name)
        info = brew.info(name)
        unless info
          stdout.puts "Installed: unknown"
          return
        end

        if info.installed?
          stdout.puts "Installed: yes"
          stdout.puts "Installed version: #{info.installed_version}"
          info.app_paths.each { |path| stdout.puts "Installed path: #{path}" }
        else
          stdout.puts "Installed: no"
        end
      end

      def list_entry_json(name, entry)
        {
          "name" => name,
          "version" => entry.version,
          "source_type" => entry.source_type,
          "source" => entry.url? ? entry.asset_url : entry.repo,
          "release_policy" => entry.release_policy,
          "pinned" => entry.pinned?,
          "install_state" => entry.install_state
        }
      end

      def info_json(name, entry)
        info = brew.info(name)
        entry.to_h.merge(
          "full_token" => "ghcask/local/#{name}",
          "pinned" => entry.pinned?,
          "cask_path" => tap.cask_path(name),
          "installed" => info ? info.installed? : nil,
          "installed_version" => info&.installed_version
        )
      end
    end
  end
end

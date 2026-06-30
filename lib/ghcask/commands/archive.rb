# frozen_string_literal: true

require "fileutils"
require "json"
require "set"

require "ghcask/catalog"
require "ghcask/commands/base"
require "ghcask/registry"

module Ghcask
  module Commands
    # `dump`/`restore` of the `Brewghcask.json` backup, which carries the
    # registry (including the quarantine policy) plus each generated cask's source.
    # Dump applies the same stale-record filtering as cleanup.
    class Archive < Base
      DEFAULT_NAME = "Brewghcask.json"
      FORMAT_VERSION = 1

      def dump
        guard do
          options = parse_options
          path = options[:path]
          filtered = filtered_catalog(tap.registry.ensure_exists)

          if options[:dry_run]
            print_dump_plan(path, filtered)
            next 0
          end

          raise UsageError, "dump file already exists: #{path}. Re-run with --force to overwrite." if File.exist?(path) && !options[:force]

          payload = {
            "version" => FORMAT_VERSION,
            "registry" => filtered.to_h,
            "casks" => filtered.names.each_with_object({}) { |name, casks| casks[name] = File.read(tap.cask_path(name)) }
          }
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, JSON.pretty_generate(payload) + "\n")
          stdout.puts "Wrote #{path}"
          0
        end
      end

      def restore
        guard do
          options = parse_options
          path = options[:path]
          raise UsageError, "dump file does not exist: #{path}" unless File.exist?(path)

          payload = parse_dump_file(path)
          registry_data = payload.fetch("registry")
          casks = payload.fetch("casks")

          if options[:dry_run]
            print_restore_plan(path, registry_data, casks)
            stdout.puts "Would install restored casks that are not installed yet." if options[:install]
            next 0
          end

          conflicts = casks.keys.select { |name| tap.cask_exist?(name) }
          raise UsageError, "local casks already exist: #{conflicts.sort.join(", ")}. Re-run with --force to overwrite." unless options[:force] || conflicts.empty?

          tap.init
          casks.each { |name, content| File.write(tap.cask_path(name), content) }
          catalog = merged_catalog(registry_data)
          tap.registry.save(catalog)
          stdout.puts "Restored #{path}"
          install_restored(catalog, casks.keys) if options[:install]
          0
        end
      end

      private

      def install_restored(catalog, names)
        ordered = names.sort
        installed = brew.installed_versions(ordered)
        ordered.each do |name|
          entry = catalog[name]
          if installed.key?(name)
            stdout.puts "#{name}: already installed"
          else
            brew.install(name, quarantine: entry.quarantine?)
            apply_quarantine_policy(entry)
            stdout.puts "Installed #{name}."
          end
          entry.install_state = Entry::STATE_INSTALLED
          tap.registry.save(catalog)
        end
      end

      def filtered_catalog(catalog)
        local = tap.cask_names.to_set
        installed = brew.installed_casks
        entries = {}
        catalog.each do |name, entry|
          next unless local.include?(name)
          next if entry.uninstalled?
          next if !entry.generated? && installed && !installed.include?(name)

          entries[name] = entry
        end
        Catalog.new(entries)
      end

      def merged_catalog(registry_data)
        incoming = Catalog.from_h(registry_data)
        current = tap.registry.ensure_exists
        incoming.each do |name, entry|
          entry.install_state = Entry::STATE_GENERATED
          current[name] = entry
        end
        current
      end

      def parse_options
        options = { path: File.expand_path(DEFAULT_NAME), force: false, global: false, dry_run: false, install: false }
        file_given = false
        OptionParser.new do |opts|
          opts.banner = "Usage: brew ghcask dump|restore [options]"
          opts.on("--file PATH", "Use a custom Brewghcask.json path") do |value|
            file_given = true
            options[:path] = File.expand_path(value)
          end
          opts.on("--global", "Use ~/.homebrew/Brewghcask.json") { options[:global] = true }
          opts.on("-f", "--force", "Overwrite an existing dump file, or same-name casks on restore") { options[:force] = true }
          opts.on("-n", "--dry-run", "Preview without writing files") { options[:dry_run] = true }
          opts.on("--install", "(restore) Also install restored casks that aren't installed yet") { options[:install] = true }
        end.parse!(@argv)
        raise UsageError, "unknown argument #{@argv.first}" unless @argv.empty?
        raise UsageError, "--file and --global cannot be used together" if options[:global] && file_given

        options[:path] = File.join(Dir.home, ".homebrew", DEFAULT_NAME) if options[:global]
        options
      end

      def parse_dump_file(path)
        payload = JSON.parse(File.read(path))
        validate_payload!(payload)
        payload
      rescue JSON::ParserError => e
        raise UsageError, "dump file is not valid JSON: #{e.message}"
      end

      def validate_payload!(payload)
        raise UsageError, "dump file must be a JSON object" unless payload.is_a?(Hash)
        raise UsageError, "unsupported dump file version: #{payload["version"].inspect}" unless payload["version"] == FORMAT_VERSION

        registry = payload["registry"]
        casks = payload["casks"]
        raise UsageError, "dump registry must be a JSON object" unless registry.is_a?(Hash)
        raise UsageError, "unsupported registry version: #{registry["version"].inspect}" unless registry["version"] == Registry::VERSION
        raise UsageError, "dump registry casks must be a JSON object" unless registry["casks"].is_a?(Hash)
        raise UsageError, "dump file casks must be a JSON object" unless casks.is_a?(Hash)

        missing = registry["casks"].keys.find { |name| !casks.key?(name) }
        raise UsageError, "dump file is missing cask content for registry entry: #{missing}" if missing

        extra = casks.keys.find { |name| !registry["casks"].key?(name) }
        raise UsageError, "dump file has cask content without registry entry: #{extra}" if extra

        casks.each do |name, content|
          raise UsageError, "invalid cask name in dump file: #{name}" unless name.match?(%r{\A[^/\s]+(?:-[^/\s]+)*\z})
          raise UsageError, "cask content must be a string: #{name}" unless content.is_a?(String)
        end
      end

      def print_dump_plan(path, catalog)
        stdout.puts "Would write #{path}"
        stdout.puts "Registry entries to export: #{catalog.names.length}"
        stdout.puts "Casks to export: #{catalog.names.length}"
      end

      def print_restore_plan(path, registry_data, casks)
        conflicts = casks.keys.select { |name| tap.cask_exist?(name) }
        incoming = registry_data.fetch("casks").keys
        current = tap.registry.load_if_exists
        merged = current ? (current.names | incoming).length : incoming.length

        stdout.puts "Would restore #{path}"
        stdout.puts "Casks in dump: #{casks.length}"
        stdout.puts "Registry entries in dump: #{incoming.length}"
        stdout.puts "Would overwrite casks: #{conflicts.empty? ? "none" : conflicts.sort.join(", ")}"
        stdout.puts "Registry entries after merge: #{merged}"
      end
    end
  end
end

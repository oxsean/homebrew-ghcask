# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"
require "set"

require "ghcask/installer"
require "ghcask/local_tap"

module Ghcask
  class Archive
    DEFAULT_NAME = "Brewghcask.json"
    FORMAT_VERSION = 1

    class Error < StandardError; end

    def initialize(argv, stdout:, stderr:, tap: LocalTap.new, runner: CommandRunner.new)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @tap = tap
      @runner = runner
    end

    def dump
      options = parse_options(default_path: File.expand_path(DEFAULT_NAME))
      path = options.fetch(:path)
      filtered = filtered_registry(@tap.registry.ensure_exists)
      if options[:dry_run]
        print_dump_plan(path, filtered)
        return 0
      end

      raise Error, "dump file already exists: #{path}. Re-run with --force to overwrite." if File.exist?(path) && !options[:force]

      payload = {
        "version" => FORMAT_VERSION,
        "registry" => filtered,
        "casks" => filtered.fetch("casks").each_key.each_with_object({}) do |name, casks|
          casks[name] = File.read(cask_path(name))
        end
      }

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(payload) + "\n")
      @stdout.puts "Wrote #{path}"
      0
    rescue OptionParser::ParseError, Error, Registry::Error, Homebrew::Error => e
      @stderr.puts "ghcask dump: #{e.message}"
      1
    end

    def restore
      options = parse_options(default_path: File.expand_path(DEFAULT_NAME))
      path = options.fetch(:path)
      raise Error, "dump file does not exist: #{path}" unless File.exist?(path)

      payload = parse_dump_file(path)
      registry = payload.fetch("registry")
      casks = payload.fetch("casks")
      if options[:dry_run]
        print_restore_plan(path, registry, casks)
        return 0
      end
      if !options[:force] && restore_conflicts?(casks)
        raise Error, "local ghcask data already exists. Re-run with --force to replace it."
      end

      @tap.init
      FileUtils.mkdir_p(@tap.casks_dir)
      casks.each do |name, content|
        File.write(cask_path(name), content)
      end
      @tap.registry.save(merged_registry(registry))

      @stdout.puts "Restored #{path}"
      0
    rescue OptionParser::ParseError, Error, Registry::Error, Homebrew::Error => e
      @stderr.puts "ghcask restore: #{e.message}"
      1
    end

    private

    def parse_options(default_path:)
      options = { path: default_path, force: false, global: false, dry_run: false }
      file_given = false
      parser = OptionParser.new do |opts|
        opts.on("--file PATH") do |value|
          file_given = true
          options[:path] = File.expand_path(value)
        end
        opts.on("--global") { options[:global] = true }
        opts.on("--force") { options[:force] = true }
        opts.on("--dry-run") { options[:dry_run] = true }
      end
      parser.parse!(@argv)
      raise Error, "unknown argument #{@argv.first}" unless @argv.empty?
      raise Error, "--file and --global cannot be used together" if options[:global] && file_given

      options[:path] = global_archive_path if options[:global]
      options
    end

    def global_archive_path
      File.join(Dir.home, ".homebrew", DEFAULT_NAME)
    end

    def filtered_registry(data)
      local_casks = local_cask_names
      installed_casks = installed_homebrew_casks
      casks = data.fetch("casks").each_with_object({}) do |(name, entry), filtered|
        next unless local_casks.include?(name)
        next if entry["install_state"] != "generated" && installed_casks && !installed_casks.include?(name)

        filtered[name] = entry
      end
      data.merge("casks" => casks)
    end

    def local_cask_names
      Dir.glob(File.join(@tap.casks_dir, "*.rb")).map { |path| File.basename(path, ".rb") }.to_set
    end

    def installed_homebrew_casks
      result = @runner.capture(["brew", "list", "--cask"])
      return nil unless result.success?

      result.stdout.lines.map(&:strip).reject(&:empty?).to_set
    end

    def print_dump_plan(path, registry)
      names = registry.fetch("casks").keys
      @stdout.puts "Would write #{path}"
      @stdout.puts "Registry entries to export: #{names.length}"
      @stdout.puts "Casks to export: #{names.length}"
    end

    def parse_dump_file(path)
      payload = JSON.parse(File.read(path))
      validate_payload!(payload)
      payload
    rescue JSON::ParserError => e
      raise Error, "dump file is not valid JSON: #{e.message}"
    end

    def validate_payload!(payload)
      raise Error, "dump file must be a JSON object" unless payload.is_a?(Hash)
      raise Error, "unsupported dump file version: #{payload["version"].inspect}" unless payload["version"] == FORMAT_VERSION

      registry = payload["registry"]
      casks = payload["casks"]
      validate_registry!(registry)
      raise Error, "dump file casks must be a JSON object" unless casks.is_a?(Hash)

      missing = registry.fetch("casks").keys.find { |name| !casks.key?(name) }
      raise Error, "dump file is missing cask content for registry entry: #{missing}" if missing

      extra = casks.keys.find { |name| !registry.fetch("casks").key?(name) }
      raise Error, "dump file has cask content without registry entry: #{extra}" if extra

      casks.each do |name, content|
        raise Error, "invalid cask name in dump file: #{name}" unless name.match?(%r{\A[^/\s]+(?:-[^/\s]+)*\z})
        raise Error, "cask content must be a string: #{name}" unless content.is_a?(String)
      end
    end

    def validate_registry!(data)
      raise Error, "dump registry must be a JSON object" unless data.is_a?(Hash)
      raise Error, "unsupported registry version: #{data["version"].inspect}" unless data["version"] == Registry::VERSION
      raise Error, "dump registry casks must be a JSON object" unless data["casks"].is_a?(Hash)
    end

    def restore_conflicts?(casks)
      casks.keys.any? { |name| File.exist?(cask_path(name)) }
    end

    def restore_conflict_names(casks)
      casks.keys.select { |name| File.exist?(cask_path(name)) }
    end

    def print_restore_plan(path, registry, casks)
      conflicts = restore_conflict_names(casks)
      current = @tap.registry.load
      incoming_names = registry.fetch("casks").keys
      merged_names = current.fetch("casks").keys | incoming_names

      @stdout.puts "Would restore #{path}"
      @stdout.puts "Casks in dump: #{casks.length}"
      @stdout.puts "Registry entries in dump: #{incoming_names.length}"
      @stdout.puts "Would overwrite casks: #{conflicts.empty? ? "none" : conflicts.sort.join(", ")}"
      @stdout.puts "Registry entries after merge: #{merged_names.length}"
    rescue Registry::Error
      @stdout.puts "Would restore #{path}"
      @stdout.puts "Casks in dump: #{casks.length}"
      @stdout.puts "Registry entries in dump: #{registry.fetch("casks").length}"
      @stdout.puts "Would overwrite casks: #{conflicts.empty? ? "none" : conflicts.sort.join(", ")}"
      @stdout.puts "Registry entries after merge: unknown"
    end

    def merged_registry(incoming)
      current = @tap.registry.ensure_exists
      merged = current.merge("casks" => current.fetch("casks").merge(incoming.fetch("casks")))
      merged["version"] = Registry::VERSION
      merged
    end

    def cask_path(name)
      File.join(@tap.casks_dir, "#{name}.rb")
    end
  end
end

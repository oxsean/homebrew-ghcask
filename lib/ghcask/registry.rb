# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"

require "ghcask/catalog"
require "ghcask/errors"

module Ghcask
  # Atomic JSON persistence for the catalog. Reads/writes a versioned
  # `{ "version", "casks" => { name => entry } }` document; all in-memory work
  # happens on a Catalog.
  class Registry
    VERSION = 1

    attr_reader :path

    def initialize(path)
      @path = path
    end

    def init
      save(Catalog.new) unless File.exist?(path)
      self
    end

    def ensure_exists
      return load if File.exist?(path)

      save(Catalog.new)
    end

    def load_if_exists
      File.exist?(path) ? load : nil
    end

    def load
      raw = JSON.parse(File.read(path))
      validate!(raw)
      Catalog.from_h(raw)
    rescue JSON::ParserError => e
      raise CorruptRegistryError, "registry is not valid JSON: #{e.message}"
    rescue Errno::ENOENT
      raise RegistryError, "registry does not exist: #{path}"
    end

    def save(catalog)
      FileUtils.mkdir_p(File.dirname(path))
      atomic_write(JSON.pretty_generate(catalog.to_h) + "\n")
      catalog
    end

    private

    def validate!(data)
      raise CorruptRegistryError, "registry must be a JSON object" unless data.is_a?(Hash)
      raise CorruptRegistryError, "unsupported registry version: #{data["version"].inspect}" unless data["version"] == VERSION
      raise CorruptRegistryError, "registry casks must be a JSON object" unless data["casks"].is_a?(Hash)
    end

    def atomic_write(contents)
      dir = File.dirname(path)
      tmp = File.join(dir, ".#{File.basename(path)}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp")

      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
        file.write(contents)
        file.flush
        file.fsync
      end

      File.rename(tmp, path)
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end
  end
end

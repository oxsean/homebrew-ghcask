# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"

module Ghcask
  class Registry
    VERSION = 1
    EMPTY = {
      "version" => VERSION,
      "casks" => {}
    }.freeze

    class Error < StandardError; end
    class CorruptError < Error; end

    attr_reader :path

    def initialize(path)
      @path = path
    end

    def ensure_exists
      return load if File.exist?(path)

      save(EMPTY)
    end

    def load
      data = JSON.parse(File.read(path))
      validate!(data)
      data
    rescue JSON::ParserError => e
      raise CorruptError, "registry is not valid JSON: #{e.message}"
    rescue Errno::ENOENT
      raise Error, "registry does not exist: #{path}"
    end

    def save(data)
      FileUtils.mkdir_p(File.dirname(path))
      atomic_write(JSON.pretty_generate(data) + "\n")
      data
    end

    private

    def validate!(data)
      unless data.is_a?(Hash)
        raise CorruptError, "registry must be a JSON object"
      end

      unless data["version"] == VERSION
        raise CorruptError, "unsupported registry version: #{data["version"].inspect}"
      end

      unless data["casks"].is_a?(Hash)
        raise CorruptError, "registry casks must be a JSON object"
      end
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

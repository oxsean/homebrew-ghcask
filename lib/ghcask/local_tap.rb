# frozen_string_literal: true

require "fileutils"

require "ghcask/homebrew"
require "ghcask/registry"

module Ghcask
  class LocalTap
    attr_reader :homebrew_repository

    def initialize(homebrew_repository: Homebrew.repository)
      @homebrew_repository = homebrew_repository
    end

    def init
      FileUtils.mkdir_p(casks_dir)
      registry.ensure_exists
      self
    end

    def root
      File.join(homebrew_repository, "Library", "Taps", "ghcask", "homebrew-local")
    end

    def casks_dir
      File.join(root, "Casks")
    end

    def registry_path
      File.join(root, "ghcask.json")
    end

    def registry
      @registry ||= Registry.new(registry_path)
    end
  end
end

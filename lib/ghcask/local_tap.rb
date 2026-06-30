# frozen_string_literal: true

require "fileutils"

require "ghcask/homebrew"
require "ghcask/registry"

module Ghcask
  # The generated tap (`$(brew --repository)/Library/Taps/ghcask/homebrew-local/`)
  # holding `Casks/*.rb` + `ghcask.json` — so the distribution tap stays clean.
  class LocalTap
    def initialize(homebrew_repository: Homebrew.repository)
      @homebrew_repository = homebrew_repository
    end

    def init
      FileUtils.mkdir_p(casks_dir)
      registry.init
      self
    end

    def root
      File.join(@homebrew_repository, "Library", "Taps", "ghcask", "homebrew-local")
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

    def cask_path(name)
      File.join(casks_dir, "#{name}.rb")
    end

    def cask_exist?(name)
      File.exist?(cask_path(name))
    end

    def cask_names
      Dir.glob(File.join(casks_dir, "*.rb")).map { |path| File.basename(path, ".rb") }
    end
  end
end

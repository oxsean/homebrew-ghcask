# frozen_string_literal: true

require "fileutils"

module Ghcask
  module Cask
    module_function

    def normalize_name(value)
      value.to_s
           .sub(/\.app\z/i, "")
           .downcase
           .gsub(/[\s_]+/, "-")
           .gsub(/[^a-z0-9-]/, "")
           .gsub(/-+/, "-")
           .gsub(/\A-|-+\z/, "")
    end

    def render(entry)
      return render_url(entry) if entry["source_type"] == "url"

      <<~RUBY
        cask #{field(entry, "cask")} do
          version #{field(entry, "version")}
          sha256 #{field(entry, "sha256")}

          url #{field(entry, "asset_url")}
          name #{field(entry, "name")}
          desc "Generated from GitHub Releases"
          homepage #{"https://github.com/#{entry.fetch("repo")}".dump}

          app #{field(entry, "app")}
        end
      RUBY
    end

    def render_url(entry)
      <<~RUBY
        cask #{field(entry, "cask")} do
          version #{field(entry, "version")}
          sha256 #{field(entry, "sha256")}

          url #{field(entry, "asset_url")}
          name #{field(entry, "name")}
          desc "Generated from a direct package URL"
          homepage #{field(entry, "homepage")}

          app #{field(entry, "app")}
        end
      RUBY
    end

    def field(entry, key)
      entry.fetch(key).to_s.dump
    end

    def write(path, entry)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, render(entry))
      yield if block_given?
    end
  end
end

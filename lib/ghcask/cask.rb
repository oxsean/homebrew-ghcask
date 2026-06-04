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
        cask "#{entry.fetch("cask")}" do
          version "#{entry.fetch("version")}"
          sha256 "#{entry.fetch("sha256")}"

          url "#{entry.fetch("asset_url")}"
          name "#{entry.fetch("name")}"
          desc "Generated from GitHub Releases"
          homepage "https://github.com/#{entry.fetch("repo")}"

          app "#{entry.fetch("app")}"
        end
      RUBY
    end

    def render_url(entry)
      <<~RUBY
        cask "#{entry.fetch("cask")}" do
          version "#{entry.fetch("version")}"
          sha256 "#{entry.fetch("sha256")}"

          url "#{entry.fetch("asset_url")}"
          name "#{entry.fetch("name")}"
          desc "Generated from a direct package URL"
          homepage "#{entry.fetch("homepage")}"

          app "#{entry.fetch("app")}"
        end
      RUBY
    end

    def write(path, entry)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, render(entry))
      yield if block_given?
    end
  end
end

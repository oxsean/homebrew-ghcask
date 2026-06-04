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

    def ruby_string_literal(value)
      value.to_s.dump
    end

    def render(entry)
      return render_url(entry) if entry["source_type"] == "url"

      <<~RUBY
        cask #{ruby_string_literal(entry.fetch("cask"))} do
          version #{ruby_string_literal(entry.fetch("version"))}
          sha256 #{ruby_string_literal(entry.fetch("sha256"))}

          url #{ruby_string_literal(entry.fetch("asset_url"))}
          name #{ruby_string_literal(entry.fetch("name"))}
          desc "Generated from GitHub Releases"
          homepage #{ruby_string_literal("https://github.com/" + entry.fetch("repo"))}

          app #{ruby_string_literal(entry.fetch("app"))}
        end
      RUBY
    end

    def render_url(entry)
      <<~RUBY
        cask #{ruby_string_literal(entry.fetch("cask"))} do
          version #{ruby_string_literal(entry.fetch("version"))}
          sha256 #{ruby_string_literal(entry.fetch("sha256"))}

          url #{ruby_string_literal(entry.fetch("asset_url"))}
          name #{ruby_string_literal(entry.fetch("name"))}
          desc "Generated from a direct package URL"
          homepage #{ruby_string_literal(entry.fetch("homepage"))}

          app #{ruby_string_literal(entry.fetch("app"))}
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

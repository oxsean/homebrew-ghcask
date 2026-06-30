# frozen_string_literal: true

require "fileutils"

module Ghcask
  # Renders an Entry into a Homebrew cask file and owns the canonical cask-naming rule.
  module CaskFile
    ZAP_PATHS = [
      "~/Library/Application Support/%s",
      "~/Library/Caches/%s",
      "~/Library/HTTPStorages/%s",
      "~/Library/Preferences/%s.plist",
      "~/Library/Saved Application State/%s.savedState",
      "~/Library/Logs/%s",
      "~/Library/Containers/%s",
      "~/Library/WebKit/%s"
    ].freeze

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
      <<~RUBY
        cask #{quote(entry.cask)} do
          version #{quote(entry.version)}
          sha256 #{quote(entry.sha256)}

          url #{quote(entry.asset_url)}
          name #{quote(entry.name)}
          desc #{quote(description(entry))}
          homepage #{quote(entry.homepage)}

          #{auto_updates_stanza(entry)}#{artifact_stanza(entry)}#{zap_stanza(entry)}
        end
      RUBY
    end

    def artifact_stanza(entry)
      return pkg_stanza(entry) if entry.pkg?
      return binary_stanza(entry) if entry.binary?

      "app #{quote(entry.app)}"
    end

    def auto_updates_stanza(entry)
      entry.auto_updates? ? "auto_updates true\n\n  " : ""
    end

    def zap_stanza(entry)
      return "" unless entry.app && valid_bundle_id?(entry.bundle_id)

      id = entry.bundle_id
      paths = ZAP_PATHS.map { |template| "        #{quote(format(template, id))}," }.join("\n")
      "\n\n  zap quit:  #{quote(id)},\n      trash: [\n#{paths}\n      ]"
    end

    def valid_bundle_id?(id)
      id.to_s.match?(/\A[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+\z/)
    end

    def pkg_stanza(entry)
      stanza = "pkg #{quote(entry.asset_name)}"
      stanza += "\n  uninstall pkgutil: #{quote(entry.pkg_id)}" if entry.pkg_id && !entry.pkg_id.to_s.empty?
      stanza
    end

    EXTRA_STANZAS = { "manpage" => "manpage", "bash" => "bash_completion", "zsh" => "zsh_completion", "fish" => "fish_completion" }.freeze

    def binary_stanza(entry)
      source = entry.binary.to_s
      target = entry.command.to_s
      stanza = "binary #{quote(source)}"
      stanza += ", target: #{quote(target)}" unless target.empty? || target == File.basename(source)
      extras = entry.extras || {}
      EXTRA_STANZAS.each do |key, name|
        path = extras[key]
        stanza += "\n  #{name} #{quote(path)}" if path && !path.to_s.empty?
      end
      stanza
    end

    def write(path, entry)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, render(entry))
      yield if block_given?
    end

    def description(entry)
      desc = entry.desc.to_s.strip
      return desc unless desc.empty?

      entry.url? ? "Generated from a direct package URL" : "Generated from GitHub Releases"
    end

    def quote(value)
      value.to_s.dump
    end
  end
end

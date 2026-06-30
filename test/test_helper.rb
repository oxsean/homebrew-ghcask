# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "fileutils"
require "json"

require_relative "support/fakes"

module GhcaskTest
  # Base test case: a throwaway Homebrew repo under a tmpdir, captured IO streams,
  # and builders for releases / entries / a seeded tap.
  class Case < Minitest::Test
    include Ghcask

    def setup
      @tmp = Dir.mktmpdir("ghcask-test-")
      @out = StringIO.new
      @err = StringIO.new
    end

    def teardown
      FileUtils.remove_entry(@tmp) if @tmp && File.directory?(@tmp)
    end

    def tap
      @tap ||= Ghcask::LocalTap.new(homebrew_repository: @tmp)
    end

    def stdout
      @out.string
    end

    def stderr
      @err.string
    end

    def io
      { stdout: @out, stderr: @err }
    end

    def asset(name, url = "https://example.com/#{name}")
      Ghcask::Asset.new(name: name, url: url)
    end

    def release(tag:, assets: ["Example-arm64.dmg"], prerelease: false, draft: false, name: nil, published_at: nil)
      Ghcask::Release.new(
        tag_name: tag, name: name, draft: draft, prerelease: prerelease,
        published_at: published_at,
        assets: assets.map { |a| a.is_a?(Array) ? asset(*a) : asset(a) }
      )
    end

    def entry(overrides = {})
      base = {
        "repo" => "acme/app", "source_type" => "github", "cask" => "app", "name" => "App",
        "app" => "App.app", "release_policy" => "latest-stable", "requested_version" => nil,
        "asset_pattern" => nil, "arch" => "arm64", "version" => "1.0.0", "release_tag" => "v1.0.0",
        "asset_name" => "App-arm64.dmg", "asset_url" => "https://example.com/app.dmg",
        "homepage" => "https://github.com/acme/app", "sha256" => "deadbeef",
        "quarantine" => true, "install_state" => "installed", "updated_at" => "2024-01-01T00:00:00Z"
      }
      Ghcask::Entry.new(base.merge(stringify(overrides)))
    end

    def url_entry(overrides = {})
      entry({
        "repo" => nil, "source_type" => "url", "cask" => "directapp", "release_policy" => "url",
        "release_tag" => nil, "asset_url" => "https://example.com/Direct-1.2.0.dmg",
        "homepage" => "https://example.com"
      }.merge(stringify(overrides)))
    end

    # Write an entry into the tap (registry + cask file) so it looks installed.
    def seed(*entries)
      tap.init
      catalog = tap.registry.ensure_exists
      entries.each do |e|
        catalog[e.cask] = e
        File.write(tap.cask_path(e.cask), Ghcask::CaskFile.render(e))
      end
      tap.registry.save(catalog)
      entries.length == 1 ? entries.first : entries
    end

    def catalog
      tap.registry.load
    end

    def stringify(hash)
      hash.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
    end
  end
end

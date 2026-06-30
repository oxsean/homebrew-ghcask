# frozen_string_literal: true

require "time"

require "ghcask/asset_selector"
require "ghcask/cask_file"
require "ghcask/direct_url"
require "ghcask/entry"
require "ghcask/errors"
require "ghcask/release"
require "ghcask/repo_ref"

module Ghcask
  Resolution = Struct.new(:asset, :release, :repo_description, keyword_init: true)

  # Turns a CLI target (or existing Entry) into a downloadable asset, then an Entry.
  # GithubSource and UrlSource share this interface so the pipeline branches on neither
  # `source_type` nor `--url`.
  class Source
    def initialize(existing: nil, install: true, quarantine: nil, app_override: nil, name_override: nil, arch_override: nil, command_override: nil)
      @existing = existing
      @install = install
      @quarantine = quarantine
      @app_override = app_override
      @name_override = name_override
      @arch_override = arch_override
      @command_override = command_override
    end

    def previewable_without_download?
      false
    end

    def unchanged_entry(_resolution)
      nil
    end

    def app_override_for_inference
      @app_override || @existing&.app
    end

    protected

    def quarantine_value
      return @quarantine unless @quarantine.nil?
      return @existing.quarantine? if @existing

      true
    end

    def install_state
      return @existing.install_state if @existing

      @install ? Entry::STATE_PENDING : Entry::STATE_GENERATED
    end

    def display_name(app_meta, fallback)
      @name_override || app_meta&.name || @existing&.name || fallback
    end

    def app_name(app_meta)
      (app_meta && app_meta.app) || @existing&.app
    end

    def binary_command(app_meta, cask)
      return nil unless app_meta&.binary

      @command_override || app_meta.command || cask
    end
  end

  class GithubSource < Source
    attr_reader :repo, :release_policy, :requested_version, :asset_pattern

    def initialize(repo:, release_policy:, requested_version: nil, asset_pattern: nil, cask_override: nil, force: false, **rest)
      super(**rest)
      @repo = repo
      @release_policy = release_policy
      @requested_version = requested_version
      @asset_pattern = asset_pattern
      @cask_override = cask_override
      @force = force
    end

    def previewable_without_download?
      true
    end

    def arch
      @arch_override || @existing&.arch || AssetSelector.local_arch
    end

    def unchanged_entry(resolution)
      return nil unless @existing
      return nil unless resolution.release&.tag_name == @existing.release_tag && resolution.asset&.name == @existing.asset_name

      @existing
    end

    def resolve(github, fetch_description: true)
      release = github.select_release(@repo, policy: @release_policy, requested_version: @requested_version)
      asset = AssetSelector.new(release.assets, arch: arch).select(pattern: @asset_pattern)
      description = @force ? nil : @existing&.desc
      description = Ghcask.concise_desc(github.repo_description(@repo)) if fetch_description && description.to_s.empty?
      Resolution.new(asset: asset, release: release, repo_description: description)
    end

    def download(resolution, github:, package:, destination_dir:, stdout: nil)
      github.download(
        repo: @repo, tag: resolution.release.tag_name, asset: resolution.asset,
        destination_dir: destination_dir, stdout: stdout
      )
    end

    def build_entry(resolution, sha:, app_meta:)
      release = resolution.release
      asset = resolution.asset
      cask = cask_name(app_meta)
      Entry.new(
        "repo" => @repo,
        "source_type" => Entry::GITHUB,
        "cask" => cask,
        "name" => display_name(app_meta, release.name || cask),
        "desc" => resolution.repo_description,
        "app" => app_name(app_meta),
        "pkg_id" => app_meta&.pkg_id,
        "binary" => app_meta&.binary,
        "command" => binary_command(app_meta, cask),
        "bundle_id" => app_meta&.bundle_id,
        "auto_updates" => app_meta&.auto_updates,
        "extras" => app_meta&.extras,
        "release_policy" => @release_policy,
        "requested_version" => @requested_version,
        "asset_pattern" => @asset_pattern,
        "arch" => arch,
        "version" => Ghcask.strip_v(release.tag_name),
        "release_tag" => release.tag_name,
        "asset_name" => asset.name,
        "asset_url" => asset.url,
        "homepage" => "https://github.com/#{@repo}",
        "sha256" => sha,
        "quarantine" => quarantine_value,
        "install_state" => install_state,
        "updated_at" => Ghcask.now
      )
    end

    def preview_entry(resolution)
      release = resolution.release
      asset = resolution.asset
      placeholder = "(will calculate during #{@existing ? "reinstall" : "install"})"
      refreshed = {
        "desc" => resolution.repo_description,
        "release_policy" => @release_policy,
        "requested_version" => @requested_version,
        "arch" => arch,
        "version" => Ghcask.strip_v(release.tag_name),
        "release_tag" => release.tag_name,
        "asset_name" => asset.name,
        "asset_url" => asset.url,
        "quarantine" => quarantine_value,
        "sha256" => placeholder
      }
      return @existing.merge(refreshed) if @existing

      cask = CaskFile.normalize_name(@cask_override || @repo.split("/").last)
      Entry.new(refreshed.merge(
        "repo" => @repo,
        "source_type" => Entry::GITHUB,
        "cask" => cask,
        "name" => @name_override || release.name || cask,
        "app" => @app_override || "(will infer during install)",
        "asset_pattern" => @asset_pattern,
        "homepage" => "https://github.com/#{@repo}",
        "install_state" => install_state
      ))
    end

    private

    def cask_name(app_meta)
      return @existing.cask if @existing

      name = CaskFile.normalize_name(@cask_override || (app_meta && app_meta.app) || @repo.split("/").last)
      raise UsageError, "Could not infer cask name. Re-run with --cask CASK." if name.empty?

      name
    end
  end

  class UrlSource < Source
    attr_reader :cask_name, :url

    def initialize(cask_name:, url:, version_override: nil, **rest)
      super(**rest)
      @cask_name = cask_name
      @url = url
      @version_override = version_override
    end

    def previewable_without_download?
      true
    end

    def resolve(_github = nil, fetch_description: true)
      Resolution.new(asset: Asset.new(name: DirectUrl.asset_name(@url), url: @url), release: nil)
    end

    def unchanged_entry(resolution)
      @existing if @existing && resolution.asset&.url == @existing.asset_url
    end

    def download(resolution, github:, package:, destination_dir:, stdout: nil)
      headers = github_auth_headers(github)
      package.download(resolution.asset, destination_dir: destination_dir, stdout: stdout, headers: headers)
    end

    def build_entry(resolution, sha:, app_meta:)
      asset = resolution.asset
      Entry.new(
        "repo" => nil,
        "source_type" => Entry::URL,
        "cask" => @cask_name,
        "name" => display_name(app_meta, CaskFile.normalize_name(@cask_name)),
        "app" => app_name(app_meta),
        "pkg_id" => app_meta&.pkg_id,
        "binary" => app_meta&.binary,
        "command" => binary_command(app_meta, @cask_name),
        "bundle_id" => app_meta&.bundle_id,
        "auto_updates" => app_meta&.auto_updates,
        "extras" => app_meta&.extras,
        "release_policy" => Entry::URL,
        "requested_version" => nil,
        "asset_pattern" => nil,
        "arch" => @arch_override || @existing&.arch,
        "version" => resolved_version(asset, app_meta),
        "release_tag" => nil,
        "asset_name" => asset.name,
        "asset_url" => asset.url,
        "homepage" => DirectUrl.homepage(asset.url),
        "sha256" => sha,
        "quarantine" => quarantine_value,
        "install_state" => install_state,
        "updated_at" => Ghcask.now
      )
    end

    def preview_entry(resolution)
      asset = resolution.asset
      Entry.new(
        "repo" => nil,
        "source_type" => Entry::URL,
        "cask" => @cask_name,
        "name" => display_name(nil, CaskFile.normalize_name(@cask_name)),
        "app" => @app_override || "(will infer during install)",
        "command" => @command_override,
        "release_policy" => Entry::URL,
        "requested_version" => nil,
        "asset_pattern" => nil,
        "arch" => @arch_override || @existing&.arch,
        "version" => resolved_version(asset, nil),
        "release_tag" => nil,
        "asset_name" => asset.name,
        "asset_url" => asset.url,
        "homepage" => DirectUrl.homepage(asset.url),
        "sha256" => "(will calculate during #{@existing ? "reinstall" : "install"})",
        "quarantine" => quarantine_value,
        "install_state" => install_state,
        "updated_at" => Ghcask.now
      )
    end

    private

    def resolved_version(asset, app_meta)
      @version_override ||
        (app_meta && app_meta.version) ||
        DirectUrl.version_from_filename(asset.name) ||
        @existing&.version ||
        "latest"
    end

    def github_auth_headers(github)
      return [] unless DirectUrl.github_host?(@url)

      token = github.auth_token
      token ? ["Authorization: Bearer #{token}"] : []
    end
  end
end

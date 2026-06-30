# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "set"

require "ghcask/command_runner"
require "ghcask/errors"

module Ghcask
  # Everything that touches `brew` lives here so command building, output
  # streaming, error summarization, JSON parsing, and the cache move are written
  # once. Generated casks are addressed as `ghcask/local/<name>`.
  module Homebrew
    class CaskInfo
      def initialize(data)
        @data = data
      end

      def installed_version
        value = @data["installed"]
        value = value.last if value.is_a?(Array)
        value = value.to_s
        value.empty? ? nil : value
      end

      def installed?
        !installed_version.nil?
      end

      def app_paths
        Array(@data["artifacts"]).flat_map { |artifact| targets(artifact) }
      end

      private

      def targets(artifact)
        return [] unless artifact.is_a?(Hash)

        nested = artifact.values.map do |value|
          if value.is_a?(Hash)
            value["target"]
          elsif value.is_a?(Array) && value.last.is_a?(Hash)
            value.last["target"]
          end
        end
        [artifact["target"], *nested].compact
      end
    end

    # Stateful wrapper around the `brew` CLI bound to a runner + output streams.
    class Brew
      TOKEN_PREFIX = "ghcask/local"

      def initialize(runner: CommandRunner.new, stdout: $stdout, stderr: $stderr)
        @runner = runner
        @stdout = stdout
        @stderr = stderr
      end

      def token(name)
        "#{TOKEN_PREFIX}/#{name}"
      end

      def install(name, force: false, quarantine: true, extra: [])
        run(action_command(name, "install", force: force, quarantine: quarantine, extra: extra), action: "install", name: name, hint: true)
      end

      def reinstall(name, force: false, quarantine: true, extra: [])
        run(action_command(name, "reinstall", force: force, quarantine: quarantine, extra: extra), action: "reinstall", name: name, hint: true)
      end

      def upgrade(name, force: false, extra: [])
        command = ["brew", "upgrade", "--cask"]
        command << "--force" if force
        command.concat(extra)
        command << token(name)
        run(command, action: "upgrade", name: name)
      end

      def uninstall(name, force: false, zap: false, extra: [])
        command = ["brew", "uninstall", "--cask"]
        command << "--zap" if zap
        command << "--force" if force
        command.concat(extra)
        command << token(name)
        run(command, action: "uninstall", name: name, allow_missing: true)
      end

      def trust(name)
        run(["brew", "trust", "--cask", token(name)], action: "trust", name: name)
      end

      def plan(name, action:, force: false, quarantine: true, extra: [])
        action_command(name, action.to_s, force: force, quarantine: quarantine, extra: extra)
      end

      def cache_package(name, asset_path)
        path = cache_path(name)
        return nil unless path

        FileUtils.mkdir_p(File.dirname(path))
        FileUtils.rm_f(path)
        FileUtils.mv(asset_path, path)
        @stdout.puts "==> Caching download for Homebrew: #{path}"
        path
      rescue StandardError => e
        @stderr.puts "Warning: Could not cache package for Homebrew. Homebrew may download again. #{e.message}"
        nil
      end

      def cached_download_for_url(url)
        root = cache_root
        return nil if root.nil? || url.to_s.empty?

        prefix = Digest::SHA256.hexdigest(url)
        Dir.glob(File.join(root, "downloads", "#{prefix}--*")).find { |path| File.file?(path) }
      end

      def info(name)
        result = @runner.capture(["brew", "info", "--cask", "--json=v2", token(name)])
        return nil unless result.success?

        cask = JSON.parse(result.stdout).fetch("casks", []).first
        cask && CaskInfo.new(cask)
      rescue JSON::ParserError, KeyError
        nil
      end

      def installed_app_paths(name)
        info(name)&.app_paths || []
      end

      def installed_versions(names)
        return {} if names.empty?

        tokens = names.map { |name| token(name) }
        result = @runner.capture(["brew", "info", "--cask", "--json=v2", *tokens])
        return versions_from(result.stdout, names) if result.success?

        names.each_with_object({}) do |name, versions|
          version = info(name)&.installed_version
          versions[name] = version if version
        end
      end

      def versions_from(stdout, names)
        JSON.parse(stdout).fetch("casks", []).each_with_object({}) do |cask, versions|
          cask_tokens = [cask["full_token"], cask["token"]].compact.map(&:to_s)
          name = names.find { |candidate| cask_tokens.any? { |token| token == candidate || token.end_with?("/#{candidate}") } }
          version = CaskInfo.new(cask).installed_version
          versions[name] = version if name && version
        end
      rescue JSON::ParserError, KeyError
        {}
      end

      def installed_casks
        result = @runner.capture(%w[brew list --cask])
        return nil unless result.success?

        result.stdout.lines.map(&:strip).reject(&:empty?).to_set
      end

      private

      def action_command(name, action, force:, quarantine:, extra: [])
        command = ["brew", action, "--cask"]
        command << "--force" if force
        command << "--no-quarantine" unless quarantine
        command.concat(extra)
        command << token(name)
        command
      end

      def cache_root
        return @cache_root if defined?(@cache_root)

        result = @runner.capture(["brew", "--cache"])
        @cache_root = result.success? ? result.stdout.strip : nil
      end

      def cache_path(name)
        result = @runner.capture(["brew", "--cache", "--cask", token(name)])
        return result.stdout.lines.map(&:strip).reject(&:empty?).last if result.success?

        @stderr.puts "Warning: Could not determine Homebrew cache path. Homebrew may download again. #{summarize(result)}"
        nil
      end

      def run(command, action:, name:, allow_missing: false, hint: false)
        @stdout.puts "==> #{command.join(" ")}"
        result = @runner.capture(command)
        @stdout.print result.stdout unless result.stdout.empty?
        @stderr.print result.stderr unless result.stderr.empty?
        return :ok if result.success?

        message = summarize(result)
        if allow_missing && not_installed?(message)
          @stderr.puts "Warning: #{message}. Marking the ghcask registry entry as uninstalled anyway."
          return :missing
        end

        detail = hint ? " Inspect with `brew cat --cask #{token(name)}`." : ""
        raise HomebrewError, "Homebrew #{action} failed: #{message}.#{detail}"
      end

      def summarize(result)
        text = result.stderr.strip.empty? ? result.stdout : result.stderr
        lines = text.lines.map(&:strip).reject(&:empty?)
        lines.find { |line| line.start_with?("Error:") } ||
          lines.reverse.find { |line| line.match?(/\berror:/i) } ||
          lines.last ||
          "command failed"
      end

      def not_installed?(message)
        message.match?(/not installed|not currently installed|no such cask/i)
      end
    end

    module_function

    def repository
      override = ENV["GHCASK_BREW_REPOSITORY"]
      return File.expand_path(override) if override && !override.empty?

      stdout, stderr, status = Open3.capture3("brew", "--repository")
      raise HomebrewError, (stderr.strip.empty? ? "brew --repository failed" : stderr.strip) unless status.success?

      path = stdout.strip
      raise HomebrewError, "brew --repository returned an empty path" if path.empty?

      path
    rescue Errno::ENOENT
      raise HomebrewError, "Homebrew is required but `brew` was not found in PATH"
    end
  end
end

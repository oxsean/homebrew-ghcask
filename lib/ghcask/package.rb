# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "shellwords"
require "tmpdir"

module Ghcask
  module Package
    class Error < StandardError; end
    class DownloadError < Error; end
    class AppInferenceError < Error; end

    AppMetadata = Struct.new(:app, :name, :version, keyword_init: true)

    module_function

    def download(asset, destination_dir:, stdout: nil)
      FileUtils.mkdir_p(destination_dir)
      target = File.join(destination_dir, File.basename(asset.name.to_s))
      url = asset.url
      raise DownloadError, "Release asset #{asset.name} does not have a download URL." if url.to_s.empty?

      stdout&.puts "==> Downloading #{url}"
      success = system(
        "curl",
        "--fail-with-body",
        "--location",
        "--show-error",
        "--progress-bar",
        "--connect-timeout",
        "10",
        "--max-time",
        "300",
        "--output",
        target,
        url
      )
      return target if success

      FileUtils.rm_f(target)
      raise DownloadError, "Failed to download #{asset.name}."
    end

    def sha256(path)
      Digest::SHA256.file(path).hexdigest
    end

    def infer_app(path, app_override: nil)
      return AppMetadata.new(app: app_override, name: app_name_without_extension(app_override)) if present?(app_override)

      case package_type(path)
      when :zip
        infer_zip_app(path)
      when :tar
        infer_tar_app(path)
      when :dmg
        infer_dmg_app(path)
      else
        raise AppInferenceError, "Cannot infer app from #{File.basename(path)}. Re-run with --app Example.app."
      end
    end

    def app_name_without_extension(app)
      File.basename(app.to_s).sub(/\.app\z/i, "")
    end

    def find_apps(root)
      apps = Dir.glob(File.join(root, "**", "*.app")).select { |path| File.directory?(path) }.sort
      apps.reject { |path| nested_inside_app?(path, root) }
    end

    def choose_app(apps, source:)
      raise AppInferenceError, "No .app bundle found in #{source}. Re-run with --app Example.app." if apps.empty?
      if apps.length > 1
        names = apps.map { |path| File.basename(path) }.join(", ")
        raise AppInferenceError, "Multiple .app bundles found in #{source}: #{names}. Re-run with --app Example.app."
      end

      app_path = apps.first
      app = File.basename(app_path)
      plist_metadata = read_info_plist(app_path)
      AppMetadata.new(
        app: app,
        name: plist_metadata[:name] || app_name_without_extension(app),
        version: plist_metadata[:version]
      )
    end

    def infer_zip_app(path)
      Dir.mktmpdir("ghcask-zip-") do |dir|
        stdout, stderr, status = Open3.capture3("ditto", "-x", "-k", path, dir)
        unless status.success?
          message = stderr.strip.empty? ? stdout.strip : stderr.strip
          raise AppInferenceError, "Failed to inspect zip asset: #{message}"
        end

        choose_app(find_apps(dir), source: File.basename(path))
      end
    end

    def infer_tar_app(path)
      Dir.mktmpdir("ghcask-tar-") do |dir|
        stdout, stderr, status = Open3.capture3("tar", "-xzf", path, "-C", dir)
        unless status.success?
          message = stderr.strip.empty? ? stdout.strip : stderr.strip
          raise AppInferenceError, "Failed to inspect tar asset: #{message}"
        end

        choose_app(find_apps(dir), source: File.basename(path))
      end
    end

    def infer_dmg_app(path)
      mountpoint = nil
      plist = nil

      stdout, stderr, status = Open3.capture3("hdiutil", "attach", "-nobrowse", "-readonly", "-plist", path)
      unless status.success?
        message = stderr.strip.empty? ? stdout.strip : stderr.strip
        raise AppInferenceError, "Failed to mount dmg asset: #{message}"
      end

      plist = stdout
      mountpoint = parse_mountpoint(plist)
      raise AppInferenceError, "Could not find dmg mountpoint. Re-run with --app Example.app." unless mountpoint

      choose_app(find_apps(mountpoint), source: File.basename(path))
    ensure
      detach_mountpoint(mountpoint) if mountpoint
    end

    def parse_mountpoint(plist)
      Dir.mktmpdir("ghcask-plist-") do |dir|
        path = File.join(dir, "attach.plist")
        File.write(path, plist)
        stdout, _stderr, status = Open3.capture3("plutil", "-extract", "system-entities", "json", "-o", "-", path)
        return nil unless status.success?

        require "json"
        entities = JSON.parse(stdout)
        entity = entities.find { |item| present?(item["mount-point"]) }
        entity && entity["mount-point"]
      end
    rescue JSON::ParserError
      nil
    end

    def detach_mountpoint(mountpoint)
      Open3.capture3("hdiutil", "detach", mountpoint)
    end

    def nested_inside_app?(path, root)
      relative = path.sub(/\A#{Regexp.escape(root)}\/?/, "")
      parts = relative.split(File::SEPARATOR)
      parts[0...-1].any? { |part| part.end_with?(".app") }
    end

    def read_info_plist(app_path)
      plist = File.join(app_path, "Contents", "Info.plist")
      return {} unless File.exist?(plist)

      {
        name: plist_value(plist, "CFBundleDisplayName") || plist_value(plist, "CFBundleName"),
        version: plist_value(plist, "CFBundleShortVersionString") || plist_value(plist, "CFBundleVersion")
      }
    end

    def plist_value(plist, key)
      stdout, _stderr, status = Open3.capture3("plutil", "-extract", key, "raw", "-o", "-", plist)
      return nil unless status.success?

      value = stdout.strip
      value.empty? ? nil : value
    end

    def package_type(path)
      name = File.basename(path).downcase
      return :dmg if name.end_with?(".dmg")
      return :zip if name.end_with?(".zip")
      return :tar if name.end_with?(".tar.gz", ".tgz")

      nil
    end

    def present?(value)
      !value.nil? && !value.to_s.empty?
    end
  end
end

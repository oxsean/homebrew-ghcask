# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

require "ghcask/errors"
require "ghcask/package_format"

module Ghcask
  # Downloads a package, computes its sha256, and infers the bundled `.app` (or a
  # `.pkg`'s identifier/version) by unpacking it (`ditto`/`tar`/`hdiutil`/`xar`) and
  # reading `Info.plist`/PackageInfo. Injected as `package:` so tests can swap it.
  module Package
    AppMetadata = Struct.new(:app, :name, :version, :pkg_id, :binary, :command, :bundle_id, :auto_updates, :extras, keyword_init: true)

    module_function

    def download(asset, destination_dir:, stdout: nil, headers: [])
      FileUtils.mkdir_p(destination_dir)
      target = File.join(destination_dir, File.basename(asset.name.to_s))
      url = asset.url
      raise DownloadError, "Release asset #{asset.name} does not have a download URL." if url.to_s.empty?

      stdout&.puts "==> Downloading #{url}"
      header_args = headers.flat_map { |h| ["--header", h] }
      success = system(
        "curl", "--fail-with-body", "--location", "--show-error", "--progress-bar",
        "--connect-timeout", "10", "--max-time", "300", *header_args, "--output", target, url
      )
      return target if success && File.exist?(target)

      FileUtils.rm_f(target)
      raise DownloadError, "Failed to download #{asset.name}."
    end

    def sha256(path)
      Digest::SHA256.file(path).hexdigest
    end

    def infer_app(path, app_override: nil)
      case package_type(path)
      when :zip then infer_zip_app(path, app_override)
      when :tar then infer_tar_app(path, app_override)
      when :dmg then infer_dmg_app(path, app_override)
      when :pkg then infer_pkg(path)
      else infer_bare_binary(path)
      end
    rescue AppInferenceError
      raise unless present?(app_override)

      AppMetadata.new(app: app_override, name: app_name_without_extension(app_override))
    end

    def infer_bare_binary(path)
      unless macho_executable?(path)
        raise AppInferenceError, "Cannot infer app from #{File.basename(path)}. Re-run with --app Example.app."
      end

      AppMetadata.new(binary: File.basename(path))
    end

    def infer_pkg(path)
      meta = pkg_metadata(path)
      AppMetadata.new(app: nil, name: nil, version: meta[:version], pkg_id: meta[:pkg_id])
    end

    def app_name_without_extension(app)
      File.basename(app.to_s).sub(/\.app\z/i, "")
    end

    def find_apps(root)
      apps = Dir.glob(File.join(root, "**", "*.app")).select { |path| File.directory?(path) }.sort
      apps.reject { |path| nested_inside_app?(path, root) }
    end

    def choose_app(apps, source:, override: nil)
      if present?(override)
        want = File.basename(override.to_s)
        match = apps.find { |path| File.basename(path).casecmp?(want) }
        raise AppInferenceError, "No .app named #{want} found in #{source}." unless match

        return build_app(match)
      end

      raise AppInferenceError, "No .app bundle found in #{source}. Re-run with --app Example.app." if apps.empty?
      if apps.length > 1
        names = apps.map { |path| File.basename(path) }.join(", ")
        raise AppInferenceError, "Multiple .app bundles found in #{source}: #{names}. Re-run with --app Example.app."
      end

      build_app(apps.first)
    end

    def build_app(app_path)
      app = File.basename(app_path)
      metadata = read_info_plist(app_path)
      AppMetadata.new(
        app: app,
        name: metadata[:name] || app_name_without_extension(app),
        version: metadata[:version],
        bundle_id: metadata[:identifier],
        auto_updates: sparkle?(app_path, metadata)
      )
    end

    def sparkle?(app_path, metadata)
      return true if present?(metadata[:su_feed_url])

      File.directory?(File.join(app_path, "Contents", "Frameworks", "Sparkle.framework"))
    end

    def infer_zip_app(path, override = nil)
      Dir.mktmpdir("ghcask-zip-") do |dir|
        run_extract!(["ditto", "-x", "-k", path, dir], kind: "zip")
        inspect_unpacked(dir, source: File.basename(path), override: override)
      end
    end

    def infer_tar_app(path, override = nil)
      Dir.mktmpdir("ghcask-tar-") do |dir|
        run_extract!(["tar", "-xf", path, "-C", dir], kind: "tar")
        inspect_unpacked(dir, source: File.basename(path), override: override)
      end
    end

    def inspect_unpacked(dir, source:, override: nil)
      apps = find_apps(dir)
      return choose_app(apps, source: source, override: override) if present?(override) || !apps.empty?

      binary = find_binary(dir)
      unless binary
        raise AppInferenceError, "No .app bundle or macOS executable found in #{source}. Re-run with --app Example.app."
      end

      relative = binary.sub(%r{\A#{Regexp.escape(dir)}/?}, "")
      command = File.basename(relative)
      AppMetadata.new(binary: relative, command: command, extras: cli_extras(dir, command))
    end

    def cli_extras(dir, command)
      files = Dir.glob(File.join(dir, "**", "*")).select { |path| File.file?(path) }
      rel = ->(path) { path && path.sub(%r{\A#{Regexp.escape(dir)}/?}, "") }
      named = ->(name) { rel.call(files.find { |path| File.basename(path) == name }) }
      manpage = files.find { |path| File.basename(path).match?(/\A#{Regexp.escape(command)}\.[1-8]\z/) } ||
                files.find { |path| File.basename(path).match?(/\.[1-8]\z/) }
      extras = {
        "manpage" => rel.call(manpage),
        "bash" => named.call("#{command}.bash"),
        "zsh" => named.call("_#{command}"),
        "fish" => named.call("#{command}.fish")
      }.compact
      extras.empty? ? nil : extras
    end

    def find_binary(root)
      machos = Dir.glob(File.join(root, "**", "*")).select { |path| File.file?(path) && macho_executable?(path) }
      if machos.length > 1
        names = machos.map { |path| File.basename(path) }.join(", ")
        raise AppInferenceError, "Multiple executables found in #{File.basename(root)}: #{names}. ghcask installs a single binary; select a single-binary asset with --asset."
      end

      machos.first
    end

    def macho_executable?(path)
      stdout, _stderr, status = Open3.capture3("file", "--brief", path)
      status.success? && stdout.include?("Mach-O") && stdout.include?("executable")
    end

    def infer_dmg_app(path, override = nil)
      mountpoint = nil
      stdout, stderr, status = Open3.capture3("hdiutil", "attach", "-nobrowse", "-readonly", "-plist", path)
      raise AppInferenceError, "Failed to mount dmg asset: #{error_text(stdout, stderr)}" unless status.success?

      mountpoint = parse_mountpoint(stdout)
      raise AppInferenceError, "Could not find dmg mountpoint. Re-run with --app Example.app." unless mountpoint

      choose_app(find_apps(mountpoint), source: File.basename(path), override: override)
    ensure
      detach_dmg(mountpoint) if mountpoint
    end

    def detach_dmg(mountpoint)
      return if Open3.capture3("hdiutil", "detach", mountpoint).last.success?

      Open3.capture3("hdiutil", "detach", "-force", mountpoint)
    end

    def run_extract!(command, kind:)
      stdout, stderr, status = Open3.capture3(*command)
      return if status.success?

      raise AppInferenceError, "Failed to inspect #{kind} asset: #{error_text(stdout, stderr)}"
    end

    def parse_mountpoint(plist)
      Dir.mktmpdir("ghcask-plist-") do |dir|
        path = File.join(dir, "attach.plist")
        File.write(path, plist)
        stdout, _stderr, status = Open3.capture3("plutil", "-extract", "system-entities", "json", "-o", "-", path)
        return nil unless status.success?

        entities = JSON.parse(stdout)
        entity = entities.find { |item| present?(item["mount-point"]) }
        entity && entity["mount-point"]
      end
    rescue JSON::ParserError
      nil
    end

    def nested_inside_app?(path, root)
      relative = path.sub(/\A#{Regexp.escape(root)}\/?/, "")
      parts = relative.split(File::SEPARATOR)
      parts[0...-1].any? { |part| part.end_with?(".app") }
    end

    def read_info_plist(app_path)
      plist = File.join(app_path, "Contents", "Info.plist")
      return {} unless File.exist?(plist)

      data = plist_hash(plist)
      {
        name: plist_str(data["CFBundleDisplayName"]) || plist_str(data["CFBundleName"]),
        version: plist_str(data["CFBundleShortVersionString"]) || plist_str(data["CFBundleVersion"]),
        identifier: plist_str(data["CFBundleIdentifier"]),
        su_feed_url: plist_str(data["SUFeedURL"])
      }
    end

    def plist_hash(plist)
      stdout, _stderr, status = Open3.capture3("plutil", "-convert", "json", "-o", "-", plist)
      return {} unless status.success?

      parsed = JSON.parse(stdout)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def plist_str(value)
      string = value.to_s.strip
      string.empty? ? nil : string
    end

    def package_type(path)
      PackageFormat.type(File.basename(path))
    end

    def pkg_metadata(path)
      Dir.mktmpdir("ghcask-pkg-") do |dir|
        %w[PackageInfo Distribution].each { |member| Open3.capture3("xar", "-xf", path, "-C", dir, member) }
        read_pkg_xml(File.join(dir, "PackageInfo")) || read_pkg_xml(File.join(dir, "Distribution")) || {}
      end
    rescue StandardError
      {}
    end

    def read_pkg_xml(file)
      return nil unless File.exist?(file)

      content = File.read(file)
      pkg_id = content[/\bidentifier="([^"]+)"/, 1] ||
               content[/<product\b[^>]*\bid="([^"]+)"/, 1] ||
               content[/<pkg-ref\b[^>]*\bid="([^"]+)"/, 1]
      version = content[/<pkg-info\b[^>]*?(?<![-\w])version="([^"]+)"/, 1] ||
                content[/<product\b[^>]*?(?<![-\w])version="([^"]+)"/, 1]
      return nil unless pkg_id || version

      { pkg_id: pkg_id, version: version }
    end

    def error_text(stdout, stderr)
      stderr.strip.empty? ? stdout.strip : stderr.strip
    end

    def present?(value)
      !value.nil? && !value.to_s.empty?
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

require "ghcask/package"

class PackageTest < Minitest::Test
  Asset = Struct.new(:name, :url, keyword_init: true)

  def test_sha256
    Dir.mktmpdir do |dir|
      path = File.join(dir, "asset.txt")
      File.write(path, "hello")

      assert_equal Digest::SHA256.hexdigest("hello"), Ghcask::Package.sha256(path)
    end
  end

  def test_download_uses_curl_progress_bar
    Dir.mktmpdir do |dir|
      commands = []
      stdout = StringIO.new
      Ghcask::Package.singleton_class.define_method(:system) do |*command|
        commands << command
        File.write(command[command.index("--output") + 1], "downloaded")
        true
      end

      path = Ghcask::Package.download(
        Asset.new(name: "Example.dmg", url: "https://example.test/Example.dmg"),
        destination_dir: dir,
        stdout: stdout
      )

      assert File.exist?(path)
      assert_includes stdout.string, "==> Downloading https://example.test/Example.dmg"
      assert_includes commands.first, "--progress-bar"
      refute_includes commands.first, "--silent"
    ensure
      Ghcask::Package.singleton_class.remove_method(:system)
    end
  end

  def test_download_removes_partial_file_on_failure
    Dir.mktmpdir do |dir|
      Ghcask::Package.singleton_class.define_method(:system) do |*command|
        File.write(command[command.index("--output") + 1], "partial")
        false
      end

      assert_raises(Ghcask::Package::DownloadError) do
        Ghcask::Package.download(Asset.new(name: "Example.dmg", url: "https://example.test/Example.dmg"), destination_dir: dir)
      end
      refute File.exist?(File.join(dir, "Example.dmg"))
    ensure
      Ghcask::Package.singleton_class.remove_method(:system)
    end
  end

  def test_app_override
    metadata = Ghcask::Package.infer_app("anything.pkg", app_override: "Example.app")

    assert_equal "Example.app", metadata.app
    assert_equal "Example", metadata.name
  end

  def test_find_single_app_in_zip
    Dir.mktmpdir do |dir|
      source = File.join(dir, "source")
      app = File.join(source, "Example.app")
      FileUtils.mkdir_p(File.join(app, "Contents"))
      File.write(File.join(app, "Contents", "Info.plist"), "<plist></plist>")
      zip = File.join(dir, "Example.zip")
      system("ditto", "-c", "-k", source, zip)

      metadata = Ghcask::Package.infer_app(zip)

      assert_equal "Example.app", metadata.app
      assert_equal "Example", metadata.name
    end
  end

  def test_find_single_app_in_tarball
    Dir.mktmpdir do |dir|
      source = File.join(dir, "source")
      app = File.join(source, "Example.app")
      FileUtils.mkdir_p(File.join(app, "Contents"))
      info = "<plist><dict><key>CFBundleName</key><string>Example</string><key>CFBundleShortVersionString</key><string>1.2.3</string></dict></plist>"
      File.write(File.join(app, "Contents", "Info.plist"), info)
      tarball = File.join(dir, "Example.tar.gz")
      assert system("tar", "-czf", tarball, "-C", source, ".")

      metadata = Ghcask::Package.infer_app(tarball)

      assert_equal "Example.app", metadata.app
      assert_equal "Example", metadata.name
      assert_equal "1.2.3", metadata.version
    end
  end

  def test_no_app_in_zip_prints_remediation
    Dir.mktmpdir do |dir|
      source = File.join(dir, "source")
      FileUtils.mkdir_p(source)
      File.write(File.join(source, "README.txt"), "hi")
      zip = File.join(dir, "NoApp.zip")
      system("ditto", "-c", "-k", source, zip)

      error = assert_raises(Ghcask::Package::AppInferenceError) { Ghcask::Package.infer_app(zip) }

      assert_includes error.message, "--app Example.app"
    end
  end

  def test_multiple_apps_in_zip_prints_remediation
    Dir.mktmpdir do |dir|
      source = File.join(dir, "source")
      FileUtils.mkdir_p(File.join(source, "One.app"))
      FileUtils.mkdir_p(File.join(source, "Two.app"))
      zip = File.join(dir, "Many.zip")
      system("ditto", "-c", "-k", source, zip)

      error = assert_raises(Ghcask::Package::AppInferenceError) { Ghcask::Package.infer_app(zip) }

      assert_includes error.message, "Multiple .app"
      assert_includes error.message, "--app Example.app"
    end
  end

  def test_nested_helper_apps_do_not_make_inference_ambiguous
    Dir.mktmpdir do |dir|
      source = File.join(dir, "source")
      main_app = File.join(source, "Recordly.app")
      helper_app = File.join(main_app, "Contents", "Frameworks", "Recordly Helper.app")
      FileUtils.mkdir_p(File.join(main_app, "Contents"))
      FileUtils.mkdir_p(helper_app)
      zip = File.join(dir, "Recordly.zip")
      system("ditto", "-c", "-k", source, zip)

      metadata = Ghcask::Package.infer_app(zip)

      assert_equal "Recordly.app", metadata.app
      assert_equal "Recordly", metadata.name
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "digest"

class PackageTest < GhcaskTest::Case
  def test_sha256_matches_digest
    file = File.join(@tmp, "f.bin")
    File.write(file, "hello")
    assert_equal Digest::SHA256.hexdigest("hello"), Ghcask::Package.sha256(file)
  end

  def test_package_type
    assert_equal :dmg, Ghcask::Package.package_type("A.dmg")
    assert_equal :pkg, Ghcask::Package.package_type("A.pkg")
    assert_equal :zip, Ghcask::Package.package_type("A.zip")
    assert_equal :tar, Ghcask::Package.package_type("A.tar.gz")
    assert_equal :tar, Ghcask::Package.package_type("A.tgz")
    assert_equal :tar, Ghcask::Package.package_type("A.tar.xz")
    assert_equal :tar, Ghcask::Package.package_type("A.tar.zst")
    assert_nil Ghcask::Package.package_type("A.exe")
  end

  def test_app_override_falls_back_when_package_uninspectable
    # dmg can't be mounted → manual override still yields a usable cask.
    meta = Ghcask::Package.infer_app("/nonexistent.dmg", app_override: "Custom.app")
    assert_equal "Custom.app", meta.app
    assert_equal "Custom", meta.name
  end

  def test_choose_app_override_selects_named_bundle_and_reads_plist
    wanted = File.join(@tmp, "Demo.app")
    other = File.join(@tmp, "Helper.app")
    FileUtils.mkdir_p(File.join(wanted, "Contents"))
    FileUtils.mkdir_p(File.join(other, "Contents"))
    File.write(File.join(wanted, "Contents", "Info.plist"), <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>CFBundleIdentifier</key><string>com.demo.example</string>
      </dict>
      </plist>
    PLIST
    # --app picks Demo.app among several AND still reads its bundle id (was lost on the short-circuit).
    meta = Ghcask::Package.choose_app([other, wanted], source: "x.zip", override: "Demo.app")
    assert_equal "Demo.app", meta.app
    assert_equal "com.demo.example", meta.bundle_id
  end

  def test_infer_app_unknown_type_raises
    assert_raises(Ghcask::AppInferenceError) { Ghcask::Package.infer_app(File.join(@tmp, "a.exe")) }
  end

  def test_download_without_url_raises
    asset = Ghcask::Asset.new(name: "A.dmg", url: "")
    assert_raises(Ghcask::DownloadError) { Ghcask::Package.download(asset, destination_dir: @tmp) }
  end

  def test_find_apps_skips_nested_bundles
    FileUtils.mkdir_p(File.join(@tmp, "Top.app", "Contents", "Helper.app"))
    apps = Ghcask::Package.find_apps(@tmp)
    assert_equal ["Top.app"], apps.map { |p| File.basename(p) }
  end

  def test_choose_app_requires_exactly_one
    assert_raises(Ghcask::AppInferenceError) { Ghcask::Package.choose_app([], source: "x.zip") }
    assert_raises(Ghcask::AppInferenceError) { Ghcask::Package.choose_app(%w[/a/A.app /b/B.app], source: "x.zip") }
  end

  def test_choose_app_reads_name_fallback_without_plist
    app = File.join(@tmp, "Example.app")
    FileUtils.mkdir_p(app)
    meta = Ghcask::Package.choose_app([app], source: "x.zip")
    assert_equal "Example.app", meta.app
    assert_equal "Example", meta.name
  end

  def test_choose_app_reads_bundle_id_from_plist
    app = File.join(@tmp, "Demo.app")
    FileUtils.mkdir_p(File.join(app, "Contents"))
    File.write(File.join(app, "Contents", "Info.plist"), <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>CFBundleIdentifier</key><string>com.demo.example</string>
      </dict>
      </plist>
    PLIST
    meta = Ghcask::Package.choose_app([app], source: "x.zip")
    assert_equal "com.demo.example", meta.bundle_id
  end

  def test_choose_app_detects_sparkle_via_feed_url
    app = File.join(@tmp, "Demo.app")
    FileUtils.mkdir_p(File.join(app, "Contents"))
    File.write(File.join(app, "Contents", "Info.plist"), <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>SUFeedURL</key><string>https://example.com/appcast.xml</string>
      </dict>
      </plist>
    PLIST
    assert Ghcask::Package.choose_app([app], source: "x.zip").auto_updates
  end

  def test_choose_app_detects_sparkle_via_framework
    app = File.join(@tmp, "Demo.app")
    FileUtils.mkdir_p(File.join(app, "Contents", "Frameworks", "Sparkle.framework"))
    assert Ghcask::Package.choose_app([app], source: "x.zip").auto_updates
  end

  def test_choose_app_no_auto_updates_without_sparkle
    app = File.join(@tmp, "Plain.app")
    FileUtils.mkdir_p(File.join(app, "Contents"))
    refute Ghcask::Package.choose_app([app], source: "x.zip").auto_updates
  end

  # --- real unpack paths (ditto / tar / plutil) ----------------------------

  def build_app_payload(display: "Demo App", version: "4.5.6")
    contents = File.join(@tmp, "payload", "Demo.app", "Contents")
    FileUtils.mkdir_p(contents)
    File.write(File.join(contents, "Info.plist"), <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>CFBundleDisplayName</key><string>#{display}</string>
        <key>CFBundleShortVersionString</key><string>#{version}</string>
      </dict>
      </plist>
    PLIST
    File.join(@tmp, "payload")
  end

  def test_infer_app_from_real_zip
    payload = build_app_payload
    zip = File.join(@tmp, "Demo.zip")
    skip("ditto unavailable") unless system("ditto", "-c", "-k", payload, zip, out: File::NULL, err: File::NULL)

    meta = Ghcask::Package.infer_app(zip)
    assert_equal "Demo.app", meta.app
    assert_equal "Demo App", meta.name
    assert_equal "4.5.6", meta.version
  end

  def test_infer_app_from_real_tarball
    payload = build_app_payload
    tgz = File.join(@tmp, "Demo.tgz")
    skip("tar unavailable") unless system("tar", "-czf", tgz, "-C", payload, ".", out: File::NULL, err: File::NULL)

    meta = Ghcask::Package.infer_app(tgz)
    assert_equal "Demo.app", meta.app
    assert_equal "Demo App", meta.name
  end

  def test_infer_pkg_reads_identifier_and_version_from_real_package
    pkg = File.join(@tmp, "Demo.pkg")
    built = system("pkgbuild", "--identifier", "com.test.demo", "--version", "3.2.1", "--nopayload", pkg, out: File::NULL, err: File::NULL)
    skip("pkgbuild unavailable") unless built

    meta = Ghcask::Package.infer_app(pkg)
    assert_nil meta.app
    assert_equal "com.test.demo", meta.pkg_id
    assert_equal "3.2.1", meta.version
  end

  def test_pkg_metadata_is_best_effort_on_garbage
    junk = File.join(@tmp, "Junk.pkg")
    File.write(junk, "not a real xar archive")
    meta = Ghcask::Package.infer_app(junk) # must not raise
    assert_nil meta.pkg_id
  end

  # --- binary inference (uses /bin/echo as a real Mach-O) -------------------

  def mach_o_fixture(dest)
    skip("no Mach-O binary available") unless File.exist?("/bin/echo")
    FileUtils.cp("/bin/echo", dest)
    File.chmod(0o755, dest)
    dest
  end

  def test_infer_binary_from_real_tarball
    tooldir = File.join(@tmp, "payload", "tool-1.0")
    FileUtils.mkdir_p(tooldir)
    mach_o_fixture(File.join(tooldir, "rg"))
    tgz = File.join(@tmp, "rg.tar.gz")
    skip("tar unavailable") unless system("tar", "-czf", tgz, "-C", File.join(@tmp, "payload"), ".", out: File::NULL, err: File::NULL)

    meta = Ghcask::Package.infer_app(tgz)
    assert_nil meta.app
    assert_equal "tool-1.0/rg", meta.binary
    assert_equal "rg", meta.command
  end

  def test_infer_binary_detects_manpage_and_completions
    tooldir = File.join(@tmp, "payload", "rg-1.0")
    FileUtils.mkdir_p(File.join(tooldir, "complete"))
    FileUtils.mkdir_p(File.join(tooldir, "doc"))
    mach_o_fixture(File.join(tooldir, "rg"))
    File.write(File.join(tooldir, "doc", "rg.1"), ".TH RG 1")
    File.write(File.join(tooldir, "complete", "rg.bash"), "# bash")
    File.write(File.join(tooldir, "complete", "_rg"), "# zsh")
    File.write(File.join(tooldir, "complete", "rg.fish"), "# fish")
    tgz = File.join(@tmp, "rg.tar.gz")
    skip("tar unavailable") unless system("tar", "-czf", tgz, "-C", File.join(@tmp, "payload"), ".", out: File::NULL, err: File::NULL)

    extras = Ghcask::Package.infer_app(tgz).extras
    assert_equal "rg-1.0/doc/rg.1", extras["manpage"]
    assert_equal "rg-1.0/complete/rg.bash", extras["bash"]
    assert_equal "rg-1.0/complete/_rg", extras["zsh"]
    assert_equal "rg-1.0/complete/rg.fish", extras["fish"]
  end

  def test_infer_binary_from_real_xz_tarball
    payload = File.join(@tmp, "payload")
    FileUtils.mkdir_p(payload)
    mach_o_fixture(File.join(payload, "tool"))
    txz = File.join(@tmp, "tool.tar.xz")
    skip("xz tar unavailable") unless system("tar", "-cJf", txz, "-C", payload, ".", out: File::NULL, err: File::NULL)

    assert_equal "tool", Ghcask::Package.infer_app(txz).binary
  end

  def test_infer_bare_binary
    bin = mach_o_fixture(File.join(@tmp, "mytool-darwin-arm64"))
    meta = Ghcask::Package.infer_app(bin)
    assert_nil meta.app
    assert_equal "mytool-darwin-arm64", meta.binary
    assert_nil meta.command # bare binary has no clean name; source resolves it from the cask
  end

  def test_non_macho_bare_asset_raises
    junk = File.join(@tmp, "notes-darwin")
    File.write(junk, "just text")
    assert_raises(Ghcask::AppInferenceError) { Ghcask::Package.infer_app(junk) }
  end

  def test_multiple_executables_raise
    payload = File.join(@tmp, "payload")
    FileUtils.mkdir_p(payload)
    mach_o_fixture(File.join(payload, "a"))
    mach_o_fixture(File.join(payload, "b"))
    tgz = File.join(@tmp, "two.tar.gz")
    skip("tar unavailable") unless system("tar", "-czf", tgz, "-C", payload, ".", out: File::NULL, err: File::NULL)

    error = assert_raises(Ghcask::AppInferenceError) { Ghcask::Package.infer_app(tgz) }
    refute_includes error.message, "--app" # --app forces app inference; useless for binaries
    assert_includes error.message, "--asset"
  end
end

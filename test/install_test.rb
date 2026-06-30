# frozen_string_literal: true

require "test_helper"

class InstallTest < GhcaskTest::Case
  def default_release(tag: "v1.0.0")
    release(tag: tag, name: "App #{tag}", assets: [["App-arm64.dmg", "https://example.com/App-#{tag}.dmg"]])
  end

  def installer(args, github: nil, package: nil, brew: nil, quarantine: nil)
    @brew = brew || GhcaskTest::FakeBrew.new
    @quarantine = quarantine || GhcaskTest::FakeQuarantine.new
    Ghcask::Commands::Install.new(
      args, stdout: @out, stderr: @err,
      github: github || GhcaskTest::FakeGitHub.new(default_release),
      tap: tap, package: package || GhcaskTest::FakePackage.new,
      brew: @brew, quarantine: @quarantine
    )
  end

  # --- github install ------------------------------------------------------

  def test_install_github_writes_cask_and_installs
    code = installer(%w[acme/app --arch arm64]).install
    assert_equal 0, code

    stored = catalog["app"]
    assert_equal "acme/app", stored.repo
    assert_equal "1.0.0", stored.version
    assert_equal "installed", stored.install_state
    assert File.exist?(tap.cask_path("app"))
    assert_equal [{ name: "app", force: false, quarantine: true }], @brew.installs
    assert_equal 1, @brew.cached.length
  end

  def test_install_github_binary_writes_binary_stanza
    release = release(tag: "v1.0.0", name: "rg v1.0.0", assets: [["rg-1.0-aarch64-apple-darwin.tar.gz", "https://example.com/rg.tar.gz"]])
    pkg = GhcaskTest::FakePackage.new(binary: "rg-1.0/rg", command: "rg")
    code = installer(%w[acme/rg --arch arm64], github: GhcaskTest::FakeGitHub.new(release), package: pkg).install
    assert_equal 0, code

    stored = catalog["rg"]
    assert_equal "rg-1.0/rg", stored.binary
    assert_equal "rg", stored.command
    assert_nil stored.app
    cask = File.read(tap.cask_path("rg"))
    assert_includes cask, %(binary "rg-1.0/rg")
    refute_includes cask, "target:"
    assert_equal [{ name: "rg", force: false, quarantine: true }], @brew.installs
  end

  def test_install_binary_cmd_overrides_command_name
    release = release(tag: "v1.0.0", assets: [["rg-1.0-aarch64-apple-darwin.tar.gz", "https://example.com/rg.tar.gz"]])
    pkg = GhcaskTest::FakePackage.new(binary: "rg-1.0/rg", command: "rg")
    installer(%w[acme/rg --arch arm64 --cmd find2], github: GhcaskTest::FakeGitHub.new(release), package: pkg).install

    assert_equal "find2", catalog["rg"].command
    assert_includes File.read(tap.cask_path("rg")), %(binary "rg-1.0/rg", target: "find2")
  end

  def test_install_bare_binary_falls_back_to_cask_name_for_command
    release = release(tag: "v1.0.0", assets: [["mytool-darwin-arm64", "https://example.com/mytool"]])
    pkg = GhcaskTest::FakePackage.new(binary: "mytool-darwin-arm64") # no command → bare binary
    installer(%w[acme/mytool --arch arm64], github: GhcaskTest::FakeGitHub.new(release), package: pkg).install

    assert_equal "mytool", catalog["mytool"].command
    assert_includes File.read(tap.cask_path("mytool")), %(binary "mytool-darwin-arm64", target: "mytool")
  end

  def test_install_app_generates_zap_with_bundle_id
    pkg = GhcaskTest::FakePackage.new(app: "App.app", bundle_id: "com.acme.app")
    installer(%w[acme/app --arch arm64], package: pkg).install

    assert_equal "com.acme.app", catalog["app"].bundle_id
    cask = File.read(tap.cask_path("app"))
    assert_includes cask, %(zap quit:  "com.acme.app")
    assert_includes cask, %("~/Library/Caches/com.acme.app")
  end

  def test_install_uses_repo_description_in_desc
    github = GhcaskTest::FakeGitHub.new(default_release, repo_description: "Fast grep alternative")
    installer(%w[acme/app --arch arm64], github: github).install
    assert_includes File.read(tap.cask_path("app")), %(desc "Fast grep alternative")
  end

  def test_install_is_concise_by_default
    installer(%w[acme/app]).install
    assert_includes stdout, "==> app 1.0.0"
    refute_includes stdout, "Source: GitHub"
  end

  def test_install_verbose_shows_full_metadata
    installer(%w[acme/app -v]).install
    assert_includes stdout, "Source: GitHub"
    assert_includes stdout, "Quarantine: enabled"
  end

  def test_github_install_downloads_through_authenticated_client
    github = GhcaskTest::FakeGitHub.new(default_release)
    # Use the real Package so a bare-curl download would be the only fallback;
    # routing through the GitHub client is what makes private repos work.
    installer(%w[acme/app], github: github, package: GhcaskTest::FakePackage.new).install
    assert_equal 1, github.downloads.length
    assert_equal "acme/app", github.downloads.first[:repo]
  end

  def test_install_defaults_quarantine_enabled_and_skips_release
    installer(%w[acme/app]).install
    assert catalog["app"].quarantine?
    assert_empty @quarantine.released
  end

  def test_install_checks_gatekeeper_when_quarantine_kept
    installer(%w[acme/app]).install
    assert_equal 1, @quarantine.warned.length
    assert_empty @quarantine.released
  end

  def test_install_no_quarantine_records_policy_and_strips_xattr
    brew = GhcaskTest::FakeBrew.new(app_paths: { "app" => ["/Applications/App.app"] })
    installer(%w[acme/app --no-quarantine], brew: brew).install
    refute catalog["app"].quarantine?
    assert_equal [{ name: "app", force: false, quarantine: false }], brew.installs
    assert_equal [["/Applications/App.app"]], @quarantine.released
  end

  def test_install_pkg_skips_quarantine_handling
    release = release(tag: "v1.0.0", assets: [["App.pkg", "https://example.com/App.pkg"]])
    pkg = GhcaskTest::FakePackage.new(app: nil, pkg_id: "com.acme.app")
    installer(%w[acme/app --arch arm64 -s], github: GhcaskTest::FakeGitHub.new(release), package: pkg).install
    assert catalog["app"].pkg?
    assert_empty @quarantine.released # pkg has no app bundle; no misleading warning
  end

  def test_s_skips_quarantine
    brew = GhcaskTest::FakeBrew.new(app_paths: { "app" => ["/Applications/App.app"] })
    installer(%w[acme/app -s], brew: brew).install
    refute catalog["app"].quarantine?
    assert_equal [["/Applications/App.app"]], @quarantine.released
  end

  def test_install_reuses_existing_without_contacting_github
    seed(entry)
    code = installer(%w[acme/app], github: GhcaskTest::ExplodingGitHub.new).install
    assert_equal 0, code
    assert_includes stdout, "Using existing local cask."
    assert_includes stdout, "Skipping GitHub lookup."
    assert_equal 1, @brew.installs.length
  end

  def test_install_force_bypasses_reuse
    seed(entry)
    installer(%w[acme/app --force]).install
    assert_equal [{ name: "app", force: true, quarantine: true }], @brew.installs
  end

  def test_failed_install_leaves_no_registry_entry
    brew = GhcaskTest::FakeBrew.new(install_error: Ghcask::HomebrewError.new("boom"))
    code = installer(%w[acme/app], brew: brew).install
    assert_equal 1, code
    assert_nil tap.registry.load_if_exists&.[]("app"), "registry must not record a failed install"
    assert File.exist?(tap.cask_path("app")), "cask file is written before brew (orphan on failure)"
  end

  def test_install_writes_registry_once
    installer(%w[acme/app]).install
    # The registry ends at the final state directly (no pending-install left behind).
    assert_equal "installed", catalog["app"].install_state
  end

  def test_install_dry_run_writes_nothing
    code = installer(%w[acme/app --arch arm64 --dry-run]).install
    assert_equal 0, code
    assert_includes stdout, "Would run: brew install --cask ghcask/local/app"
    refute File.exist?(tap.registry_path)
    assert_empty @brew.installs
  end

  def test_install_passes_unrecognized_flags_after_dashdash_to_brew
    installer(%w[acme/app -- --appdir=/Apps --verbose]).install
    assert_equal ["--appdir=/Apps", "--verbose"], @brew.installs.first[:extra]
  end

  def test_install_forwards_common_brew_flags
    installer(%w[acme/app -v -d]).install
    assert_equal ["--verbose", "--debug"], @brew.installs.first[:extra]
  end

  def test_reinstall_passes_through_after_dashdash
    seed(entry)
    installer(%w[app -- --verbose], github: GhcaskTest::ExplodingGitHub.new).reinstall
    assert_equal ["--verbose"], @brew.reinstalls.first[:extra]
  end

  def test_install_dry_run_shows_passthrough_in_plan
    code = installer(%w[acme/app --arch arm64 --dry-run -- --verbose]).install
    assert_equal 0, code
    assert_includes stdout, "Would run: brew install --cask --verbose ghcask/local/app"
  end

  def test_install_trust_trusts_cask
    installer(%w[acme/app --trust]).install
    assert_equal %w[app], @brew.trusts
  end

  def test_install_trust_short_flag_trusts_cask
    installer(%w[acme/app -t]).install
    assert_equal %w[app], @brew.trusts
  end

  # --- generate ------------------------------------------------------------

  def test_generate_creates_without_installing
    code = installer(%w[acme/app]).generate
    assert_equal 0, code
    assert_equal "generated", catalog["app"].install_state
    assert_empty @brew.installs
    assert_includes stdout, "Generated local cask: app."
  end

  def test_generate_supports_multiple_github_targets
    github = GhcaskTest::FakeGitHub.new({
      "acme/app" => default_release,
      "acme/tool" => release(tag: "v3.0.0", assets: [["Tool-arm64.dmg", "https://example.com/Tool.dmg"]])
    })
    # app: nil → each cask name is inferred from the repo basename.
    package = GhcaskTest::FakePackage.new(app: nil)
    code = installer(%w[acme/app acme/tool], github: github, package: package).generate
    assert_equal 0, code
    assert_equal %w[app tool], catalog.names.sort
    assert_empty @brew.installs
  end

  # --- url install ---------------------------------------------------------

  def test_install_tag_url_refreshes_and_pins_even_when_cask_exists
    seed(entry("version" => "1.0.0", "release_tag" => "v1.0.0", "requested_version" => nil))
    github = GhcaskTest::FakeGitHub.new(default_release(tag: "v2.0.0"))
    code = installer(%w[https://github.com/acme/app/releases/tag/v2.0.0], github: github).install
    assert_equal 0, code
    stored = catalog["app"]
    assert_equal "v2.0.0", stored.release_tag
    assert_equal "v2.0.0", stored.requested_version
    assert stored.pinned?
  end

  def test_install_prerelease_refreshes_existing_instead_of_silently_reusing
    seed(entry("release_policy" => "latest-stable", "release_tag" => "v1.0.0"))
    github = GhcaskTest::FakeGitHub.new(release(tag: "v2.0.0-rc1", prerelease: true, assets: [["App-arm64.dmg", "https://example.com/rc.dmg"]]))
    installer(%w[acme/app --prerelease], github: github).install
    assert_equal "latest-prerelease", catalog["app"].release_policy
    assert_equal "v2.0.0-rc1", catalog["app"].release_tag
  end

  def test_reinstall_after_uninstall_restores_installed_state
    seed(entry("install_state" => "uninstalled"))
    installer(%w[app], github: GhcaskTest::ExplodingGitHub.new).reinstall
    assert_equal "installed", catalog["app"].install_state
    assert_equal 1, @brew.reinstalls.length
  end

  def test_install_url_source
    args = ["directapp", "--url", "https://example.com/Direct-1.2.0.dmg"]
    code = installer(args).install
    assert_equal 0, code
    stored = catalog["directapp"]
    assert stored.url?
    assert_equal "1.2.0", stored.version
    assert_equal "https://example.com", stored.homepage
    assert_equal 1, @brew.installs.length
  end

  def test_url_dry_run_previews_without_downloading
    pkg = GhcaskTest::FakePackage.new
    code = installer(["moom", "--url", "https://example.com/Moom-4.5.0.dmg", "--dry-run"], package: pkg).generate
    assert_equal 0, code
    assert_empty pkg.downloads, "dry-run must not download a direct URL package"
    refute File.exist?(tap.cask_path("moom")), "dry-run must not write the cask"
    assert_includes stdout, "4.5.0" # version inferred from the filename, no download
  end

  def test_url_generate_reuses_cached_download
    # Fresh cask (no prior entry); the URL is already in Homebrew's cache → no download.
    pkg = GhcaskTest::FakePackage.new
    brew = GhcaskTest::FakeBrew.new(cached_urls: { "https://example.com/Moom-4.5.0.dmg" => "/cache/moom.dmg" })
    installer(["moom", "--url", "https://example.com/Moom-4.5.0.dmg"], package: pkg, brew: brew).generate
    assert_empty pkg.downloads, "a URL already cached by Homebrew must not be re-downloaded"
    assert_empty brew.cached, "a reused cache file must not be re-cached onto itself"
  end

  def test_url_reinstall_same_url_reuses_entry
    seed(url_entry) # asset_url: https://example.com/Direct-1.2.0.dmg
    pkg = GhcaskTest::FakePackage.new
    installer(["directapp", "--url", "https://example.com/Direct-1.2.0.dmg"], package: pkg).reinstall
    assert_empty pkg.downloads, "unchanged URL must not be re-downloaded or re-hashed"
    assert_includes stdout, "already current"
  end

  def test_github_reinstall_same_version_reuses_entry
    seed(entry("version" => "1.0.0", "release_tag" => "v1.0.0", "asset_name" => "App-arm64.dmg"))
    pkg = GhcaskTest::FakePackage.new
    gh = GhcaskTest::FakeGitHub.new(release(tag: "v1.0.0", assets: [["App-arm64.dmg", "https://example.com/app.dmg"]]))
    installer(%w[app --version v1.0.0], github: gh, package: pkg).reinstall
    assert_empty pkg.downloads, "an unchanged release must not be re-downloaded or re-hashed"
    assert_includes stdout, "already current"
  end

  def test_url_reinstall_force_redownloads
    seed(url_entry)
    pkg = GhcaskTest::FakePackage.new
    brew = GhcaskTest::FakeBrew.new(cached_urls: { "https://example.com/Direct-1.2.0.dmg" => "/cache/directapp.dmg" })
    installer(["directapp", "--url", "https://example.com/Direct-1.2.0.dmg", "--force"], package: pkg, brew: brew).reinstall
    refute_empty pkg.downloads, "--force must re-download even when cached"
  end

  def test_url_reinstall_new_url_redownloads
    seed(url_entry)
    pkg = GhcaskTest::FakePackage.new
    brew = GhcaskTest::FakeBrew.new(cached_urls: { "https://example.com/Direct-1.2.0.dmg" => "/cache/directapp.dmg" })
    installer(["directapp", "--url", "https://example.com/Direct-2.0.0.dmg"], package: pkg, brew: brew).reinstall
    refute_empty pkg.downloads, "a changed URL is a different cache key and must be downloaded"
  end

  def test_install_url_rejects_a_changed_url_for_existing_cask
    seed(url_entry) # asset_url: https://example.com/Direct-1.2.0.dmg
    code = installer(["directapp", "--url", "https://example.com/Direct-2.0.0.dmg"]).install
    assert_equal 1, code
    assert_includes stderr, "already exists from a different URL"
    assert_includes stderr, "reinstall directapp --url"
  end

  def test_install_url_github_release_authenticates_download
    github = GhcaskTest::FakeGitHub.new(default_release, auth_token: "t")
    package = GhcaskTest::FakePackage.new
    args = ["foo", "--url", "https://github.com/acme/app/releases/download/v1.2.0/Foo-1.2.0.dmg"]
    installer(args, github: github, package: package).install
    assert_includes package.download_headers.last, "Authorization: Bearer t"
    assert_equal "1.2.0", catalog["foo"].version
  end

  def test_install_url_raw_github_authenticates_download
    github = GhcaskTest::FakeGitHub.new(default_release, auth_token: "t")
    package = GhcaskTest::FakePackage.new
    args = ["foo", "--url", "https://raw.githubusercontent.com/acme/app/main/Foo-1.2.0.dmg"]
    installer(args, github: github, package: package).install
    assert_includes package.download_headers.last, "Authorization: Bearer t"
  end

  def test_install_url_non_github_sends_no_auth
    github = GhcaskTest::FakeGitHub.new(default_release, auth_token: "t")
    package = GhcaskTest::FakePackage.new
    installer(["foo", "--url", "https://example.com/Foo-1.2.0.dmg"], github: github, package: package).install
    assert_empty package.download_headers.last
  end

  def test_install_url_no_quarantine
    brew = GhcaskTest::FakeBrew.new(app_paths: { "directapp" => ["/Applications/Direct.app"] })
    args = ["directapp", "--url", "https://example.com/Direct-1.2.0.dmg", "--no-quarantine"]
    installer(args, brew: brew).install
    refute catalog["directapp"].quarantine?
    assert_equal [["/Applications/Direct.app"]], @quarantine.released
  end

  def test_install_url_pkg_renders_pkg_stanza
    brew = GhcaskTest::FakeBrew.new
    args = ["foopkg", "--url", "https://example.com/Foo-1.2.pkg"]
    installer(args, package: GhcaskTest::FakePackage.new(app: nil, pkg_id: "com.foo.bar"), brew: brew).install
    stored = catalog["foopkg"]
    assert stored.pkg?
    assert_equal "com.foo.bar", stored.pkg_id
    cask = File.read(tap.cask_path("foopkg"))
    assert_includes cask, %(pkg "Foo-1.2.pkg")
    assert_includes cask, %(uninstall pkgutil: "com.foo.bar")
    assert_equal 1, brew.installs.length
  end

  def test_install_github_pkg_asset
    github = GhcaskTest::FakeGitHub.new(release(tag: "v1.0.0", assets: [["Tool-1.0.0.pkg", "https://example.com/Tool.pkg"]]))
    installer(%w[acme/tool], github: github, package: GhcaskTest::FakePackage.new(app: nil, pkg_id: "com.acme.tool")).install
    stored = catalog["tool"]
    assert stored.pkg?
    assert_equal "com.acme.tool", stored.pkg_id
    assert_includes File.read(tap.cask_path("tool")), %(pkg "Tool-1.0.0.pkg")
  end

  def test_install_url_rejects_github_only_flags
    args = ["directapp", "--url", "https://example.com/Direct.dmg", "--prerelease"]
    code = installer(args).install
    assert_equal 1, code
    assert_includes stderr, "only available for GitHub source installs"
  end

  def test_install_url_requires_single_target
    code = installer(["a", "b", "--url", "https://example.com/A.dmg"]).install
    assert_equal 1, code
    assert_includes stderr, "--url supports exactly one cask name"
  end

  # --- reinstall -----------------------------------------------------------

  def test_reinstall_existing_does_not_refresh
    seed(entry)
    code = installer(%w[app], github: GhcaskTest::ExplodingGitHub.new).reinstall
    assert_equal 0, code
    assert_equal 1, @brew.reinstalls.length
  end

  def test_reinstall_with_version_pins_and_refreshes
    seed(entry)
    github = GhcaskTest::FakeGitHub.new(default_release(tag: "v2.0.0"))
    installer(%w[acme/app --version v2.0.0], github: github).reinstall
    stored = catalog["app"]
    assert_equal "v2.0.0", stored.release_tag
    assert_equal "v2.0.0", stored.requested_version
    assert stored.pinned?
    assert_equal 1, @brew.reinstalls.length
  end

  def test_reinstall_quarantine_only_is_lightweight
    seed(entry("quarantine" => true, "version" => "1.0.0", "release_tag" => "v1.0.0"))
    brew = GhcaskTest::FakeBrew.new(app_paths: { "app" => ["/Applications/App.app"] })
    code = installer(%w[app --no-quarantine], github: GhcaskTest::ExplodingGitHub.new, brew: brew).reinstall
    assert_equal 0, code
    stored = catalog["app"]
    refute stored.quarantine?
    assert_equal "1.0.0", stored.version, "quarantine-only reinstall must not change the version"
    assert_equal [{ name: "app", force: false, quarantine: false }], brew.reinstalls
    assert_equal [["/Applications/App.app"]], @quarantine.released
  end

  def test_reinstall_prerelease_switches_track_without_pinning
    seed(entry("release_policy" => "latest-stable", "release_tag" => "v1.0.0"))
    github = GhcaskTest::FakeGitHub.new(release(tag: "v2.0.0-rc1", prerelease: true, assets: [["App-arm64.dmg", "https://example.com/rc.dmg"]]))
    installer(%w[app --prerelease], github: github).reinstall
    stored = catalog["app"]
    assert_equal "latest-prerelease", stored.release_policy
    assert_equal "v2.0.0-rc1", stored.release_tag
    refute stored.pinned?, "track switch must not pin"
  end

  def test_reinstall_stable_switches_track
    seed(entry("release_policy" => "latest-prerelease", "release_tag" => "v2.0.0-rc1"))
    github = GhcaskTest::FakeGitHub.new(release(tag: "v1.5.0", assets: [["App-arm64.dmg", "https://example.com/stable.dmg"]]))
    installer(%w[app --stable], github: github).reinstall
    assert_equal "latest-stable", catalog["app"].release_policy
    assert_equal "v1.5.0", catalog["app"].release_tag
  end

  def test_install_version_overwrites_and_pins_existing
    seed(entry("version" => "1.0.0", "release_tag" => "v1.0.0", "requested_version" => nil))
    github = GhcaskTest::FakeGitHub.new(default_release(tag: "v2.0.0"))
    installer(%w[acme/app --version v2.0.0], github: github).install
    stored = catalog["app"]
    assert_equal "v2.0.0", stored.release_tag
    assert_equal "v2.0.0", stored.requested_version
    assert_equal [{ name: "app", force: false, quarantine: true }], @brew.installs
  end

  def test_reinstall_url_replaces_source
    seed(url_entry)
    args = ["directapp", "--url", "https://example.com/Direct-2.0.0.dmg"]
    installer(args).reinstall
    stored = catalog["directapp"]
    assert_equal "2.0.0", stored.version
    assert_equal "https://example.com/Direct-2.0.0.dmg", stored.asset_url
    assert_equal 1, @brew.reinstalls.length
  end

  def test_reinstall_url_flag_rejected_for_github_cask
    seed(entry)
    code = installer(["app", "--url", "https://example.com/x.dmg"]).reinstall
    assert_equal 1, code
    assert_includes stderr, "reinstall --url is only supported for direct URL casks"
    assert_includes stderr, "brew ghcask reinstall app --force" # actionable, not the nonexistent upgrade --force
  end

  def test_reinstall_mutually_exclusive_selectors
    seed(entry)
    code = installer(%w[app --version v2.0.0 --prerelease]).reinstall
    assert_equal 1, code
    assert_includes stderr, "mutually exclusive"
  end

  # --- validation ----------------------------------------------------------

  def test_install_requires_target
    assert_equal 1, installer([]).install
    assert stderr.start_with?("Error:"), "errors should use brew's Error: prefix"
    assert_includes stderr, "repository is required"
  end

  def test_install_prerelease_and_stable_conflict
    code = installer(%w[acme/app --prerelease --stable]).install
    assert_equal 1, code
    assert_includes stderr, "mutually exclusive"
  end
end

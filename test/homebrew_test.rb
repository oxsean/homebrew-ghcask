# frozen_string_literal: true

require "test_helper"

class HomebrewTest < GhcaskTest::Case
  def brew(runner)
    Ghcask::Homebrew::Brew.new(runner: runner, stdout: @out, stderr: @err)
  end

  def test_repository_honors_env_override
    original = ENV["GHCASK_BREW_REPOSITORY"]
    ENV["GHCASK_BREW_REPOSITORY"] = @tmp
    assert_equal File.expand_path(@tmp), Ghcask::Homebrew.repository
  ensure
    ENV["GHCASK_BREW_REPOSITORY"] = original
  end

  def test_install_command_includes_force_and_no_quarantine
    runner = GhcaskTest::FakeRunner.new
    brew(runner).install("app", force: true, quarantine: false)
    command = runner.commands.last
    assert_equal %w[brew install --cask --force --no-quarantine ghcask/local/app], command
    # brew-style: a `==>` step marker, and no redundant completion line.
    assert_includes @out.string, "==> brew install"
    refute_includes @out.string, "Homebrew finished"
  end

  def test_extra_flags_forwarded_before_token
    runner = GhcaskTest::FakeRunner.new
    brew(runner).install("app", extra: ["--verbose", "--appdir=/X"])
    assert_equal %w[brew install --cask --verbose --appdir=/X ghcask/local/app], runner.commands.last
  end

  def test_upgrade_and_uninstall_forward_extra
    runner = GhcaskTest::FakeRunner.new
    brew(runner).upgrade("app", extra: ["--verbose"])
    assert_equal %w[brew upgrade --cask --verbose ghcask/local/app], runner.commands.last

    brew(runner).uninstall("app", force: true, extra: ["--zap"])
    assert_equal %w[brew uninstall --cask --force --zap ghcask/local/app], runner.commands.last
  end

  def test_install_defaults_to_quarantine_on
    runner = GhcaskTest::FakeRunner.new
    brew(runner).install("app")
    assert_equal %w[brew install --cask ghcask/local/app], runner.commands.last
  end

  def test_install_failure_raises_with_inspect_hint
    runner = GhcaskTest::FakeRunner.new
    runner.on("brew", "install", stderr: "Error: boom", ok: false)
    error = assert_raises(Ghcask::HomebrewError) { brew(runner).install("app") }
    assert_includes error.message, "Error: boom"
    assert_includes error.message, "brew cat --cask ghcask/local/app"
  end

  def test_uninstall_warns_but_succeeds_when_not_installed
    runner = GhcaskTest::FakeRunner.new
    runner.on("brew", "uninstall", stderr: "Error: Cask 'app' is not installed.", ok: false)
    assert_equal :missing, brew(runner).uninstall("app", force: false)
    assert_includes stderr, "Marking the ghcask registry entry as uninstalled anyway"
  end

  def test_info_parses_installed_version_and_paths
    runner = GhcaskTest::FakeRunner.new
    json = JSON.generate("casks" => [{
      "token" => "app", "installed" => "1.2.3",
      "artifacts" => [{ "app" => ["App.app"], "target" => "/Applications/App.app" }]
    }])
    runner.on("brew", "info", stdout: json)
    info = brew(runner).info("app")
    assert info.installed?
    assert_equal "1.2.3", info.installed_version
    assert_includes info.app_paths, "/Applications/App.app"
  end

  def test_installed_versions_maps_tokens_to_names
    runner = GhcaskTest::FakeRunner.new
    json = JSON.generate("casks" => [{ "full_token" => "ghcask/local/app", "installed" => "1.0.0" }])
    runner.on("brew", "info", stdout: json)
    assert_equal({ "app" => "1.0.0" }, brew(runner).installed_versions(%w[app]))
  end

  def test_installed_versions_falls_back_per_cask_when_batch_fails
    runner = GhcaskTest::FakeRunner.new
    good = JSON.generate("casks" => [{ "token" => "good", "installed" => "1.0.0" }])
    # Rules are matched last-added-first, so the longer batch rule wins for the
    # batch call while the single-cask calls fall through to their own rules.
    runner.on("brew", "info", "--cask", "--json=v2", "ghcask/local/good", stdout: good)
    runner.on("brew", "info", "--cask", "--json=v2", "ghcask/local/bad", ok: false)
    runner.on("brew", "info", "--cask", "--json=v2", "ghcask/local/good", "ghcask/local/bad", ok: false)

    assert_equal({ "good" => "1.0.0" }, brew(runner).installed_versions(%w[good bad]))
  end

  def test_cache_package_moves_file
    runner = GhcaskTest::FakeRunner.new
    cache = File.join(@tmp, "cache", "app.dmg")
    runner.on("brew", "--cache", stdout: "#{cache}\n")
    src = File.join(@tmp, "download.dmg")
    File.write(src, "bytes")

    result = brew(runner).cache_package("app", src)
    assert_equal cache, result
    assert File.exist?(cache)
    refute File.exist?(src), "asset should be moved, not copied"
  end

  def test_installed_casks_nil_on_failure
    runner = GhcaskTest::FakeRunner.new
    runner.on("brew", "list", ok: false)
    assert_nil brew(runner).installed_casks
  end
end

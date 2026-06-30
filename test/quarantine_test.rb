# frozen_string_literal: true

require "test_helper"

class QuarantineTest < GhcaskTest::Case
  def quarantine(runner)
    Ghcask::Quarantine.new(runner: runner, stdout: @out, stderr: @err)
  end

  def app_dir
    path = File.join(@tmp, "App.app")
    FileUtils.mkdir_p(path)
    path
  end

  def test_releases_existing_paths
    runner = GhcaskTest::FakeRunner.new
    path = app_dir
    released = quarantine(runner).release([path])
    assert_equal [path], released
    command = runner.commands.last
    assert_equal ["xattr", "-dr", "com.apple.quarantine", path], command
  end

  def test_missing_attribute_is_not_a_failure
    runner = GhcaskTest::FakeRunner.new
    runner.on("xattr", stderr: "No such xattr: com.apple.quarantine", ok: false)
    assert_equal [app_dir], quarantine(runner).release([app_dir])
  end

  def test_real_xattr_failure_raises
    runner = GhcaskTest::FakeRunner.new
    runner.on("xattr", stderr: "Operation not permitted", ok: false)
    error = assert_raises(Ghcask::QuarantineError) { quarantine(runner).release([app_dir]) }
    assert_includes error.message, "Operation not permitted"
    assert_includes error.message, "xattr -dr com.apple.quarantine"
  end

  def test_warn_if_blocked_warns_with_xattr_command_for_unsigned_app
    runner = GhcaskTest::FakeRunner.new
    runner.on("spctl", ok: false) # Gatekeeper rejects → unsigned/un-notarized
    path = app_dir
    quarantine(runner).warn_if_blocked([path])
    assert_includes stderr, "macOS may refuse to open it"
    assert_includes stderr, "xattr -dr com.apple.quarantine #{path.inspect}"
  end

  def test_warn_if_blocked_silent_for_signed_app
    runner = GhcaskTest::FakeRunner.new
    runner.on("spctl", ok: true) # Gatekeeper accepts
    quarantine(runner).warn_if_blocked([app_dir])
    assert_empty stderr
  end

  def test_warn_if_blocked_silent_when_spctl_unavailable
    runner = GhcaskTest::FakeRunner.new
    runner.executable("spctl", present: false)
    quarantine(runner).warn_if_blocked([app_dir])
    assert_empty stderr
  end

  def test_no_existing_paths_warns_and_returns_empty
    runner = GhcaskTest::FakeRunner.new
    assert_empty quarantine(runner).release([File.join(@tmp, "missing.app")])
    assert_empty quarantine(runner).release([])
    assert_includes stderr, "Could not find an installed app bundle"
  end
end

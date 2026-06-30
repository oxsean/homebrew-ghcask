# frozen_string_literal: true

require "test_helper"

class DoctorTest < GhcaskTest::Case
  def doctor(args, runner: nil)
    Ghcask::Commands::Doctor.new(args, stdout: @out, stderr: @err, runner: runner || GhcaskTest::FakeRunner.new)
  end

  def test_lists_required_tools_including_xattr
    code = doctor([]).run
    assert_equal 0, code
    assert_includes stdout, "xattr: ok"
    assert_includes stdout, "brew: ok"
    assert_includes stdout, "gh: ok"
  end

  def test_shasum_not_required
    doctor([]).run
    refute_includes stdout, "shasum" # sha256 uses Digest::SHA256, not the CLI
  end

  def test_reports_missing_tool
    runner = GhcaskTest::FakeRunner.new
    runner.executable("gh", present: false)
    doctor([], runner: runner).run
    assert_includes stdout, "gh: missing"
  end

  def test_dry_run_flag
    doctor(%w[--dry-run]).run
    assert_includes stdout, "Dry run: yes"
  end

  def test_unknown_option
    code = doctor(%w[--bogus]).run
    assert_equal 1, code
    assert_includes stderr, "unknown option --bogus"
  end

  def test_help
    code = doctor(%w[--help]).run
    assert_equal 0, code
    assert_includes stdout, "Usage:"
  end
end

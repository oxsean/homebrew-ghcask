# frozen_string_literal: true

require "test_helper"
require "ghcask/cli"

class GhcaskCliTest < Minitest::Test
  def run_cli(*argv)
    stdout = StringIO.new
    stderr = StringIO.new
    status = Ghcask::CLI.run(argv, stdout: stdout, stderr: stderr)
    [status, stdout.string, stderr.string]
  end

  def test_help_prints_usage
    status, stdout, stderr = run_cli("--help")

    assert_equal 0, status
    assert_includes stdout, "Usage:"
    assert_includes stdout, "install owner/repo"
    assert_includes stdout, "install cask-name --url URL"
    assert_includes stdout, "update                                    Refresh all local cask metadata without upgrading apps"
    assert_includes stdout, "upgrade [cask-name]"
    assert_includes stdout, "reinstall cask-name|owner/repo"
    assert_includes stdout, "reinstall cask-name --url URL"
    assert_includes stdout, "pin cask-name|owner/repo"
    assert_includes stdout, "unpin cask-name|owner/repo"
    assert_includes stdout, "uninstall cask-name|owner/repo"
    assert_includes stdout, "cleanup [--dry-run]"
    assert_includes stdout, "dump [options]"
    assert_includes stdout, "restore [options]"
    assert_includes stdout, "--dry-run     Preview supported commands without writing local state"
    assert_includes stdout, "Install options:"
    assert_includes stdout, "--url URL"
    assert_includes stdout, "--no-install"
    assert_includes stdout, "--trust"
    assert_includes stdout, "Reinstall options:"
    assert_includes stdout, "--prerelease"
    assert_includes stdout, "--stable"
    assert_includes stdout, "Upgrade options:"
    assert_includes stdout, "--force"
    assert_includes stdout, "Outdated options:"
    assert_includes stdout, "--all"
    assert_includes stdout, "Pin and unpin:"
    assert_includes stdout, "Repository formats:"
    assert_includes stdout, "https://github.com/owner/repo/releases/tag/v1.2.3"
    assert_includes stdout, "Uninstall options:"
    assert_includes stdout, "--keep-installed"
    assert_includes stdout, "Dump and restore options:"
    assert_includes stdout, "--file PATH"
    assert_includes stdout, "--global"
    assert_empty stderr
  end

  def test_doctor_dry_run_dispatches_without_network
    status, stdout, stderr = run_cli("doctor", "--dry-run")

    assert_equal 0, status
    assert_includes stdout, "ghcask doctor"
    assert_includes stdout, "Dry run: yes"
    assert_includes stdout, "Required tools:"
    assert_includes stdout, "tar:"
    assert_empty stderr
  end

  def test_unknown_command_fails_with_hint
    status, _stdout, stderr = run_cli("wat")

    assert_equal 1, status
    assert_includes stderr, "unknown command: wat"
    assert_includes stderr, "brew ghcask --help"
  end
end

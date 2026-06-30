# frozen_string_literal: true

require "test_helper"

class CommandRunnerTest < GhcaskTest::Case
  def runner
    @runner ||= Ghcask::CommandRunner.new
  end

  def test_capture_success_and_stdout
    result = runner.capture(["printf", "hi"])
    assert result.success?
    assert_equal "hi", result.stdout
  end

  def test_capture_nonzero_exit
    refute runner.capture(["false"]).success?
  end

  def test_capture_missing_binary_returns_failure
    result = runner.capture(["ghcask-no-such-binary-xyz"])
    refute result.success?
    refute_empty result.stderr
  end

  def test_which_finds_on_path
    path = runner.which("ls")
    assert path&.end_with?("/ls")
    assert File.executable?(path)
  end

  def test_which_nil_for_missing
    assert_nil runner.which("ghcask-no-such-binary-xyz")
  end

  def test_which_absolute_path
    assert_equal "/bin/ls", runner.which("/bin/ls")
    assert_nil runner.which("/no/such/binary")
  end

  def test_executable_predicate
    assert runner.executable?("ls")
    refute runner.executable?("ghcask-no-such-binary-xyz")
  end
end

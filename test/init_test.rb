# frozen_string_literal: true

require "test_helper"

class InitTest < GhcaskTest::Case
  def init(args)
    Ghcask::Commands::Init.new(args, stdout: @out, stderr: @err, tap: tap)
  end

  def test_creates_tap_and_registry
    code = init([]).run
    assert_equal 0, code
    assert File.directory?(tap.casks_dir)
    assert File.exist?(tap.registry_path)
    assert_includes stdout, "Initialized ghcask local tap:"
  end

  def test_is_idempotent
    seed(entry) # tap already initialized with a cask
    code = init([]).run
    assert_equal 0, code
    assert_equal entry, catalog["app"] # existing registry/cask untouched
  end

  def test_help
    code = init(%w[--help]).run
    assert_equal 0, code
    assert_includes stdout, "Usage:"
  end

  def test_rejects_unknown_option
    code = init(%w[--bogus]).run
    assert_equal 1, code
    assert_includes stderr, "unknown option --bogus"
  end
end

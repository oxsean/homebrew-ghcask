# frozen_string_literal: true

require "test_helper"
require "tmpdir"

require "ghcask/local_tap"

class LocalTapTest < Minitest::Test
  def test_init_creates_generated_tap_and_registry
    Dir.mktmpdir do |homebrew|
      tap = Ghcask::LocalTap.new(homebrew_repository: homebrew)

      tap.init

      assert Dir.exist?(tap.root)
      assert Dir.exist?(tap.casks_dir)
      assert File.exist?(tap.registry_path)
      assert_equal({ "version" => 1, "casks" => {} }, tap.registry.load)
    end
  end

  def test_init_is_idempotent
    Dir.mktmpdir do |homebrew|
      tap = Ghcask::LocalTap.new(homebrew_repository: homebrew)

      tap.init
      tap.init

      assert_equal({ "version" => 1, "casks" => {} }, tap.registry.load)
    end
  end
end

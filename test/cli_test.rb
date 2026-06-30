# frozen_string_literal: true

require "test_helper"

class CLITest < GhcaskTest::Case
  def setup
    super
    @original_repo = ENV["GHCASK_BREW_REPOSITORY"]
    ENV["GHCASK_BREW_REPOSITORY"] = @tmp
  end

  def teardown
    ENV["GHCASK_BREW_REPOSITORY"] = @original_repo
    super
  end

  def run_cli(*argv)
    Ghcask::CLI.run(argv, stdout: @out, stderr: @err)
  end

  def test_version
    assert_equal 0, run_cli("--version")
    assert_equal "ghcask #{Ghcask::VERSION}", stdout.strip
  end

  def test_version_short_flag
    assert_equal 0, run_cli("-v")
    assert_equal "ghcask #{Ghcask::VERSION}", stdout.strip
  end

  def test_help_variants
    assert_equal 0, run_cli("--help")
    assert_includes stdout, "Usage:"
    assert_equal 0, run_cli
    assert_includes stdout, "ghcask #{Ghcask::VERSION}"
  end

  def test_help_documents_pinned_upgrade_behavior
    run_cli("--help")
    assert_includes stdout, "Upgrade skips pinned casks"
  end

  def test_unknown_command
    code = run_cli("frobnicate")
    assert_equal 1, code
    assert_includes stderr, "Error: Unknown command: frobnicate"
  end

  def test_init_routes_and_creates_tap
    assert_equal 0, run_cli("init")
    assert File.exist?(tap.registry_path)
    assert_includes stdout, "Initialized ghcask local tap:"
  end

  def test_list_routes_to_inventory
    seed(entry)
    assert_equal 0, run_cli("list")
    assert_includes stdout, "app\t1.0.0\tacme/app"
  end

  def test_uninstall_aliases_route_together
    %w[uninstall remove rm].each do |alias_name|
      assert_includes Ghcask::CLI::HELP, "uninstall"
      # routing: an unknown cask returns 1 via the same handler
      @out = StringIO.new
      @err = StringIO.new
      code = run_cli(alias_name, "missing-cask")
      assert_equal 1, code
      assert_includes stderr, "managed cask not found"
    end
  end

  def test_doctor_routes
    assert_equal 0, run_cli("doctor", "--dry-run")
    assert_includes stdout, "ghcask doctor"
  end
end

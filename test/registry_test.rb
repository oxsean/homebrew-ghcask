# frozen_string_literal: true

require "test_helper"

class RegistryTest < GhcaskTest::Case
  def registry
    @registry ||= Ghcask::Registry.new(File.join(@tmp, "ghcask.json"))
  end

  def test_ensure_exists_creates_empty_catalog
    cat = registry.ensure_exists
    assert_empty cat.names
    assert File.exist?(registry.path)
  end

  def test_load_if_exists_returns_nil_without_file
    assert_nil registry.load_if_exists
  end

  def test_save_and_load_round_trip
    cat = Ghcask::Catalog.new
    cat["app"] = entry
    registry.save(cat)

    loaded = registry.load
    assert_equal %w[app], loaded.names
    assert_equal entry, loaded["app"]
  end

  def test_atomic_write_leaves_no_temp_files
    registry.save(Ghcask::Catalog.new)
    leftovers = Dir.children(@tmp).grep(/\.tmp\z/)
    assert_empty leftovers
  end

  def test_corrupt_json_raises
    File.write(registry.path, "{not json")
    assert_raises(Ghcask::CorruptRegistryError) { registry.load }
  end

  def test_wrong_version_raises
    File.write(registry.path, JSON.generate("version" => 99, "casks" => {}))
    assert_raises(Ghcask::CorruptRegistryError) { registry.load }
  end

  def test_find_by_repo
    cat = Ghcask::Catalog.new
    cat["app"] = entry("repo" => "acme/app")
    name, found = cat.find_by_repo("acme/app")
    assert_equal "app", name
    assert_equal "acme/app", found.repo
    assert_nil cat.find_by_repo("nope/none")
    assert_nil cat.find_by_repo(nil)
  end
end

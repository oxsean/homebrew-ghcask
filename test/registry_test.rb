# frozen_string_literal: true

require "test_helper"
require "tmpdir"

require "ghcask/registry"

class RegistryTest < Minitest::Test
  def registry_in_tempdir
    Dir.mktmpdir do |dir|
      yield Ghcask::Registry.new(File.join(dir, "ghcask.json"))
    end
  end

  def test_ensure_exists_writes_empty_registry
    registry_in_tempdir do |registry|
      assert_equal({ "version" => 1, "casks" => {} }, registry.ensure_exists)
      assert_equal({ "version" => 1, "casks" => {} }, registry.load)
    end
  end

  def test_save_and_load_round_trip
    registry_in_tempdir do |registry|
      data = {
        "version" => 1,
        "casks" => {
          "example" => {
            "repo" => "owner/repo",
            "version" => "1.2.3"
          }
        }
      }

      registry.save(data)

      assert_equal data, registry.load
    end
  end

  def test_save_writes_without_validation_but_load_validates
    registry_in_tempdir do |registry|
      registry.save("nope")

      error = assert_raises(Ghcask::Registry::CorruptError) { registry.load }
      assert_includes error.message, "registry must be a JSON object"
    end
  end

  def test_corrupted_registry_raises_clear_error
    registry_in_tempdir do |registry|
      File.write(registry.path, "{ nope")

      error = assert_raises(Ghcask::Registry::CorruptError) { registry.load }
      assert_includes error.message, "registry is not valid JSON"
    end
  end

  def test_invalid_registry_shape_raises_clear_error
    registry_in_tempdir do |registry|
      File.write(registry.path, JSON.dump("nope"))

      error = assert_raises(Ghcask::Registry::CorruptError) { registry.load }
      assert_includes error.message, "registry must be a JSON object"
    end
  end
end

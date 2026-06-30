# frozen_string_literal: true

require "test_helper"

class EntryTest < GhcaskTest::Case
  def test_quarantine_defaults_to_enabled
    assert Ghcask::Entry.new("cask" => "x").quarantine?
  end

  def test_explicit_false_quarantine_survives_construction
    refute Ghcask::Entry.new("cask" => "x", "quarantine" => false).quarantine?
  end

  def test_symbol_keys_are_accepted
    e = Ghcask::Entry.new(cask: "x", source_type: "url")
    assert_equal "x", e.cask
    assert e.url?
  end

  def test_bundle_id_round_trips
    e = Ghcask::Entry.new("cask" => "x", "bundle_id" => "com.x.y")
    assert_equal "com.x.y", Ghcask::Entry.from_h(e.to_h).bundle_id
  end

  def test_pinned_tracks_requested_version
    refute entry("requested_version" => nil).pinned?
    refute entry("requested_version" => "").pinned?
    assert entry("requested_version" => "v1.2.3").pinned?
  end

  def test_source_predicates
    assert entry.github?
    refute entry.url?
    assert url_entry.url?
    refute url_entry.checkable?
    assert entry.checkable?
  end

  def test_merge_is_non_destructive_and_restringifies
    original = entry("quarantine" => true)
    merged = original.merge(quarantine: false, version: "2.0.0")
    refute merged.quarantine?
    assert_equal "2.0.0", merged.version
    assert original.quarantine?, "merge must not mutate the receiver"
    assert_equal "1.0.0", original.version
  end

  def test_to_h_round_trips
    e = entry("quarantine" => false, "requested_version" => "v1.0.0")
    assert_equal e, Ghcask::Entry.from_h(e.to_h)
  end

  def test_to_h_contains_every_attribute
    assert_equal Ghcask::Entry::ATTRIBUTES.sort, entry.to_h.keys.sort
  end

  def test_pkg_predicate_keys_off_asset_extension
    refute entry("asset_name" => "App.dmg").pkg?
    assert entry("asset_name" => "Foo-1.0.pkg").pkg?
    assert entry("asset_name" => "FOO.PKG").pkg?
  end

  def test_state_helpers
    assert entry("install_state" => "generated").generated?
    assert entry("install_state" => "uninstalled").uninstalled?
    refute entry("install_state" => "installed").generated?
  end
end

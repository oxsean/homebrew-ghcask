# frozen_string_literal: true

require "test_helper"

require "ghcask/cask"

class CaskTest < Minitest::Test
  def github_entry
    {
      "repo" => "owner/repo",
      "source_type" => "github",
      "cask" => "example",
      "name" => "Example\"; system(\"bad\") #",
      "app" => "Example\nBad.app",
      "version" => "1.0.0\"; system(\"bad\") #",
      "asset_url" => "https://example.test/Example.dmg?x=\"bad\"",
      "sha256" => "abc123"
    }
  end

  def test_render_quotes_github_fields_as_ruby_string_literals
    rendered = Ghcask::Cask.render(github_entry)

    assert_includes rendered, "version \"1.0.0\\\"; system(\\\"bad\\\") #\""
    assert_includes rendered, "name \"Example\\\"; system(\\\"bad\\\") #\""
    assert_includes rendered, "app \"Example\\nBad.app\""
    assert_includes rendered, 'desc "Generated from GitHub Releases"'
  end

  def test_render_quotes_direct_url_homepage
    entry = github_entry.merge(
      "source_type" => "url",
      "homepage" => "https://example.test/\"; system(\"bad\") #"
    )

    rendered = Ghcask::Cask.render(entry)

    assert_includes rendered, "homepage \"https://example.test/\\\"; system(\\\"bad\\\") #\""
    assert_includes rendered, 'desc "Generated from a direct package URL"'
  end
end

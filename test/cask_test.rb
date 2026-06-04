# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "tmpdir"

require "ghcask/cask"

class CaskTest < Minitest::Test
  def github_entry(overrides = {})
    {
      "repo" => "owner/repo",
      "source_type" => "github",
      "cask" => "example",
      "name" => "Example",
      "app" => "Example.app",
      "version" => "1.2.3",
      "asset_url" => "https://github.com/owner/repo/releases/download/v1.2.3/Example.dmg",
      "sha256" => "abc123"
    }.merge(overrides)
  end

  def url_entry(overrides = {})
    {
      "source_type" => "url",
      "cask" => "example",
      "name" => "Example",
      "app" => "Example.app",
      "version" => "2.4.0",
      "asset_url" => "https://downloads.example.test/apps/Example-2.4.0.dmg",
      "homepage" => "https://downloads.example.test",
      "sha256" => "def456"
    }.merge(overrides)
  end

  def assert_ruby_syntax(source)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "example.rb")
      File.write(path, source)
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-c", path)
      assert status.success?, stderr
    end
  end

  def test_render_preserves_ordinary_github_output
    rendered = Ghcask::Cask.render(github_entry)

    assert_equal <<~RUBY, rendered
      cask "example" do
        version "1.2.3"
        sha256 "abc123"

        url "https://github.com/owner/repo/releases/download/v1.2.3/Example.dmg"
        name "Example"
        desc "Generated from GitHub Releases"
        homepage "https://github.com/owner/repo"

        app "Example.app"
      end
    RUBY
    assert_ruby_syntax(rendered)
  end

  def test_render_url_escapes_dangerous_literals
    payload = %q{bad"quote\path#{Kernel.system("echo hacked")};raise("no")}
    rendered = Ghcask::Cask.render(
      url_entry(
        "cask" => payload,
        "version" => payload,
        "sha256" => payload,
        "asset_url" => "https://downloads.example.test/#{payload}.dmg",
        "name" => payload,
        "homepage" => "https://downloads.example.test/#{payload}",
        "app" => "#{payload}.app"
      )
    )

    assert_includes rendered, "cask #{payload.dump} do"
    assert_includes rendered, "version #{payload.dump}"
    assert_includes rendered, "sha256 #{payload.dump}"
    assert_includes rendered, "name #{payload.dump}"
    assert_includes rendered, "app #{("#{payload}.app").dump}"
    assert_includes rendered, "url #{("https://downloads.example.test/#{payload}.dmg").dump}"
    assert_includes rendered, "homepage #{("https://downloads.example.test/#{payload}").dump}"
    assert_match(/\\#\{/, rendered)
    refute_match(/(?<!\\)#\{/, rendered)
    assert_ruby_syntax(rendered)
  end

  def test_render_escapes_github_homepage_literal
    repo = %q{owner/repo"#{Kernel.warn("repo payload")}}
    rendered = Ghcask::Cask.render(github_entry("repo" => repo))

    assert_includes rendered, %(homepage #{("https://github.com/#{repo}").dump})
    refute_match(/(?<!\\)#\{/, rendered)
    assert_ruby_syntax(rendered)
  end
end

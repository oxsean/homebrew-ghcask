# frozen_string_literal: true

require "time"

module Ghcask
  Release = Struct.new(:tag_name, :name, :draft, :prerelease, :published_at, :assets, keyword_init: true)
  Asset = Struct.new(:name, :url, :api_url, keyword_init: true)
  Repo = Struct.new(:full_name, :stars, :description, keyword_init: true)

  def self.strip_v(version)
    version.to_s.sub(/\Av/i, "")
  end

  MAX_DESC = 80

  def self.concise_desc(text)
    cleaned = text.to_s.strip.gsub(/\s+/, " ")
    return cleaned if cleaned.length <= MAX_DESC

    first = cleaned.split(/\.\s/).first.to_s.sub(/\.\z/, "").strip
    return first if first.length <= MAX_DESC

    "#{first[0, MAX_DESC - 1].sub(/\s\S*\z/, "").strip}…"
  end

  def self.now
    Time.now.utc.iso8601
  end
end

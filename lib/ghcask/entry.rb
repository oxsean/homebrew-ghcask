# frozen_string_literal: true

module Ghcask
  # The one definition of a registry entry: every command goes through it, never raw
  # string keys, so the JSON schema lives in one place. `to_h`/`from_h` round-trip the
  # persisted form `dump`/`restore` and the cask renderer depend on.
  class Entry
    ATTRIBUTES = %w[
      repo source_type cask name desc app pkg_id binary command bundle_id auto_updates extras release_policy requested_version
      asset_pattern arch version release_tag asset_name asset_url homepage
      sha256 quarantine install_state updated_at
    ].freeze

    GITHUB = "github"
    URL = "url"

    STATE_GENERATED = "generated"
    STATE_PENDING = "pending-install"
    STATE_INSTALLED = "installed"
    STATE_UNINSTALLED = "uninstalled"

    def initialize(attributes = {})
      @attributes = {}
      ATTRIBUTES.each do |key|
        @attributes[key] = attributes.key?(key) ? attributes[key] : attributes[key.to_sym]
      end
      @attributes["quarantine"] = true if @attributes["quarantine"].nil?
    end

    def self.from_h(hash)
      new(hash)
    end

    ATTRIBUTES.each do |attribute|
      define_method(attribute) { @attributes[attribute] }
      define_method("#{attribute}=") { |value| @attributes[attribute] = value }
    end

    def github?
      source_type == GITHUB
    end

    def url?
      source_type == URL
    end

    def pkg?
      asset_name.to_s.downcase.end_with?(".pkg")
    end

    def binary?
      !binary.to_s.empty?
    end

    def auto_updates?
      @attributes["auto_updates"] == true
    end

    def pinned?
      !requested_version.to_s.empty?
    end

    def quarantine?
      @attributes["quarantine"] != false
    end

    def generated?
      install_state == STATE_GENERATED
    end

    def uninstalled?
      install_state == STATE_UNINSTALLED
    end

    def checkable?
      github?
    end

    def merge(attributes)
      self.class.new(to_h.merge(stringify(attributes)))
    end

    def to_h
      @attributes.dup
    end

    def ==(other)
      other.is_a?(Entry) && other.to_h == to_h
    end

    private

    def stringify(attributes)
      attributes.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
    end
  end
end

# frozen_string_literal: true

require "ghcask/entry"

module Ghcask
  # The in-memory set of managed casks, keyed by cask name. Wraps the raw
  # `{ name => Entry }` map so commands manipulate entries by name without
  # reaching into the persisted Hash shape.
  class Catalog
    def initialize(entries = {})
      @entries = entries
    end

    def self.from_h(data)
      entries = data.fetch("casks").each_with_object({}) do |(name, attributes), out|
        out[name] = Entry.from_h(attributes)
      end
      new(entries)
    end

    def [](name)
      @entries[name]
    end

    def []=(name, entry)
      @entries[name] = entry
    end

    def delete(name)
      @entries.delete(name)
    end

    def each(&block)
      @entries.each(&block)
    end

    def names
      @entries.keys
    end

    def find_by_repo(repo)
      return nil if repo.to_s.empty?

      @entries.find { |_name, entry| entry.repo == repo }
    end

    def to_h
      {
        "version" => Registry::VERSION,
        "casks" => @entries.transform_values(&:to_h)
      }
    end
  end
end

# frozen_string_literal: true

module Ghcask
  # Single source of truth for the macOS package extensions ghcask understands
  # and the artifact type each maps to. Asset scoring, unpacking, and direct-URL
  # validation all derive from this, so adding a format is one edit here.
  module PackageFormat
    TYPES = {
      ".dmg" => :dmg,
      ".pkg" => :pkg,
      ".zip" => :zip,
      ".tar.gz" => :tar,
      ".tar.xz" => :tar,
      ".tar.bz2" => :tar,
      ".tar.zst" => :tar,
      ".tgz" => :tar
    }.freeze

    EXTENSIONS = TYPES.keys.sort_by { |ext| -ext.length }.freeze

    module_function

    def extension(name)
      lower = name.to_s.downcase
      EXTENSIONS.find { |ext| lower.end_with?(ext) }
    end

    def type(name)
      TYPES[extension(name)]
    end

    def package?(name)
      !type(name).nil?
    end
  end
end

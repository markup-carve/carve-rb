# frozen_string_literal: true

# Carve: Ruby bindings for the Carve markup language.
#
# This file loads the compiled native extension (built from ext/carve, a Rust
# crate wrapping the carve-rs engine via magnus) and layers a small,
# idiomatic Ruby API on top of the raw primitives it exports.
require_relative "carve/version"

# Load the compiled native extension. Built by `rake compile` to
# lib/carve/carve.so (or .bundle on macOS).
require_relative "carve/carve"

module Carve
  # Extension names the native binding understands (snake_case or hyphenated).
  EXTENSIONS = %i[
    autolink
    details
    list_table
    math_block
    heading_permalinks
    citations
    tab_normalize
    wikilinks
    external_links
    fenced_render
    spoiler
    table_of_contents
  ].freeze

  class << self
    # Render Carve +source+ to an HTML string.
    #
    # With no extensions:
    #   Carve.to_html("# Hello")             # => "<section ...>\n  <h1>Hello</h1>..."
    #
    # With extensions (Array of names as Symbols or Strings):
    #   Carve.to_html(src, extensions: [:math_block])
    #   Carve.to_html(src, extensions: %w[math-block list-table])
    #
    # Recognized extension names: see Carve::EXTENSIONS. Names may be given
    # snake_case (:math_block) or hyphenated ("math-block").
    #
    # An unknown extension name raises ArgumentError (from the native layer).
    def to_html(source, extensions: nil)
      list = Array(extensions)
      return _to_html(source.to_s) if list.empty?

      to_html_with_extensions(source.to_s, list.map(&:to_s))
    end
  end
end

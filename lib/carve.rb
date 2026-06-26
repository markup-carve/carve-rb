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
    code_callouts
    tab_normalize
    wikilinks
    external_links
    fenced_render
    fenced_render_graphviz
    fenced_render_chart
    spoiler
    table_of_contents
  ].freeze

  # Render modes the native binding understands.
  #
  # +:interactive+ (default) emits live HTML with client-script hooks (e.g.
  # `<pre class="mermaid">`, `<details>`). +:static+ emits self-contained HTML
  # for print / PDF / archival: it forces disclosure (`<details open>`) and
  # pre-renders client-script constructs through the +renderers:+ callables,
  # degrading to (escaped) source when a renderer is absent or fails.
  MODES = %i[interactive static].freeze

  # Renderer keys accepted by the +renderers:+ Hash (see .to_html). Each maps a
  # construct's source to a self-contained HTML string emitted on the static
  # path. +mermaid+ / +chart+ / +graphviz+ are callables `(String) -> String`;
  # +math+ is `(String, display_bool) -> String`.
  RENDERER_KEYS = %i[mermaid chart graphviz math].freeze

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
    #
    # ==== Static render mode
    #
    # Pass +mode: :static+ (or "static") to emit self-contained HTML for print /
    # PDF / archival. In static mode disclosure is forced (`<details open>`) and
    # client-script constructs are pre-rendered through the +renderers:+ Hash:
    #
    #   Carve.to_html(src, extensions: [:fenced_render], mode: :static,
    #                 renderers: { mermaid: ->(s) { "<svg>#{s}</svg>" } })
    #
    # Renderer callables (Symbol or String keys, see Carve::RENDERER_KEYS):
    #   * +:mermaid+ / +:chart+ / +:graphviz+ -> callable `(String) -> String`
    #   * +:math+                             -> callable `(String, display) -> String`
    #
    # When a needed renderer is absent, or a renderer raises / returns a
    # non-String, the construct degrades to its HTML-ESCAPED source (never blank,
    # never raw HTML). Omitting +mode:+ defaults to interactive (non-breaking).
    #
    # An unknown mode or renderer key raises ArgumentError (from the native
    # layer).
    def to_html(source, extensions: nil, mode: nil, renderers: nil)
      list = Array(extensions)

      # Fast path: interactive (default), no extensions, no renderers.
      if list.empty? && (mode.nil? || mode.to_s == "interactive") && (renderers.nil? || renderers.empty?)
        return _to_html(source.to_s)
      end

      to_html_full(
        source.to_s,
        list.map(&:to_s),
        (mode || :interactive).to_s,
        renderers || {},
      )
    end
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "carve"

class CarveTest < Minitest::Test
  # Path to the carve-rs CLI binary, used for byte-identical checks.
  # Override with the CARVE_CLI env var; the test is skipped when absent.
  CARVE_CLI = ENV.fetch("CARVE_CLI", "../carve-rs/target/release/carve")

  def test_version_defined
    assert_match(/\A\d+\.\d+\.\d+\z/, Carve::VERSION)
  end

  def test_heading
    html = Carve.to_html("# Hi")
    assert_includes html, "<h1"
    assert_includes html, "Hi"
  end

  def test_bold_uses_asterisk
    # In Carve, *...* is STRONG (bold), unlike Djot/Markdown emphasis rules.
    html = Carve.to_html("*x*")
    assert_includes html, "<strong>x</strong>"
  end

  def test_emphasis_uses_slash
    # In Carve, /.../ is EMPHASIS (italic).
    html = Carve.to_html("/x/")
    assert_includes html, "<em>x</em>"
  end

  def test_list
    html = Carve.to_html("- one\n- two\n")
    assert_includes html, "<ul>"
    assert_includes html, "<li>"
    assert_includes html, "one"
    assert_includes html, "two"
  end

  def test_link
    html = Carve.to_html("[label](https://example.com)")
    assert_includes html, '<a href="https://example.com"'
    assert_includes html, "label</a>"
  end

  def test_table
    src = <<~CRV
      | a | b |
      |---|---|
      | 1 | 2 |
    CRV
    html = Carve.to_html(src)
    assert_includes html, "<table>"
    assert_includes html, "<td>1</td>"
  end

  def test_extension_changes_output_math_block
    src = <<~CRV
      ```math
      a^2 + b^2 = c^2
      ```
    CRV
    plain = Carve.to_html(src)
    with_math = Carve.to_html(src, extensions: [:math_block])
    # Enabling the extension must change the output.
    refute_equal plain, with_math
    # The math-block extension emits a math container/class.
    assert_includes with_math, "math"
  end

  def test_extension_accepts_hyphenated_string
    src = "```math\nx\n```\n"
    sym = Carve.to_html(src, extensions: [:math_block])
    str = Carve.to_html(src, extensions: ["math-block"])
    assert_equal sym, str
  end

  def test_extension_changes_output_code_callouts
    src = "``` python\nresult = 1 + 1  <1>\n```\n\n<1> The sum.\n"
    plain = Carve.to_html(src)
    with_cc = Carve.to_html(src, extensions: [:code_callouts])
    refute_equal plain, with_cc
    assert_includes with_cc, 'class="callout"'
  end

  def test_unknown_extension_raises_argument_error
    assert_raises(ArgumentError) do
      Carve.to_html("# x", extensions: [:no_such_extension])
    end
  end

  # ---- Static render mode + renderers ---------------------------------------

  DETAILS_SRC = <<~CRV
    ::: details "FAQ"
    body text
    :::
  CRV

  def test_static_mode_forces_details_open
    # carve-rb inherits the disclosure rule from carve-rs: static mode forces
    # `<details open>`, interactive/default emits a collapsed `<details>`.
    interactive = Carve.to_html(DETAILS_SRC, extensions: [:details])
    static = Carve.to_html(DETAILS_SRC, extensions: [:details], mode: :static)
    assert_includes interactive, "<details>"
    refute_includes interactive, "<details open"
    assert_includes static, "<details open"
  end

  def test_mode_default_is_interactive
    # Omitting mode must equal explicit interactive (non-breaking default).
    assert_equal Carve.to_html(DETAILS_SRC, extensions: [:details]),
                 Carve.to_html(DETAILS_SRC, extensions: [:details], mode: :interactive)
  end

  MERMAID_SRC = <<~CRV
    ```mermaid
    graph TD; A-->B
    ```
  CRV

  def test_mermaid_static_without_renderer_falls_back_to_source
    # No renderer supplied: the static path degrades to the (escaped) source,
    # not an injected SVG.
    html = Carve.to_html(MERMAID_SRC, extensions: [:fenced_render], mode: :static)
    assert_includes html, "graph TD"
    refute_includes html, "<svg>"
  end

  def test_mermaid_static_with_renderer_injects_svg
    html = Carve.to_html(
      MERMAID_SRC,
      extensions: [:fenced_render],
      mode: :static,
      renderers: { "mermaid" => ->(s) { "<svg>" + s + "</svg>" } },
    )
    assert_includes html, "<svg>graph TD; A-->B"
    assert_includes html, "</svg>"
  end

  def test_graphviz_renderer_consulted_for_dot_fence
    src = <<~CRV
      ```dot
      digraph { a -> b }
      ```
    CRV
    html = Carve.to_html(
      src,
      extensions: [:fenced_render_graphviz],
      mode: :static,
      renderers: { "graphviz" => ->(s) { "<svg class=\"gv\">rendered</svg>" } },
    )
    assert_includes html, "<svg class=\"gv\">rendered</svg>"
  end

  MATH_SRC = <<~CRV
    ```math
    a^2 + b^2 = c^2
    ```
  CRV

  def test_math_renderer_receives_display_flag
    # Block math must call the renderer with display=true; inline with false.
    block = Carve.to_html(
      MATH_SRC,
      extensions: [:math_block],
      mode: :static,
      renderers: { "math" => ->(tex, display) { "<math d=\"#{display}\">#{tex.strip}</math>" } },
    )
    assert_includes block, "<math d=\"true\">"

    inline = Carve.to_html(
      "text $`x+y` end",
      extensions: [:math_block],
      mode: :static,
      renderers: { "math" => ->(tex, display) { "<math d=\"#{display}\">#{tex}</math>" } },
    )
    assert_includes inline, "<math d=\"false\">"
  end

  def test_unknown_mode_raises_argument_error
    assert_raises(ArgumentError) do
      Carve.to_html("# x", mode: :no_such_mode)
    end
  end

  # The engine keys diagram renderers by fence css class and accepts ANY key,
  # including a custom fence word's class. This binding therefore forwards the
  # key instead of allowlisting it - an allowlist could not express a custom
  # fence at all, and had to be edited whenever the engine learned a new
  # diagram type.
  #
  # The cost is that a typo no longer raises: "mermiad" now registers a
  # renderer that never fires, where it used to be an ArgumentError. That is
  # the price of matching the engine's contract rather than imposing a stricter
  # one on top of it.
  def test_arbitrary_renderer_key_registers_a_diagram_renderer
    html = Carve.to_html("```mermaid\ngraph TD;\n```\n",
                         extensions: [:fenced_render], mode: :static,
                         renderers: { "mermaid" => ->(_src) { "<svg id=\"m\"></svg>" } })
    assert_includes html, "<svg id=\"m\"></svg>"

    # An unrecognized key is accepted rather than rejected: it simply never
    # matches a fence.
    assert_kind_of String, Carve.to_html("# x", mode: :static,
                                         renderers: { "no_such" => ->(s) { s } })
  end

  def test_empty_renderer_key_raises_argument_error
    assert_raises(ArgumentError) do
      Carve.to_html("# x", mode: :static, renderers: { "" => ->(s) { s } })
    end
  end

  def test_renderer_raising_falls_back_to_escaped_source
    # A hostile source plus a raising renderer must degrade to ESCAPED source -
    # never raw HTML (the carve-py XSS lesson). No `<img onerror=...>` may leak.
    hostile = <<~CRV
      ```mermaid
      <img src=x onerror=alert(1)>
      ```
    CRV
    html = Carve.to_html(
      hostile,
      extensions: [:fenced_render],
      mode: :static,
      renderers: { "mermaid" => ->(_s) { raise "renderer boom" } },
    )
    refute_includes html, "<img src=x onerror=alert(1)>"
    assert_includes html, "&lt;img src=x onerror=alert(1)&gt;"
  end

  def test_renderer_non_string_return_falls_back_to_escaped_source
    hostile = <<~CRV
      ```mermaid
      <b>x</b>
      ```
    CRV
    html = Carve.to_html(
      hostile,
      extensions: [:fenced_render],
      mode: :static,
      renderers: { "mermaid" => ->(_s) { 42 } }, # non-String return
    )
    refute_includes html, "<b>x</b>"
    assert_includes html, "&lt;b&gt;x&lt;/b&gt;"
  end

  def test_constants_advertise_modes_and_renderer_keys
    assert_equal %i[interactive static], Carve::MODES
    assert_equal %i[mermaid chart graphviz math], Carve::RENDERER_KEYS
    # The canonical graphviz fenced-render preset is advertised.
    assert_includes Carve::EXTENSIONS, :fenced_render_graphviz
  end

  # ---- Byte-identical parity vs the carve-rs CLI ----------------------------

  def cli_html(source)
    skip "carve-rs CLI not built at #{CARVE_CLI}" unless File.executable?(CARVE_CLI)
    out, status = Open3.capture2(CARVE_CLI, stdin_data: source)
    assert status.success?, "carve CLI failed"
    out
  end

  # The CLI prints a single trailing newline; the library does not. Normalize
  # by stripping one trailing newline from each side before comparing.
  def assert_byte_identical(source)
    lib = Carve.to_html(source).sub(/\n\z/, "")
    cli = cli_html(source).sub(/\n\z/, "")
    assert_equal cli, lib, "library output diverges from carve-rs CLI"
  end

  def test_byte_identical_heading_inline
    assert_byte_identical("# Hello *world*\n\n/italic/ text.")
  end

  def test_byte_identical_list_and_link
    assert_byte_identical("- [a](https://a.test)\n- second\n")
  end

  def test_byte_identical_table
    assert_byte_identical("| h1 | h2 |\n|----|----|\n| x | y |\n")
  end

  # Extension-generated ids join the document id namespace (extensions
  # contract 2.6): reference-list ids dedupe against explicit {#id}
  # attributes and generated heading ids inside the engine. The binding
  # exposes citations without a bibliography pool, so only ref-{key}
  # entries are reachable here (cite-{key}-{n} anchors need a pool).
  def test_citation_reference_ids_avoid_heading_ids
    src = "# ref foo\n\nSee [@foo].\n\n[@foo]: Foo reference.\n"
    html = Carve.to_html(src, extensions: [:citations])
    assert_includes html, 'id="ref-foo"'          # the heading section keeps the slug
    assert_includes html, 'id="ref-foo-2"'        # the reference entry is bumped
    assert_includes html, 'href="#ref-foo-2"'     # and the citation link follows
  end

  def test_citation_reference_ids_avoid_explicit_ids
    src = "{#ref-foo}\nReserved.\n\nSee [@foo].\n\n[@foo]: Foo reference.\n"
    html = Carve.to_html(src, extensions: [:citations])
    assert_includes html, 'id="ref-foo-2"'
    assert_includes html, 'href="#ref-foo-2"'
  end

  def test_citation_reference_ids_stable_without_collision
    src = "See [@foo].\n\n[@foo]: Foo reference.\n"
    html = Carve.to_html(src, extensions: [:citations])
    assert_includes html, 'id="ref-foo"'
    assert_includes html, 'href="#ref-foo"'
    refute_includes html, 'ref-foo-2'
  end

  # ---- Carve.parse (AST export) --------------------------------------

  def test_parse_returns_document_root
    ast = Carve.parse("# Hi")
    assert_equal "document", ast[:type]
    assert_kind_of Array, ast[:children]
    assert_equal 4, ast[:srcByteLength]
  end

  # PART 12 section 2: the root carries `frontmatter` and `footnoteDefs`
  # EXACTLY when the document has them. This used to emit an empty object for
  # every document, which says "this document has frontmatter, and it is empty"
  # - a different claim, and one the reference does not make (carve#411).
  def test_parse_omits_root_fields_the_document_does_not_have
    ast = Carve.parse("# Hi")

    refute ast.key?(:frontmatter)
    refute ast.key?(:footnoteDefs)
  end

  def test_parse_carries_root_fields_the_document_does_have
    with_frontmatter = Carve.parse("---\ntitle: x\n---\n\nbody\n")
    with_footnote = Carve.parse("a[^r]\n\n[^r]: d\n")

    assert_equal({ title: "x" }, with_frontmatter[:frontmatter])
    refute with_frontmatter.key?(:footnoteDefs)
    assert with_footnote.key?(:footnoteDefs)
    refute with_footnote.key?(:frontmatter)
  end

  def test_parse_heading_with_inline_children
    heading = Carve.parse("# Hello *world*")[:children].first
    assert_equal "heading", heading[:type]
    assert_equal 1, heading[:level]
    kinds = heading[:children].map { |n| n[:type] }
    assert_equal %w[text emphasis], kinds
    strong = heading[:children].last
    assert_equal "strong", strong[:kind]
    assert_equal "world", strong[:children].first[:value]
  end

  def test_parse_emphasis_kinds
    para = Carve.parse("*b* /i/")[:children].first
    kinds = para[:children].select { |n| n[:type] == "emphasis" }.map { |n| n[:kind] }
    assert_equal %w[strong italic], kinds
  end

  # A typographic substitution is its own node carrying BOTH halves: the
  # resolved kind and the author's source run (spec PART 9 section 8). A
  # consumer that displays the document reads the glyph or resolves the kind; a
  # consumer rebuilding source reads the value. Serializing only one half would
  # make this binding's JSON lossier than the tree behind it.
  def test_parse_smart_punctuation_carries_kind_and_source
    para = Carve.parse(%(He said "hi" and it's fine... a--b))[:children].first
    smart = para[:children].select { |n| n[:type] == "smart_punctuation" }

    kinds = smart.map { |n| n[:kind] }
    assert_includes kinds, "left_double_quote"
    assert_includes kinds, "ellipsis"
    assert_includes kinds, "en_dash"

    # The author's spelling survives.
    assert_equal "...", smart.find { |n| n[:kind] == "ellipsis" }[:value]
    assert_equal "--", smart.find { |n| n[:kind] == "en_dash" }[:value]

    # A quote carries its resolved glyph, because the character is
    # locale-dependent and is chosen during parsing; other kinds resolve
    # through the spec's table and carry no glyph of their own.
    assert_equal "\u201C", smart.find { |n| n[:kind] == "left_double_quote" }[:glyph]
    assert_nil smart.find { |n| n[:kind] == "ellipsis" }[:glyph]
  end

  def test_parse_list_items
    list = Carve.parse("- one\n- two\n")[:children].first
    assert_equal "list", list[:type]
    refute list[:ordered]
    assert_equal 2, list[:items].size
    assert_equal "list_item", list[:items].first[:type]
  end

  def test_parse_table_header_cells
    table = Carve.parse("|= A |= B |\n| 1 | 2 |\n")[:children].first
    assert_equal "table", table[:type]
    assert_equal [true, true], table[:rows].first[:cells].map { |c| c[:header] }
  end

  def test_parse_code_block_fields
    code = Carve.parse("```ruby\nputs 1\n```\n")[:children].first
    assert_equal "code_block", code[:type]
    assert_equal "ruby", code[:lang]
    assert_includes code[:content], "puts 1"
  end

  def test_parse_link_node
    para = Carve.parse("[text](https://x.io)")[:children].first
    link = para[:children].find { |n| n[:type] == "link" }
    assert_equal "https://x.io", link[:href]
    assert_equal "text", link[:children].first[:value]
  end

  def test_parse_autolink_exposes_display_text
    para = Carve.parse("<mailto:a@b.example>")[:children].first
    auto = para[:children].find { |n| n[:type] == "autolink" }
    assert_equal "mailto:a@b.example", auto[:href]
    assert_equal "mailto:a@b.example", auto[:text]
  end

  def test_parse_uses_the_spec_node_vocabulary
    # These names are docs/profiles.md, not this binding's choosing: a tree from
    # here has to be readable by carve-js and carve-php (markup-carve/carve#405).
    para = Carve.parse("a {+i+} {-d-} {~o~>n~} b")[:children].first
    types = para[:children].map { |n| n[:type] }

    assert_includes types, "insert"
    assert_includes types, "delete"
    assert_includes types, "substitution"
    refute_includes types, "critic_insert"
  end

  def test_parse_splits_the_two_footnote_forms
    # `footnote` is the BLOCK definition type in the vocabulary, so using it for
    # the inline forms named three things with one identifier.
    para = Carve.parse("a[^r] and ^[n]\n\n[^r]: def\n")[:children].first
    types = para[:children].map { |n| n[:type] }

    assert_includes types, "footnote_ref"
    assert_includes types, "inline_footnote"
    refute_includes types, "footnote"
  end

  def test_parse_root_uses_reference_field_names
    ast = Carve.parse("a[^r]\n\n[^r]: def\n")

    assert ast.key?(:footnoteDefs)
    assert ast.key?(:srcByteLength)
    refute ast.key?(:footnote_defs)
    refute ast.key?(:source_len)
  end

  def test_parse_critic_nodes_expose_attrs
    para = Carve.parse("a {+ins+}{.note} b")[:children].first
    ins = para[:children].find { |n| n[:type] == "insert" }
    assert_equal "ins", ins[:children].first[:value]
    assert ins.key?(:attrs)
  end

  def test_parse_handles_deep_nesting_beyond_json_default
    # Ruby JSON defaults max_nesting to 100; the engine allows deeper. A doc
    # the engine renders must also parse without JSON::NestingError.
    src = ("> " * 120) + "deep\n"
    ast = Carve.parse(src)
    assert_equal "document", ast[:type]
  end

  def test_parse_attrs_shape
    node = Carve.parse("{#id .cls}\n# H")[:children].first
    assert_equal "id", node[:attrs][:id]
    assert_includes node[:attrs][:classes], "cls"
  end

  # --- Engine language surface --------------------------------------------
  #
  # These exercise the carve-rs engine through the binding's public API, so a
  # stale engine pin in ext/carve/Cargo.lock surfaces as a test failure rather
  # than as a silently outdated language.

  def test_superscript_and_subscript_are_braced_only
    # Bare `^x^` / `,x,` are literal text; only the braced forms mark up.
    literal = Carve.to_html("a ^2^ b and H,2,O")
    refute_includes literal, "<sup>"
    refute_includes literal, "<sub>"

    marked = Carve.to_html("x{^2^} and H{,2,}O")
    assert_includes marked, "<sup>2</sup>"
    assert_includes marked, "<sub>2</sub>"
  end

  def test_symbol_inline_renders_and_takes_attrs
    # An unmapped symbol renders its `:name:` source, but it is a real Symbol
    # node - attaching attributes proves it parsed as one rather than as text.
    assert_includes Carve.to_html(":smile:{.emoji}"), '<span class="emoji">:smile:</span>'
  end

  def test_symbol_word_boundary_guard
    # A `:` preceded by a word character does not open a symbol.
    out = Carve.to_html("a:b:c and 10:30: and me@example.com")
    refute_includes out, "<span"
    assert_includes out, "a:b:c"
  end

  def test_parse_symbol_node
    node = Carve.parse(":+1:")[:children].first[:children].first
    assert_equal "symbol", node[:type]
    assert_equal "+1", node[:name]
  end

  def test_parse_admonition_title_is_inline_content
    # The admonition title is a list of inline nodes, not a plain string.
    node = Carve.parse(%Q{::: note "Heads *up*"\nBody.\n:::\n})[:children].first
    assert_equal "admonition", node[:type]
    assert_equal "text", node[:title].first[:type]
    assert_equal "emphasis", node[:title].last[:type]
  end


  # --- symbols map -----------------------------------------------------------

  def test_symbols_map_renders_mapped_value
    out = Carve.to_html("Ship it :rocket:", symbols: { "rocket" => "\u{1F680}" })
    assert_includes out, "Ship it \u{1F680}"
    refute_includes out, ":rocket:"
  end

  def test_symbols_map_accepts_symbol_keys_and_composes_with_extensions
    out = Carve.to_html("Ship it :rocket:", extensions: [:autolink], symbols: { rocket: "\u{1F680}" })
    assert_includes out, "\u{1F680}"
  end

  def test_symbols_map_plus_one_is_a_valid_name
    assert_includes Carve.to_html("nice :+1:", symbols: { "+1" => "\u{1F44D}" }), "nice \u{1F44D}"
  end

  def test_unmapped_symbol_stays_literal_with_a_map_active
    out = Carve.to_html(":rocket: and :shrug:", symbols: { "rocket" => "\u{1F680}" })
    assert_includes out, "\u{1F680}"
    assert_includes out, ":shrug:"
  end

  def test_symbols_map_does_not_defeat_the_word_boundary_guard
    # Each of these names WOULD map if the leading word-boundary guard were lost.
    out = Carve.to_html(
      "a:b:c and 10:30: and me@example.com",
      symbols: { "b" => "MAPPED-B", "30" => "MAPPED-30", "example" => "MAPPED-EX" },
    )
    assert_includes out, "a:b:c"
    assert_includes out, "10:30:"
    assert_includes out, "me@example.com"
    refute_includes out, "MAPPED-"
  end

  def test_symbol_value_is_trusted_raw_output_not_escaped
    # Documented contract: a symbol value is inserted RAW into the target format
    # (same trust class as the renderers map), so markup comes through as markup.
    # Never build a symbols map from untrusted input.
    out = Carve.to_html(":bold:", symbols: { "bold" => "<b>x</b>" })
    assert_includes out, "<b>x</b>"
    refute_includes out, "&lt;b&gt;"
  end

  def test_symbols_map_rejects_a_non_string_value
    assert_raises(TypeError) do
      Carve.to_html(":n:", symbols: { "n" => 1 })
    end
  end

  # ---------------------------------------------------------------- safe render

  RAW_HTML_SRC = "# Heading\n\n```=html\n<script>alert(1)</script>\n```\n"

  def test_safe_escapes_a_raw_html_block
    out = Carve.to_html(RAW_HTML_SRC, safe: true)
    assert_includes out, "&lt;script&gt;"
    refute_includes out, "<script>"
  end

  # Pairs with the test above: without it, a change that stopped emitting raw
  # HTML at all would leave that assertion green for the wrong reason.
  def test_raw_html_is_emitted_verbatim_by_default
    out = Carve.to_html(RAW_HTML_SRC)
    assert_includes out, "<script>alert(1)</script>"
  end

  def test_profile_restricts_constructs
    out = Carve.to_html(RAW_HTML_SRC, profile: "comment")
    refute_includes out, "<h1"

    # And the default keeps the heading, so the check above can fail.
    assert_includes Carve.to_html(RAW_HTML_SRC), "<h1"
  end

  def test_profile_accepts_a_symbol
    assert_equal Carve.to_html(RAW_HTML_SRC, profile: "comment"),
                 Carve.to_html(RAW_HTML_SRC, profile: :comment)
  end

  def test_unknown_profile_raises_argument_error
    error = assert_raises(ArgumentError) do
      Carve.to_html("# Hi", profile: "nope")
    end
    assert_includes error.message, "comment"
    assert_includes error.message, "minimal"
  end

  def test_safe_composes_with_extensions
    out = Carve.to_html(RAW_HTML_SRC, safe: true, extensions: [:details])
    assert_includes out, "&lt;script&gt;"
    refute_includes out, "<script>"
  end

  def test_profile_length_cap_raises_instead_of_returning_empty_html
    # The infallible engine entry point returns "" on a profile rejection, which
    # a caller cannot tell from a document that rendered to nothing.
    error = assert_raises(ArgumentError) do
      Carve.to_html("x" * 20_000, profile: :minimal)
    end
    assert_includes error.message, "Profile violations"
  end

  def test_input_under_the_cap_still_renders
    # Makes the check above able to fail rather than passing on any raise.
    assert_includes Carve.to_html("hello", profile: :minimal), "<p>hello</p>"
  end

  # ------------------------------------------------------------- stamp reader

  # The literal bytes carve-php and carve-js write, so a divergence in any
  # writer fails here rather than in the field.
  PHP_MARKER = "# Hi\n\n%% carve-version: 0.1; generated-by: carve-php 0.1.0\n"
  JS_BLOCK_MARKER = "# Hi\n\n%%%\ncarve-version: 0.1\ngenerated-by: carve-js 0.1.0\n%%%\n"

  def test_read_stamp_reads_a_marker_written_by_carve_php
    assert_equal({ version: "0.1", generated_by: "carve-php 0.1.0" }, Carve.read_stamp(PHP_MARKER))
  end

  def test_read_stamp_reads_the_block_form_from_carve_js
    assert_equal({ version: "0.1", generated_by: "carve-js 0.1.0" }, Carve.read_stamp(JS_BLOCK_MARKER))
  end

  def test_read_stamp_returns_nil_for_an_unstamped_document
    assert_nil Carve.read_stamp("# Hi\n\nNo marker.\n")
  end

  def test_read_stamp_does_not_mistake_a_trailing_comment_for_a_marker
    # Keeps "no marker" from quietly meaning "parsing gave up".
    assert_nil Carve.read_stamp("# Hi\n\n%% just a note\n")
  end

  def test_read_stamp_reports_an_unrecorded_writer_as_nil
    assert_equal({ version: "0.1", generated_by: nil }, Carve.read_stamp("# Hi\n\n%% carve-version: 0.1\n"))
  end

  def test_needs_review_for_older_and_unstamped_documents
    assert Carve.needs_review?("a\n\n%% carve-version: 0.0.9; generated-by: x\n")
    # Unknown provenance: assuming a document is current is the unsafe direction.
    assert Carve.needs_review?("a\n")
  end

  def test_needs_review_is_false_for_a_current_document
    refute Carve.needs_review?(PHP_MARKER)
  end

  def test_needs_review_accepts_an_explicit_target_version
    refute Carve.needs_review?("a\n\n%% carve-version: 0.1; generated-by: x\n", "0.1.0")
    assert Carve.needs_review?("a\n\n%% carve-version: 0.9; generated-by: x\n", "0.10")
  end

end

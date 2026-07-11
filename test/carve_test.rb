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

  def test_unknown_renderer_key_raises_argument_error
    assert_raises(ArgumentError) do
      Carve.to_html("# x", mode: :static, renderers: { "no_such" => ->(s) { s } })
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
    assert_equal({}, ast[:frontmatter])
    assert_equal 4, ast[:source_len]
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

  def test_parse_critic_nodes_expose_attrs
    para = Carve.parse("a {+ins+}{.note} b")[:children].first
    ins = para[:children].find { |n| n[:type] == "critic_insert" }
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

end

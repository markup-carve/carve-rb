# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "carve"

class CarveTest < Minitest::Test
  # Absolute path to the carve-rs CLI binary, used for byte-identical checks.
  CARVE_CLI = "/media/mark/data/work/git/carve-rs/target/release/carve"

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
end

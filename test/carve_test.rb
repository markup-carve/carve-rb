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

  def test_unknown_extension_raises_argument_error
    assert_raises(ArgumentError) do
      Carve.to_html("# x", extensions: [:no_such_extension])
    end
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

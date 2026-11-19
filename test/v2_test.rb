# frozen_string_literal: true

require "minitest/autorun"
require "carve"
require "tmpdir"

class CarveV2Test < Minitest::Test
  def test_render_uses_carve2_json_boundary_c2_t_010
    assert_equal "<p>Hi <strong>there</strong></p>", Carve.to_html("Hi *there*")
    assert_equal Carve.to_html("Hi"), Carve.call("render", source: "Hi").fetch("html")
  end

  def test_raw_html_defaults_to_escaped_u_076
    source = "```=html\n<b>trusted</b>\n```\n"
    refute_includes Carve.to_html(source), "<b>trusted</b>"
    assert_includes Carve.to_html(source, raw_html: true), "<b>trusted</b>"
    refute_includes Carve.to_html(source, raw_html: true, safe: true), "<b>trusted</b>"
  end

  def test_parse_and_encode_tree_c2_t_005
    tree = Carve.parse("# Title")
    assert_kind_of Hash, tree
    assert_equal tree, Carve.parse_with_diagnostics("# Title").fetch(:tree)
    json = Carve.call("encodeTree", tree: Carve.call("parse", source: "# Title").fetch("tree")).fetch("json")
    assert_kind_of Hash, Carve.call("decodeTree", json: json).fetch("tree")
  end

  def test_lint_returns_v2_diagnostics_c2_t_020
    assert_kind_of Array, Carve.lint("Text")
    assert_kind_of Array, Carve.call("lint", source: "Text").fetch("diagnostics")
  end

  def test_render_with_diagnostics_c2_t_020
    result = Carve.render_with_diagnostics("Hi")
    assert_equal "<p>Hi</p>", result.fetch(:html)
    assert_kind_of Array, result.fetch(:diagnostics)
  end

  def test_include_resolver_reports_dependencies_c2_t_022
    Dir.mktmpdir("carve-rb-v2-") do |root|
      page = File.join(root, "page.crv")
      File.write(page, "{{ child.crv }}")
      File.write(File.join(root, "child.crv"), "Child text.")
      result = Carve.to_html_with_includes("{{ child.crv }}", root: root, source_path: page)
      assert_includes result.fetch(:value), "Child text."
      assert_equal "child.crv", result.fetch(:dependencies).first.fetch(:path)
    end
  end

  def test_source_writer_is_reserved_carve_rs_4327
    error = assert_raises(Carve::WriterUnavailable) { Carve.to_carve("Hi") }
    assert_match(/carve writer not available yet/, error.message)
    skip "carve-rs#4327: source writer registration pending"
  end

  def test_markdown_plain_and_ansi_writers_are_reserved_carve_rs_4327
    %i[to_markdown to_plain_text to_ansi].each do |name|
      error = assert_raises(Carve::WriterUnavailable) { Carve.public_send(name, "Hi") }
      assert_match(/writer not available yet/, error.message)
    end
    skip "carve-rs#4327: Markdown, plain, and ANSI writer registrations pending"
  end

  def test_html_import_is_reserved_carve_rs_4328
    assert_raises(Carve::EngineError) { Carve.from_html("<p>Hi</p>") }
    skip "carve-rs#4328: HTML importDocument pending"
  end

  def test_extensions_are_reserved_carve_rs_4329
    assert_raises(Carve::ExtensionUnavailable) { Carve.to_html("Hi", extensions: [:math_block]) }
    assert_raises(Carve::ExtensionUnavailable) { Carve.register_extension({}) }
    skip "carve-rs#4329: extension registration pending"
  end
end

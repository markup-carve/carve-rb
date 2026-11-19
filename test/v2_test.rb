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

  def test_url_policy_keeps_the_secure_default_c2_h_082
    assert_equal '<p><a href="">bad</a></p>', Carve.to_html('[bad](javascript:alert(1))')
  end

  def test_render_mode_profile_symbols_and_sections_reach_the_engine_c2_t_005
    assert_equal '<h1 id="Hi">Hi</h1>', Carve.to_html('# Hi', sections: false)
    assert_equal '<p>Ship 🚀</p>', Carve.to_html('Ship :rocket:', symbols: { rocket: '🚀' })
    assert_raises(Carve::EngineError) { Carve.to_html('Hi', profile: :unknown) }
    assert_raises(Carve::EngineError) { Carve.to_html('Hi', symbols: { rocket: 1 }) }
  end

  def test_parse_and_encode_tree_c2_t_005
    tree = Carve.parse("# Title")
    assert_kind_of Hash, tree
    assert_equal tree, Carve.parse_with_diagnostics("# Title").fetch(:tree)
    json = Carve.call("encodeTree", tree: Carve.call("parse", source: "# Title").fetch("tree")).fetch("json")
    assert_kind_of Hash, Carve.call("decodeTree", json: json).fetch("tree")
    assert_equal({}, Carve.call("validateTree", tree: Carve.call("parse", source: "# Title").fetch("tree")))
    refute Carve.parse("# Title", positions: false).fetch(:children).first.key?(:pos)
    refute Carve.parse_with_diagnostics("# Title", positions: false).fetch(:tree)
               .fetch(:children).first.key?(:pos)
  end

  def test_html_target_uses_the_writer_registry_c2_t_005
    assert_equal "<p>Hi</p>", Carve.write("Hi", target: "html")
  end

  def test_lint_returns_v2_diagnostics_c2_t_020
    assert_kind_of Array, Carve.lint("Text")
    assert_kind_of Array, Carve.call("lint", source: "Text").fetch("diagnostics")
    assert_equal "broken-fragment-link", Carve.lint("[x](#missing)").first.fetch(:code)
  end

  def test_invalid_options_preserve_the_c2_t_040_error_fields
    error = assert_raises(Carve::EngineError) { Carve.to_html("Hi", mode: :unknown) }
    assert_equal "CarveOptionError", error.name
    assert_equal "usage", error.category
    assert_equal 2, error.status
  end

  def test_json_boundary_accepts_source_bytes_c2_b_218
    result = Carve.call("render", source_bytes: [72, 105])
    assert_equal "<p>Hi</p>", result.fetch("html")
  end

  def test_markdown_import_is_removed_c2_t_003
    error = assert_raises(ArgumentError) { Carve.from_markdown("*x*") }
    assert_match(/not part of Carve 0.2/, error.message)
  end

  def test_legacy_provenance_and_debug_calls_report_the_02_upgrade_boundary
    assert_raises(ArgumentError) { Carve.read_stamp("Text") }
    assert_raises(ArgumentError) { Carve.needs_review?("Text") }
    assert_raises(ArgumentError) { Carve.decision_trace("Text") }
    assert_raises(Carve::IncludeRegionError) { Carve.select_include_region("Text", "x", mode: :carve) }
  end

  def test_html_import_mode_is_removed_c2_m_008
    error = assert_raises(ArgumentError) { Carve.from_html("<p>x</p>", mode: :raw) }
    assert_match(/modes were removed/, error.message)
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
      tree = Carve.parse_with_includes("{{ child.crv }}", root: root, source_path: page).fetch(:value)
      assert_equal "include", tree.fetch(:children).first.fetch(:type)
    end
  end

  def test_include_byte_budget_reports_a_c2_n_065_diagnostic
    Dir.mktmpdir("carve-rb-v2-") do |root|
      page = File.join(root, "page.crv")
      File.write(page, "{{ child.crv }}")
      File.write(File.join(root, "child.crv"), "Child text.")
      result = Carve.to_html_with_includes("{{ child.crv }}", root: root,
                                           source_path: page, max_bytes: 1)
      assert_includes result.fetch(:warnings).map { |row| row.fetch(:code) }, "include-budget"
      refute_includes result.fetch(:value), "Child text."
    end
  end

  def test_source_writer_is_reserved_carve_rs_4327
    error = assert_raises(Carve::WriterUnavailable) { Carve.to_carve("Hi") }
    assert_match(/carve writer not available yet/, error.message)
    skip "carve-rs#4327: source writer registration pending"
  end

  def test_include_writer_reaches_the_writer_registry_carve_rs_4327
    Dir.mktmpdir("carve-rb-v2-") do |root|
      page = File.join(root, "page.crv")
      File.write(page, "Text")
      error = assert_raises(Carve::WriterUnavailable) do
        Carve.render_with_includes("Text", root: root, source_path: page,
                                   target: "markdown")
      end
      assert_match(/markdown writer not available yet/, error.message)
    end
    skip "carve-rs#4327: include writer targets pending"
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
    assert_raises(Carve::ExtensionUnavailable) do
      Carve.to_html_full("Hi", [:math_block], :static, {})
    end
    assert_raises(Carve::ExtensionUnavailable) { Carve.register_extension({}) }
    skip "carve-rs#4329: extension registration pending"
  end
end

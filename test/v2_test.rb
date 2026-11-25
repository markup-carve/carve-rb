# frozen_string_literal: true

require "minitest/autorun"
require "carve"
require "tmpdir"

class CarveV2Test < Minitest::Test
  def test_render_uses_the_json_boundary_c2_t_010
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

  def test_parse_keeps_symbol_keys_and_engine_errors
    tree = Carve.parse("# Title")
    assert_equal "document", tree.fetch(:type)
    assert_equal "heading", tree.fetch(:children).first.fetch(:type)
    assert_equal "document", Carve.call("parse", source: "# Title").fetch("tree").fetch("type")

    error = assert_raises(Carve::EngineError) { Carve.parse("Hi", unknown_option: true) }
    assert_equal "CarveOptionError", error.name
    assert_equal "usage", error.category
    assert_equal 2, error.status
  end

  def test_default_parse_matches_the_public_tree_for_different_constructs
    sources = [
      "# Title\n\nA /paragraph/ with [link](/path).\n",
      "- one\n- two\n",
      "|= Name |= Qty |\n| Apple | 2 |\n",
      "```ruby\nputs 1\n```\n",
      "> A quote\n> with two lines\n",
      "Text[^note]\n\n[^note]: A note\n"
    ]
    sources.each do |source|
      public_tree = Carve.call("parse", source: source).fetch("tree")
      assert_equal Carve.send(:symbolize, public_tree), Carve.parse(source)
    end
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

  def test_source_writer_c2_w_035
    assert_equal "= Hi\n", Carve.to_carve("# Hi")
    assert_equal "= Hi\n", Carve.call("format", source: "# Hi").fetch("source")
  end

  def test_source_writer_aligns_tables_on_request
    source = "| a | longer |\n| b | c |\n"
    assert_equal source, Carve.to_carve(source)
    assert_equal "| a | longer |\n| b | c      |\n", Carve.to_carve(source, align_tables: true)
  end

  def test_include_writer_returns_markdown
    Dir.mktmpdir("carve-rb-v2-") do |root|
      page = File.join(root, "page.crv")
      File.write(page, "Text")
      result = Carve.render_with_includes("Text", root: root, source_path: page,
                                          target: "markdown")
      assert_equal "Text\n", result.fetch(:value)
      assert_empty result.fetch(:warnings)
    end
  end

  def test_markdown_plain_and_ansi_writers_return_output
    assert_equal "Hi\n", Carve.to_markdown("Hi")
    assert_equal "Hi\n", Carve.to_plain_text("Hi")
    assert_equal "Hi\n", Carve.to_ansi("Hi")
  end

  def test_html_import_c2_t_005
    result = Carve.from_html("<p>Hello <strong>world</strong></p>")
    assert_equal "Hello *world*\n", result.fetch("source")
    assert_equal "document", result.fetch("tree").fetch("type")
    assert_equal [], result.fetch("diagnostics")
  end

  def test_standard_extensions_c2_x_039
    assert_includes Carve::EXTENSIONS, "carve.tabs"
    source = "::: tabs\n::: tab {title=A}\nx\n:::\n:::\n"
    expected = Carve.call("render", source: source,
                          options: { extensions: ["carve.tabs"], renderers: { "carve.tabs" => "standard" } }).fetch("html")
    assert_equal expected, Carve.to_html(source, extensions: ["carve.tabs"], renderers: { "carve.tabs" => :standard })
    assert_equal "<p>Page</p>", Carve.to_html_with_extensions(":wiki[Page]", ["carve.wiki"])
  end

  def test_navigation_extensions_are_listed_and_selectable
    names = %w[carve.autolink carve.externalLinks carve.headingNumbers carve.headingPermalinks carve.headingReference carve.linkPolicy carve.toc carve.tocPlacement]
    names.each do |name|
      assert_includes Carve::EXTENSIONS, name
      assert_equal "<p>Hi</p>", Carve.to_html("Hi", extensions: [name])
    end
  end

  def test_heading_shift_is_a_core_render_option
    # carve#6325 (C2-H-208): headingShift replaced the carve.headingLevelShift extension.
    refute_includes Carve::EXTENSIONS, "carve.headingLevelShift"
    begin
      Carve.to_html("x", heading_shift: 0)
    rescue Carve::EngineError => error
      raise unless error.message.include?("unknown option")
      skip "the pinned engine predates headingShift"
    end
    assert_includes Carve.to_html("= Chapter\n", heading_shift: 1), "<h2"
    assert_includes Carve.to_html("= Chapter\n", headingShift: 2), "<h3"
    assert_equal Carve.to_html("= Chapter\n"), Carve.to_html("= Chapter\n", heading_shift: 0)
    assert_raises(Carve::EngineError) { Carve.to_html("= Chapter\n", heading_shift: 6) }
  end

  def test_every_listed_standard_extension_enables
    Carve::EXTENSIONS.each { |name| Carve.to_html("Hi", extensions: [name]) }
    html = Carve.to_html("::: details\nBody\n:::\n", extensions: ["carve.details"],
                                                     renderers: { "carve.details" => :standard })
    assert_includes html, "<details>"
    assert_raises(Carve::ExtensionUnavailable) do
      Carve.to_html("Hi", extensions: ["carve.mathBlock"], renderers: { "carve.mathBlock" => ->(node) { node } })
    end
  end

  def test_include_parse_reads_the_selected_extensions
    Dir.mktmpdir("carve-rb-v2-") do |root|
      page = File.join(root, "page.crv")
      File.write(page, ":wiki[Page]")
      tree = Carve.parse_with_includes(":wiki[Page]", root: root, source_path: page,
                                       extensions: ["carve.wiki"]).fetch(:value)
      assert_equal "inline_extension", tree.dig(:children, 0, :children, 0, :type)
      assert_equal Carve.parse(":wiki[Page]", extensions: ["carve.wiki"]).fetch(:children), tree.fetch(:children)
    end
  end

  def test_extension_refusals_c2_t_010
    error = assert_raises(Carve::EngineError) { Carve.to_html("Hi", extensions: [:math_block]) }
    assert_equal "CarveOptionError", error.name
    assert_raises(Carve::ExtensionUnavailable) do
      Carve.to_html("Hi", extensions: ["carve.tabs"], renderers: { "carve.tabs" => ->(node) { node } })
    end
    assert_raises(Carve::ExtensionUnavailable) { Carve.register_extension({}) }
    assert_raises(Carve::ExtensionUnavailable) { Carve.lint("Hi", extensions: ["carve.tabs"]) }
  end

  def test_unresolved_include_loss_names_its_file
    Dir.mktmpdir("carve-rb-v2-") do |root|
      page = File.join(root, "page.crv")
      File.write(page, "{{ missing.crv }}")
      result = Carve.to_html_with_includes("{{ missing.crv }}", root: root, source_path: page)
      loss = result.fetch(:warnings).find { |row| row.fetch(:code) == "include-unresolved" }
      assert_equal 'Include "missing.crv" could not be resolved.', loss.fetch(:message)
    end
  end
end

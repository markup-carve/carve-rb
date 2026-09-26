# frozen_string_literal: true

require "minitest/autorun"
require "carve"
require "json"

class LineBlockTabSpansTest < Minitest::Test
  def nodes(value)
    case value
    when Hash then [value] + value.reject { |key, _| key == :pos }.values.flat_map { |child| nodes(child) }
    when Array then value.flat_map { |child| nodes(child) }
    else []
    end
  end

  def test_unchanged_text_beside_tabs_has_exact_source_spans
    ["::: |\na\tb\n:::\n", "> ::: |\n> \t😀 *bold*\n> :::\n"].each do |source|
      all = nodes(Carve.parse(source))
      texts = all.select { |node| node[:type] == "text" }
      refute_empty texts
      texts.each do |node|
        pos = node[:pos]
        refute_nil pos, node[:value]
        assert_equal node[:value], source[pos[:startOffset]...pos[:endOffset]]
      end
      all.select { |node| node[:type] == "non_breaking_space" }.each do |node|
        refute node.key?(:pos)
      end
    end
  end

  def test_merged_text_with_a_tab_generated_space_omits_its_span
    all = nodes(Carve.parse("::: |\ntab\tgap\n:::\n"))
    merged = all.find { |node| node[:type] == "text" && node[:value] == "tab gap" }
    refute_nil merged
    refute merged.key?(:pos)
  end
  def test_a_fence_body_stops_below_its_container_column
    fixture = File.join(__dir__, "fixtures", "engine-parity", "fence-below-content-column")
    expected = JSON.parse(File.read("#{fixture}.json"))
    actual = JSON.parse(Carve._to_ast_json(File.read("#{fixture}.crv")))
    assert_equal expected, actual
  end

end

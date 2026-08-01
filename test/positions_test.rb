# frozen_string_literal: true

require "minitest/autorun"
require "carve"

# PART 12 section 4: every node except the document root carries `pos`.
#
# The engine may gate position TRACKING behind a parse option, but a serialized
# document has to carry the result, so `Carve.parse` turns tracking on. These
# tests hold three things the section is explicit about: the field names, the
# unit (Unicode codepoints, not bytes), and that a span the engine could not
# determine is ABSENT rather than filled with placeholder numbers.
class PositionsTest < Minitest::Test
  FIELDS = %i[startLine endLine startColumn endColumn startOffset endOffset].freeze

  def test_root_has_no_position
    # The root is the one exemption: it spans the whole source by definition,
    # so a span on it tells a consumer nothing it does not already know.
    doc = Carve.parse("# H\n")
    refute doc.key?(:pos), "the document root must not carry a position"
  end

  def test_heading_span_covers_the_marker
    doc = Carve.parse("# Title\n")
    pos = doc[:children][0][:pos]
    refute_nil pos, "a heading at the start of the document must carry a position"
    assert_equal FIELDS.sort, pos.keys.sort
    assert_equal 1, pos[:startLine]
    assert_equal 1, pos[:startColumn]
    assert_equal 0, pos[:startOffset]
    # `endOffset` is exclusive, so it equals the length of "# Title".
    assert_equal 7, pos[:endOffset]
  end

  def test_offsets_are_codepoints_not_bytes
    # The emoji is one codepoint and four bytes. A byte-indexed engine reports
    # the paragraph ending at 19; codepoints put it at 16. This is the exact
    # discriminator PART 12 section 4 uses, and it is invisible on ASCII.
    source = "# H\n\nHello \u{1F600} *b*\n"
    assert_equal 20, source.bytesize
    assert_equal 17, source.length

    paragraph = Carve.parse(source)[:children][1]
    assert_equal 5, paragraph[:pos][:startOffset]
    assert_equal 16, paragraph[:pos][:endOffset]
  end

  def test_span_slices_back_to_the_source
    source = "First para.\n\nSecond para.\n"
    doc = Carve.parse(source)
    doc[:children].each do |node|
      pos = node[:pos]
      next unless pos

      slice = source[pos[:startOffset]...pos[:endOffset]]
      assert_includes slice, node[:children][0][:value]
    end
  end

  def test_nested_blocks_map_back_to_the_document
    # A block parsed from lines with a container prefix removed has to be
    # mapped back through what the container took. Getting this wrong is
    # invisible on line numbers and shows up only in the column.
    source = "> quoted\n"
    quote = Carve.parse(source)[:children][0]
    assert_equal "block_quote", quote[:type]

    paragraph = quote[:children][0]
    refute_nil paragraph[:pos], "a paragraph inside a block quote must carry a position"
    assert_equal 2, paragraph[:pos][:startOffset], "the span must skip the `> ` marker"
    assert_equal "quoted", source[paragraph[:pos][:startOffset]...paragraph[:pos][:endOffset]]
  end

  def test_absent_beats_invented
    # Line-block content carries a private-use sentinel for its indentation, so
    # it is not a verbatim slice of the source and the engine cannot honestly
    # place it. Section 4 requires the field to be OMITTED there rather than
    # filled with zeros, which a consumer would read as "start of document".
    doc = Carve.parse("::: |\n  indented\n:::\n")
    line_block = doc[:children][0]
    assert_equal "line_block", line_block[:type]

    line_block[:children].each do |child|
      next unless child.key?(:pos)

      # If a position IS published it must be a real one, never all zeros.
      refute_equal 0, child[:pos][:endOffset],
                   "a published span must not be a zero-length placeholder"
    end
  end

  def test_no_node_publishes_a_zero_length_span
    # A span whose end equals its start is the shape a placeholder takes. No
    # node in a document this ordinary should have one.
    source = "# H\n\ntext\n\n- a\n- b\n\n> q\n\n```\ncode\n```\n"
    zero_length = []
    walk(Carve.parse(source)) do |node|
      pos = node[:pos]
      next unless pos

      zero_length << node[:type] if pos[:startOffset] == pos[:endOffset]
    end
    assert_empty zero_length, "these node types published an empty span"
  end

  private

  def walk(node, &block)
    return unless node.is_a?(Hash)

    yield node if node[:type] && node[:type] != "document"
    node.each_value do |value|
      case value
      when Hash then walk(value, &block)
      when Array then value.each { |v| walk(v, &block) }
      end
    end
  end
end

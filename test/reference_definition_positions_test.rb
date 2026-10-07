# frozen_string_literal: true

require "minitest/autorun"
require "carve"

# A reference definition's span points into the input the caller passed.
#
# `Carve.parse` is the only entry point that serializes positions, so it is the
# only one where this is observable. carve-lang 0.1.8 publishes the span in the
# ORIGINAL input, where 0.1.7 published it in a buffer the engine had already
# normalized (markup-carve/carve-rs#2239). Measured across the two pins on a
# document whose only difference is a leading BOM:
#
#   0.1.7   startOffset 0, startColumn 1
#   0.1.8   startOffset 1, startColumn 2
#
# One is right and one is wrong for a caller doing anything with the span. An
# editor highlighting the definition, or a host slicing the source to quote it,
# reads offset 0 under 0.1.7 and lands on the BOM rather than on the `[`.
#
# The three shapes are asserted together because the delta is a RELATIONSHIP
# between them, not a single number: the plain document is the reference, the
# BOM document must be shifted by exactly the BOM, and the CRLF document must
# not be shifted at all. Pinning only the BOM case would pass an engine that had
# started shifting every document.
class ReferenceDefinitionPositionsTest < Minitest::Test
  PLAIN = "[a]: /x\n\nSee [a].\n"
  WITH_BOM = "﻿[a]: /x\n\nSee [a].\n"
  WITH_CRLF = "[a]: /x\r\n\r\nSee [a].\r\n"

  def definition_span(source)
    found = []
    walk = lambda do |node|
      case node
      when Hash
        found << node[:pos] if node[:type] == "link_reference_definition"
        node.each_value { |value| walk.call(value) }
      when Array
        node.each { |value| walk.call(value) }
      end
    end
    walk.call(Carve.parse(source))

    refute_empty found, "no link_reference_definition in the tree for #{source.inspect}"
    found.first
  end

  def test_a_plain_document_starts_at_the_first_byte
    span = definition_span(PLAIN)

    assert_equal 0, span[:startOffset]
    assert_equal 1, span[:startColumn]
    assert_equal 7, span[:endOffset]
  end

  # The BOM is one character of the input the caller passed, so the definition
  # that follows it starts one past the start, not at it.
  def test_a_leading_bom_shifts_the_span_by_the_bom
    plain = definition_span(PLAIN)
    bom = definition_span(WITH_BOM)

    assert_equal 1, bom[:startOffset],
                 "the definition after a BOM must not report the BOM's own offset"
    assert_equal 2, bom[:startColumn]
    assert_equal plain[:endOffset] + 1, bom[:endOffset]
    assert_equal plain[:startLine], bom[:startLine]
  end

  # A CRLF line ending is two bytes, but neither of them precedes the first
  # definition, so nothing moves.
  def test_crlf_line_endings_do_not_shift_the_span
    assert_equal definition_span(PLAIN), definition_span(WITH_CRLF)
  end
end

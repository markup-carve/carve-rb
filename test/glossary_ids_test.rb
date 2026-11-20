# frozen_string_literal: true

require "minitest/autorun"
require "carve"

# Glossary ids preserve case, and a reference matches its term exactly.
#
# carve-lang 0.1.8 made this lookup exact (markup-carve/carve-rs#2325, #2327,
# markup-carve/carve#2739). The old behavior was not merely case-insensitive, it
# LOST an entry: measured on the 0.1.7 pin this gem shipped at v0.1.6, the two
# terms `API` and `api` rendered as
#
#   <dt id="gloss-api">API</dt>   <!-- the id downcased the term -->
#   <dt>api</dt>                  <!-- and the second got NO id at all -->
#
# so one of two authored terms became unlinkable with nothing saying so. Under
# 0.1.8 each term keeps its own case-preserving id.
#
# The ids are the assertion rather than the prose, because the ids are what a
# link target and a reference resolve against; the visible text was already
# correct under both engines, which is why nothing here noticed.
class GlossaryIdsTest < Minitest::Test
  TWO_CASES = <<~CARVE
    ::: glossary
    :: API
    : an interface

    :: api
    : lowercase
    :::

    See API and api.
  CARVE

  def test_two_terms_differing_only_in_case_take_two_ids
    html = Carve.to_html(TWO_CASES, extensions: [:glossary])

    assert_includes html, "<dt id=\"gloss-API\">API</dt>"
    assert_includes html, "<dt id=\"gloss-api\">api</dt>"
  end

  # The regression this guards is a MISSING id, so count them. Asserting only
  # the two spellings above would still pass an engine that emitted one of them
  # twice, and an engine that dropped an id emits a bare `<dt>` which neither
  # `assert_includes` can see.
  def test_every_term_carries_an_id
    html = Carve.to_html(TWO_CASES, extensions: [:glossary])
    terms = html.scan(/<dt\b[^>]*>/)

    assert_equal 2, terms.length, "expected two terms, got #{terms.inspect}"
    terms.each do |tag|
      assert_match(/\sid="/, tag, "a glossary term rendered without an id: #{tag}")
    end
  end

  def test_the_term_ids_are_distinct
    html = Carve.to_html(TWO_CASES, extensions: [:glossary])
    ids = html.scan(/<dt\b[^>]*\sid="([^"]+)"/).flatten

    assert_equal ids.uniq, ids, "two glossary terms share an id: #{ids.inspect}"
    assert_equal %w[gloss-API gloss-api], ids
  end
end

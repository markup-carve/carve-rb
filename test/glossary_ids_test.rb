# frozen_string_literal: true

require "minitest/autorun"
require "carve"

# C2-X-039 does not register the 0.1 glossary renderer. The core definition
# list still keeps separate terms whose spelling differs only by case.
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

  def test_core_terms_differing_only_in_case_stay_distinct
    html = Carve.to_html(TWO_CASES)
    assert_includes html, "<dt>API</dt>"
    assert_includes html, "<dt>api</dt>"
  end

  # Both terms remain visible without the retired glossary renderer.
  def test_core_terms_stay_present_without_retired_glossary
    html = Carve.to_html(TWO_CASES)
    assert_equal 2, html.scan(/<dt>/).length
    assert_raises(Carve::EngineError) { Carve.to_html(TWO_CASES, extensions: [:glossary]) }
  end

  def test_core_term_texts_are_distinct
    html = Carve.to_html(TWO_CASES)
    assert_equal %w[API api], html.scan(/<dt>([^<]+)<\/dt>/).flatten
  end
end

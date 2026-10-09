# frozen_string_literal: true

require "minitest/autorun"
require "corpus_population"

# The counter's own test, because the corpus can no longer be its test.
#
# The population gates used to count one pair per `::: compare` block, while the
# spec's generator writes one pair per `carve` fence inside the block. The gap
# only showed on a multi-pair block, and markup-carve/carve#2825 split the one
# block upstream that had it, so a corpus run cannot demonstrate the difference
# any more. A synthetic page can.
class CorpusPopulationTest < Minitest::Test
  PAGE = [
    "::: compare",
    "```carve", "one", "```",
    "```html", "<p>one</p>", "```",
    "````carve", "```carve", "nested, not a pair", "```", "````",
    "```html", "<pre>two</pre>", "```",
    "```carve", "three", "```",
    "```html", "<p>three</p>", "```",
    ":::",
    "```carve", "outside any block", "```",
  ].freeze

  def census
    CorpusPopulation.census_compare_pairs(PAGE)
  end

  def test_counts_every_carve_fence_in_a_block_as_a_pair
    pairs = census.sum { |block| block["carve"] }
    assert_equal 3, pairs, "got #{pairs} pairs, want 3"
  end

  def test_reports_one_block_with_matching_html_fences
    blocks = census
    assert_equal 1, blocks.length
    assert_equal 3, blocks.first["html"]
    assert_nil blocks.first[:unclosed]
    assert_nil blocks.first[:unclosed_fence]
  end

  def test_an_unclosed_block_is_reported_rather_than_counted_silently
    blocks = CorpusPopulation.census_compare_pairs(["::: compare", "```carve", "x", "```"])
    assert_equal true, blocks.first[:unclosed]
  end
end

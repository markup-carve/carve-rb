# frozen_string_literal: true

require "minitest/autorun"
require "corpus_population"
require "tmpdir"
require "fileutils"

# The counter's own test, because the corpus can no longer be its test.
#
# The population gates used to count one pair per `::: compare` block, while the
# spec's generator writes one pair per `carve` fence inside the block. The gap
# only showed on a multi-pair block, and markup-carve/carve#2825 split the one
# block upstream that had it, so a corpus run cannot demonstrate the difference
# any more. A synthetic page can.
class CorpusPopulationTest < Minitest::Test
  include CorpusPopulation

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

  PAIR = ["::: compare", "```carve", "x", "```", "```html", "<p>x</p>", "```", ":::"].freeze

  def example_tree(root)
    examples = File.join(root, "resources", "examples")
    FileUtils.mkdir_p(File.join(examples, "edge-cases"))
    File.write(File.join(examples, "core.md"), PAIR.join("\n"))
    File.write(File.join(examples, "extensions.md"), PAIR.join("\n"))
    examples
  end

  def test_edge_case_sections_in_their_own_files
    Dir.mktmpdir do |root|
      sections = File.join(example_tree(root), "edge-cases")
      File.write(File.join(sections, "0049-b.md"), (["## B", ""] + PAIR).join("\n"))
      File.write(File.join(sections, "0048-a.md"), (["---", "page: tables", "---", "", "## A", ""] + PAIR + PAIR).join("\n"))
      File.write(File.join(sections, "README.md"), PAIR.join("\n"))
      pages = CorpusPopulation.example_pages(File.join(root, "resources", "examples"))
      assert_equal %w[core.md extensions.md 0048-a.md 0049-b.md], pages.map { |path| File.basename(path) }
      assert_equal 5, declared_corpus_size(File.join(root, "tests", "corpus"))
    end
  end

  def test_the_single_edge_case_page_wins_when_it_exists
    Dir.mktmpdir do |root|
      examples = example_tree(root)
      File.write(File.join(examples, "edge-cases.md"), PAIR.join("\n"))
      assert_equal "edge-cases.md", File.basename(CorpusPopulation.example_pages(examples).last)
    end
  end

  def test_an_empty_section_directory_is_refused
    Dir.mktmpdir do |root|
      assert_raises(RuntimeError) { CorpusPopulation.example_pages(example_tree(root)) }
    end
  end

  def test_front_matter_is_not_section_content
    assert_equal ["## A"], CorpusPopulation.section_body("---\npage: x\n---\n## A")
    assert_equal ["---", "x"], CorpusPopulation.section_body("---\nx")
  end
end

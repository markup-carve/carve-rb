# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "corpus_population"

class CorpusPopulationTest < Minitest::Test
  include CorpusPopulation

  SOURCE = "````text\n::: compare\n```carve\nfake\n```\n```html\nfake\n```\n:::\n````\n::: compare no-render\n````carve\n::: compare\n```html\nliteral\n```\n:::\n````\n```html\n<p>first</p>\n```\n```carve\nsecond\n```\n```html\n<p>second</p>\n```\n:::\n"

  def with_source(source)
    Dir.mktmpdir do |root|
      examples = File.join(root, "resources", "examples")
      FileUtils.mkdir_p(examples)
      EXAMPLE_PAGES.each_with_index do |page, index|
        File.write(File.join(examples, page), index.zero? ? source : "")
      end
      yield File.join(root, "tests", "corpus")
    end
  end

  def test_multiple_pairs_and_literal_fences
    with_source(SOURCE) do |corpus|
      assert_equal 2, declared_corpus_size(corpus)
      assert_whole_corpus(corpus, 2, "complete")
      assert_raises(Minitest::Assertion) { assert_whole_corpus(corpus, 1, "truncated") }
    end
  end

  def test_unpaired_and_unclosed_sources_are_refused
    ["::: compare\n```carve\nx\n```\n:::\n", "::: compare\n:::\n", SOURCE.sub(/:::\n\z/, "")].each do |source|
      with_source(source) do |corpus|
        assert_raises(Minitest::Assertion) { declared_corpus_size(corpus) }
      end
    end
  end
end

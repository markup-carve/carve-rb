# frozen_string_literal: true

require "minitest/autorun"
require "corpus_population"
require "tmpdir"
require "fileutils"

# The spec's generator writes one corpus pair per distinct input
# (markup-carve/carve#5244); a generator from before it wrote every authored pair.
class CorpusPopulationDedupTest < Minitest::Test
  include CorpusPopulation

  def pair(input, opener = "::: compare")
    [opener, "```carve", input, "```", "```html", "<p>#{input}</p>", "```", ":::"]
  end

  def tree(root, pages)
    examples = File.join(root, "resources", "examples")
    FileUtils.mkdir_p(examples)
    File.write(File.join(examples, "core.md"), pages[0].join("\n"))
    File.write(File.join(examples, "extensions.md"), pages[1].join("\n"))
    File.write(File.join(examples, "edge-cases.md"), pages[2].join("\n"))
    corpus = File.join(root, "tests", "corpus")
    FileUtils.mkdir_p(corpus)
    corpus
  end

  def write_corpus(corpus, inputs)
    inputs.each_with_index { |bytes, i| File.binwrite(File.join(corpus, "#{i}.crv"), bytes) }
  end

  # x twice across pages, and x again under crlf, which is a different input.
  def pages
    [pair("x"), pair("x") + pair("y"), pair("x", "::: compare crlf")]
  end

  def test_a_deduplicated_corpus_expects_one_pair_per_distinct_input
    Dir.mktmpdir do |root|
      corpus = tree(root, pages)
      write_corpus(corpus, ["x\n", "y\n", "x\r\n"])
      assert_equal 4, declared_corpus_size(corpus)
      assert_equal 3, expected_corpus_size(corpus)
      assert_whole_corpus(corpus, 3, "pairs")
    end
  end

  def test_a_corpus_holding_duplicates_expects_every_authored_pair
    Dir.mktmpdir do |root|
      corpus = tree(root, pages)
      write_corpus(corpus, ["x\n", "x\n", "y\n", "x\r\n"])
      assert_equal 4, expected_corpus_size(corpus)
    end
  end

  def test_a_cut_deduplicated_corpus_still_fails
    Dir.mktmpdir do |root|
      corpus = tree(root, pages)
      write_corpus(corpus, ["x\n", "y\n"])
      assert_raises(Minitest::Assertion) { assert_whole_corpus(corpus, 2, "pairs") }
    end
  end

  def test_an_empty_corpus_still_fails
    Dir.mktmpdir do |root|
      corpus = tree(root, pages)
      assert_raises(Minitest::Assertion) { assert_whole_corpus(corpus, 0, "pairs") }
    end
  end

  def test_modifiers_transform_the_input_in_the_generators_order
    assert_equal "﻿a\r\nb".b, CorpusPopulation.input_bytes(%w[a b], %w[no-final-newline crlf bom])
    assert_equal "a\u0000\r".b, CorpusPopulation.input_bytes(["a␀"], %w[cr nul])
  end
end

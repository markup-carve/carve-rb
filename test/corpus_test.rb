# frozen_string_literal: true

# The mandatory spec corpus, run through this gem.
#
# Every implementation is held to byte-identical HTML for these inputs. This gem
# builds carve-rs from a pinned revision, so it cannot ship a stale prebuilt
# artifact -- but it can sit on a pin whose output no longer matches the spec,
# and the rest of the suite asserts hand-written expectations that a drifted
# engine satisfies happily. The CI workflow records what that already cost once:
# the pin sat months behind, past two breaking AST changes, with CI green.
#
# The corpus path comes from CARVE_SPEC_CORPUS. Unset, these tests skip, so a
# plain `rake test` works in a checkout without the spec repo. CI checks the spec
# out and sets it.

require "minitest/autorun"
require "carve"
require "corpus_population"

class CorpusTest < Minitest::Test
  include CorpusPopulation

  CORPUS = ENV.fetch("CARVE_SPEC_CORPUS", nil)

  def pairs
    Dir.glob(File.join(CORPUS, "*.crv")).sort.filter_map do |crv|
      html = crv.sub(/\.crv\z/, ".html")
      [crv, html] if File.exist?(html)
    end
  end

  def test_corpus_is_actually_present
    skip "CARVE_SPEC_CORPUS not set (see .github/workflows/ci.yml)" unless CORPUS

    assert File.directory?(CORPUS), "CARVE_SPEC_CORPUS=#{CORPUS} is not a directory"
    # Equality against what the spec declares, not a floor. `>= 400` against a
    # corpus of over a thousand passed with two thirds of it missing, which is
    # the condition this test exists to reject; see test/corpus_population.rb.
    assert_whole_corpus(CORPUS, pairs.length, "corpus pairs found")
  end

  def test_corpus_renders_byte_identically
    skip "CARVE_SPEC_CORPUS not set (see .github/workflows/ci.yml)" unless CORPUS

    all = pairs
    mismatches = all.reject do |crv, html|
      want = File.read(html).sub(/\n+\z/, "")
      got = Carve.to_html(File.read(crv)).sub(/\n+\z/, "")
      got == want
    end.map { |crv, _| File.basename(crv, ".crv") }

    assert_empty mismatches,
                 "#{mismatches.length} of #{all.length} corpus cases diverge from the spec: " \
                 "#{mismatches.first(20).join(', ')}#{mismatches.length > 20 ? ' ...' : ''}. " \
                 "The carve-rs rev in ext/carve/Cargo.toml is probably behind; bump it and " \
                 "commit the regenerated ext/carve/Cargo.lock."
  end
end

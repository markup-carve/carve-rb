# frozen_string_literal: true

# Every node type the corpus is known to exercise still reaches the tree.
#
# `corpus_test.rb` compares `Carve.to_html` against the `.html` fixtures, and
# that is the only corpus-driven check this gem had. It cannot see an AST-only
# change, because a node that renders nothing renders nothing in both engines:
# the carve-rs pin sat 44 commits behind, past the commit that gives a
# definition its own node (PART 12 §10), and every corpus pair still matched
# byte for byte (#46, #47).
#
# WHY A TYPE SET RATHER THAN A PER-DOCUMENT ASSERTION. The obvious check - a
# document with a definition line must produce a `link_reference_definition` -
# does not survive contact with the corpus: 64 documents have that source shape
# and 36 legitimately produce no such node, because `[^f]: note` is the same
# shape and because several documents exist precisely to pin that a
# definition-shaped line is NOT a definition. Modelling that needs an allowlist
# of exactly the documents whose rules the check cannot model, which is a check
# whose exceptions are the behavior.
#
# The type set has no such problem. A pin that drops a node type drops it from
# ALL 655 documents at once, so the whole corpus answers with one fact and no
# per-document reasoning.
#
# THE ASSERTION IS ONE-DIRECTIONAL ON PURPOSE. A type going missing fails; a
# NEW type appearing does not. New constructs arrive with corpus growth and
# should not fail a gem that parses them correctly - and the drift this exists
# to catch only ever subtracts.

require "minitest/autorun"
require "carve"
require "set"

class CorpusAstTypesTest < Minitest::Test
  CORPUS = ENV.fetch("CARVE_SPEC_CORPUS", nil)

  # Recorded by walking every corpus document through this gem. Kept as an
  # explicit list rather than a count: a count says "something went missing"
  # and this says which.
  EXPECTED = %w[
    abbreviation abbreviation_def admonition autolink block_quote caption_number
    code code_block comment critic_comment definition_description definition_list
    definition_term delete div document emphasis escaped_text figure footnote
    footnote_ref frontmatter hard_break heading heading_ref highlight image
    inline_extension inline_footnote insert line_block link
    link_reference_definition list list_item literal_inline math mention
    paragraph raw_block raw_inline smart_punctuation soft_break span strike
    strong subscript substitution superscript symbol table table_cell table_row
    tag text thematic_break underline
  ].freeze

  def corpus_files
    Dir.glob(File.join(CORPUS, "*.crv")).sort
  end

  def types_produced
    seen = Set.new
    walk = lambda do |node|
      case node
      when Hash
        seen << node[:type] if node[:type]
        node.each_value { |v| walk.call(v) }
      when Array
        node.each { |v| walk.call(v) }
      end
    end
    corpus_files.each { |f| walk.call(Carve.parse(File.read(f))) }
    seen
  end

  def test_the_corpus_is_actually_walked
    skip "CARVE_SPEC_CORPUS not set (see .github/workflows/ci.yml)" unless CORPUS

    # Without this an empty or mistyped directory produces an empty set, every
    # `assert_includes` below is vacuous, and the run reads as clean - the same
    # failure shape this file exists to remove.
    found = corpus_files.length
    assert_operator found, :>=, 400,
                    "only #{found} corpus documents under #{CORPUS}; the corpus has ~650, " \
                    "so this is a wiring problem, not a clean run"
  end

  def test_every_recorded_node_type_still_reaches_the_tree
    skip "CARVE_SPEC_CORPUS not set (see .github/workflows/ci.yml)" unless CORPUS

    produced = types_produced
    missing = EXPECTED.reject { |type| produced.include?(type) }

    assert_empty missing,
                 "#{missing.length} node type(s) the corpus used to produce are gone: " \
                 "#{missing.join(', ')}. The carve-rs rev in ext/carve/Cargo.toml is " \
                 "probably behind a change that renamed or removed them; bump it and " \
                 "commit the regenerated ext/carve/Cargo.lock. If a type was removed " \
                 "from the language on purpose, delete it from EXPECTED in the same commit."
  end

  def test_a_new_node_type_is_reported_without_failing
    skip "CARVE_SPEC_CORPUS not set (see .github/workflows/ci.yml)" unless CORPUS

    # Not a failure - see the header. But an unrecorded type is worth seeing,
    # because it usually means the corpus grew a construct and EXPECTED should
    # grow with it.
    extra = types_produced.to_a - EXPECTED
    unless extra.empty?
      warn "corpus produces #{extra.length} node type(s) not in EXPECTED: #{extra.sort.join(', ')}"
    end
    pass
  end
end

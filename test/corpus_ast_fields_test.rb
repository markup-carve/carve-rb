# frozen_string_literal: true

# Every FIELD name the corpus is known to produce still reaches the tree.
#
# `corpus_ast_types_test.rb` states the case for a ledger at length and records
# node TYPES. This is the same ledger one level down, because a type is only
# half of what a tree carries: a pin behind a change that adds, renames or drops
# a field ON an existing node leaves the type where it was, and the type ledger
# is satisfied.
#
# `corpus_test.rb` does not close that gap either. It compares HTML, and a field
# can have no rendering at all. `thematic_break.marker` is the shortest
# demonstration in the language: `---` and `***` are different documents that a
# writer has to reproduce, they differ in the tree by that one field, and both
# render `<hr>`. `document.srcByteLength` and `strong.boldItalic` are the same
# shape of name. A pin that stopped emitting any of them would keep every one of
# the 1053 corpus pairs byte-identical.
#
# The gap has a live example rather than only a hypothetical one. The delimited
# inline comment (PART 9 §21a) is a `comment` node like the trailing `%%` form,
# told apart by a `delimited` field, and the schema marks that field optional -
# so the type ledger, the HTML corpus and a shape check against the schema all
# pass on a tree that never carries it. Its rendering happens to differ too, so
# `corpus_test.rb` caught this one; the next such field need not be so kind.
#
# WHY A `type.field` SET. A bare set of names would let `delimited` reaching ANY
# node stand in for it reaching `comment`. Pairing the two costs nothing and
# says which node lost the name.
#
# `pos` is excluded: it is on every node, it would be 60 entries of noise, and
# `positions_test.rb` already asserts it.
#
# ONE-DIRECTIONAL, for the reason `corpus_ast_types_test.rb` gives at length: a
# name going missing fails, a NEW name only warns. New fields arrive with the
# language and should not fail a gem that parses them correctly, and a pin left
# behind only ever subtracts.

require "minitest/autorun"
require "carve"
require "set"

class CorpusAstFieldsTest < Minitest::Test
  CORPUS = ENV.fetch("CARVE_SPEC_CORPUS", nil)

  # Recorded by walking every corpus document through this gem. An explicit
  # list rather than a count, so a failure names the field instead of saying
  # that some number of them went away.
  EXPECTED = %w[
    abbreviation.abbr abbreviation.expansion abbreviation_def.abbr
    abbreviation_def.expansion admonition.attrs admonition.children
    admonition.kind admonition.label admonition.title autolink.attrs
    autolink.href autolink.text block_quote.attrs block_quote.children
    caption_number.n code.attrs code.value code_block.attrs code_block.content
    code_block.header code_block.label code_block.lang comment.block
    comment.content comment.delimited critic_comment.text
    definition_description.children definition_list.items
    definition_term.children delete.children div.attrs div.children div.label
    document.children document.srcByteLength emphasis.children escaped_text.value
    figure.attrs figure.caption figure.target figure_group.attrs
    figure_group.caption figure_group.children footnote.children footnote.label
    footnote_ref.attrs footnote_ref.id footnote_ref.number frontmatter.content
    frontmatter.format heading.attrs heading.children heading.level
    heading_ref.href heading_ref.target highlight.children image.alt image.attrs
    image.rawRef image.ref image.src image.title inline_extension.attrs
    inline_extension.content inline_extension.name inline_footnote.attrs
    inline_footnote.inline inline_footnote.number insert.attrs insert.children
    line_block.children link.attrs link.children link.href link.rawRef link.ref
    link.title link_reference_definition.attrs link_reference_definition.href
    link_reference_definition.label link_reference_definition.title list.attrs
    list.bareMarker list.bulletChar list.delim list.items list.olType
    list.ordered list.start list.tight list_item.attrs list_item.checked
    list_item.children literal_inline.attrs literal_inline.content math.attrs
    math.content math.display mention.user paragraph.attrs paragraph.children
    raw_block.content raw_block.format raw_inline.content raw_inline.format
    smart_punctuation.glyph smart_punctuation.kind smart_punctuation.value
    span.attrs span.children strike.children strong.attrs strong.boldItalic
    strong.children subscript.children substitution.newText substitution.oldText
    superscript.children symbol.attrs symbol.name table.attrs table.caption
    table.rows table_cell.align table_cell.attrs table_cell.children
    table_cell.header table_cell.span table_row.attrs table_row.cells tag.name
    text.value thematic_break.marker underline.children
  ].freeze

  # On every node, and asserted by `positions_test.rb` already.
  IGNORED_KEYS = %i[type pos].freeze

  def corpus_files
    Dir.glob(File.join(CORPUS, "*.crv")).sort
  end

  def fields_produced
    seen = Set.new
    walk = lambda do |node|
      case node
      when Hash
        if node[:type]
          node.each_key { |key| seen << "#{node[:type]}.#{key}" unless IGNORED_KEYS.include?(key) }
        end
        node.each_value { |value| walk.call(value) }
      when Array
        node.each { |value| walk.call(value) }
      end
    end
    corpus_files.each { |file| walk.call(Carve.parse(File.read(file))) }
    seen
  end

  def test_the_corpus_is_actually_walked
    skip "CARVE_SPEC_CORPUS not set (see .github/workflows/ci.yml)" unless CORPUS

    # Without this an empty or mistyped directory produces an empty set, the
    # assertion below reads as clean, and the check joins the ones it replaces.
    found = corpus_files.length
    assert_operator found, :>=, 400,
                    "only #{found} corpus documents under #{CORPUS}; the corpus has ~1000, " \
                    "so this is a wiring problem, not a clean run"
  end

  def test_every_recorded_field_name_still_reaches_the_tree
    skip "CARVE_SPEC_CORPUS not set (see .github/workflows/ci.yml)" unless CORPUS

    produced = fields_produced
    missing = EXPECTED.reject { |field| produced.include?(field) }

    assert_empty missing,
                 "#{missing.length} field name(s) the corpus used to produce are gone: " \
                 "#{missing.join(', ')}. The carve-rs rev in ext/carve/Cargo.toml is " \
                 "probably behind a change that added or renamed them; bump it and commit " \
                 "the regenerated ext/carve/Cargo.lock. If a field left the language on " \
                 "purpose, delete it from EXPECTED in the same commit."
  end

  def test_a_new_field_name_is_reported_without_failing
    skip "CARVE_SPEC_CORPUS not set (see .github/workflows/ci.yml)" unless CORPUS

    extra = fields_produced.to_a - EXPECTED
    unless extra.empty?
      warn "corpus produces #{extra.length} field name(s) not in EXPECTED: #{extra.sort.join(', ')}"
    end
    pass
  end
end

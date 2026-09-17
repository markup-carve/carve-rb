# frozen_string_literal: true

# Every node this gem produces uses field names the spec's schema names.
#
# The other two corpus checks answer different questions and neither covers
# this one:
#
#   corpus_test.rb            does the HTML match? blind to anything the
#                             renderer drops, which is how an AST-only drift
#                             got through (#46, #47)
#   corpus_ast_types_test.rb  is every node TYPE still produced? blind to a
#                             type that is still produced under a renamed or
#                             extra FIELD
#
# This one reads `resources/ast-schema.json` from the spec checkout and asserts
# two of its constraints against every node the corpus produces: no property
# outside the type's `properties` where the schema sets
# `additionalProperties: false`, and every name in `required` present.
#
# WHAT IT IS NOT. It is not JSON Schema validation. It checks two keywords and
# ignores the rest - types, enums, formats, conditionals - because a real
# validator would be a new dependency for a native gem and draft-2020-12
# support in Ruby is uneven. The two it checks are the ones a drifted engine
# actually trips: a field renamed on one side of the binding, or one that
# stopped being emitted.
#
# NO HISTORICAL DRIFT IN REACH EXERCISES IT. The pin this gem shipped on before
# #46 - 44 commits back - produces zero findings here, because what it dropped
# was a whole node TYPE, which is the other test's job. So the ablation below is
# a mutated schema rather than an old pin, and this check is a guard against a
# class that has happened in this fleet (the CHANGELOG records `label` becoming
# `id` on a footnote reference) rather than one it has caught.

require "minitest/autorun"
require "carve"
require "json"
require "corpus_population"

class CorpusAstSchemaShapeTest < Minitest::Test
  include CorpusPopulation

  CORPUS = ENV.fetch("CARVE_SPEC_CORPUS", nil)
  # Defaults beside the corpus, so CI needs no second variable: the corpus lives
  # at <spec>/tests/corpus and the schema at <spec>/resources/ast-schema.json.
  SCHEMA = ENV.fetch("CARVE_SPEC_SCHEMA") do
    CORPUS ? File.expand_path("../../resources/ast-schema.json", CORPUS) : nil
  end

  def defs
    @defs ||= JSON.parse(File.read(SCHEMA)).fetch("$defs")
  end

  # Every `{type: ...}` hash in the tree, depth first.
  def each_node(node, &block)
    case node
    when Hash
      block.call(node) if node[:type]
      node.each_value { |v| each_node(v, &block) }
    when Array
      node.each { |v| each_node(v, &block) }
    end
  end

  def corpus_files
    Dir.glob(File.join(CORPUS, "*.crv")).sort
  end

  def findings
    found = Hash.new(0)
    corpus_files.each do |file|
      each_node(Carve.parse(File.read(file))) do |node|
        type = node[:type].to_s
        schema = defs[type]
        if schema.nil?
          found["#{type}: no $defs entry in the schema"] += 1
          next
        end
        properties = schema["properties"] or next
        if schema["additionalProperties"] == false
          node.each_key do |key|
            found["#{type}.#{key}: not a property the schema names"] += 1 unless properties.key?(key.to_s)
          end
        end
        Array(schema["required"]).each do |name|
          found["#{type}: required property #{name} is missing"] += 1 unless node.key?(name.to_sym)
        end
      end
    end
    found
  end

  def test_the_schema_is_actually_read
    skip "CARVE_SPEC_CORPUS not set (see .github/workflows/ci.yml)" unless CORPUS

    # Without this, a missing or moved schema file would make `defs` empty,
    # every node would take the `next` above, and the sweep would report a clean
    # run having checked nothing.
    assert File.exist?(SCHEMA), "no schema at #{SCHEMA}; set CARVE_SPEC_SCHEMA"
    assert_operator defs.length, :>=, 40,
                    "the schema has only #{defs.length} type definitions, which is too few to be " \
                    "the spec's - check CARVE_SPEC_SCHEMA"
  end

  def test_the_corpus_is_actually_walked
    skip "CARVE_SPEC_CORPUS not set (see .github/workflows/ci.yml)" unless CORPUS

    # The schema half of this file already refuses to run against a schema that
    # is not there. The corpus half had no equivalent: an empty, truncated or
    # mistyped CARVE_SPEC_CORPUS makes the glob return fewer files (or none),
    # every assertion below still passes, and the run reports that the AST shape
    # was verified across a corpus it never read. The stronger the assertions in
    # the loop, the more convincing that empty green looks.
    #
    # Equality against what the spec's example pages DECLARE, not a floor and
    # not a count taken from the corpus directory itself; see
    # test/corpus_population.rb for why both of those guard nothing.
    assert_whole_corpus(CORPUS, corpus_files.length, "corpus documents walked")
  end

  def test_every_node_uses_field_names_the_schema_names
    skip "CARVE_SPEC_CORPUS not set (see .github/workflows/ci.yml)" unless CORPUS

    problems = findings
    assert_empty problems.keys,
                 "#{problems.values.sum} node(s) do not match the schema's field names: " \
                 "#{problems.sort_by { |_, n| -n }.first(10).map { |k, n| "#{n}x #{k}" }.join('; ')}. " \
                 "The carve-rs rev in ext/carve/Cargo.toml is probably behind a rename; bump it " \
                 "and commit the regenerated ext/carve/Cargo.lock. If the spec renamed the field " \
                 "on purpose, this gem's pin has to move with it."
  end

  def test_the_check_can_fail
    skip "CARVE_SPEC_CORPUS not set (see .github/workflows/ci.yml)" unless CORPUS

    # The ablation, in the test rather than in a commit message: rename a
    # property the corpus certainly produces and confirm the sweep reports it.
    # Without this the two assertions above pass identically whether the schema
    # is being read or quietly ignored.
    original = defs["text"]["properties"]
    begin
      defs["text"]["properties"] = original.reject { |k, _| k == "value" }
      assert_includes findings.keys, "text.value: not a property the schema names"
    ensure
      defs["text"]["properties"] = original
    end
  end
end

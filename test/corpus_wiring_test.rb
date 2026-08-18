# frozen_string_literal: true

# The corpus gate has to be REACHED, not merely present.
#
# corpus_test.rb, corpus_ast_types_test.rb, corpus_ast_fields_test.rb and
# corpus_ast_schema_shape_test.rb all hang off one environment variable, and
# every test in them opens with
#
#   skip "CARVE_SPEC_CORPUS not set (see .github/workflows/ci.yml)" unless CORPUS
#
# That skip is a convenience for a plain checkout without the spec repo, and it
# is a hole in CI. All four files are reached through a single `env:` block in
# .github/workflows/ci.yml; delete it, rename the variable, or move `rake test`
# to a job that never checks the spec out, and every corpus assertion stops
# running while the task still exits 0. The build goes green having compared
# nothing - the variant-1 dead check catalogued in markup-carve/carve#755, and
# the shape hugo-carve shipped, where ci.yml skipped the corpus test in silence.
#
# Measured on this gem before this file existed: with CARVE_SPEC_CORPUS unset,
# corpus_test.rb reported "2 runs, 0 assertions, 0 failures, 0 errors, 2 skips"
# and exited 0, over an engine pin that was diverging on 24 of the spec's 1239
# documents at the time.
#
# So the skip is kept exactly where it is useful and refused where it is
# dangerous. This test carries no skip of its own: a CI runner that gets here
# without a corpus is a wiring failure, and it fails rather than reporting a
# pass.

require "minitest/autorun"

class CorpusWiringTest < Minitest::Test
  CORPUS = ENV.fetch("CARVE_SPEC_CORPUS", nil)

  # GitHub Actions sets both; `CI` alone covers other runners.
  IN_CI = ENV["GITHUB_ACTIONS"] == "true" || ENV["CI"] == "true"

  def test_ci_always_has_the_corpus_wired_up
    # Local runs legitimately have no spec checkout. Asserting there would make
    # `rake test` unrunnable outside CI, which is how a guard gets deleted
    # rather than fixed.
    return unless IN_CI

    refute_nil CORPUS,
               "CARVE_SPEC_CORPUS is unset in a CI run. The corpus tests are the only checks " \
               "that measure this gem against the spec, and unset they skip and report " \
               "success. Set it from the spec checkout (see the \"Check out the spec corpus\" " \
               "step in .github/workflows/ci.yml); do not let this run report success."

    assert File.directory?(CORPUS),
           "CARVE_SPEC_CORPUS=#{CORPUS} is set in a CI run but is not a directory, so every " \
           "corpus test below it skips. The spec checkout step is misconfigured."
  end
end

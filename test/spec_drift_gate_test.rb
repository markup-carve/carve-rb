# frozen_string_literal: true

# THE DRIFT VERDICT HAS TO BE ABLE TO FAIL.
#
# The job it belongs to could not. It discarded the gate's exit status and then
# failed only when no count had been logged at all, so the one input it could
# not refuse was a nonzero divergence count - and it passed on
# `50 of 1475 corpus documents render differently` while the gem rendered those
# 50 wrongly (markup-carve/carve-rb#100). A check that cannot fail on its own
# subject is the recurring defect this org keeps finding
# (markup-carve/carve#755), and the only proof against it is watching the
# refusal happen.
#
# So this drives scripts/check-spec-drift.py over synthetic logs and asserts the
# EXIT CODE, never the text. Reading a verdict out of a log is the bug being
# fixed; reproducing it in the test that guards the fix would leave the fix
# unguarded.
#
# It does not need the extension, the corpus, or a built gem, which is the point:
# the four verdicts are then exercised on every push rather than only on the day
# a real divergence appears.

require "minitest/autorun"
require "tmpdir"

class SpecDriftGateTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "scripts/check-spec-drift.py")
  LEDGER = File.join(ROOT, "resources/spec-drift.txt")

  # A log shaped like a real diverging run: the per-document lines
  # scripts/verify-packaged-gem.rb prints, then minitest's failure carrying the
  # headline.
  def diverging_log(*names)
    lines = names.map { |name| "corpus mismatch: #{name}" }
    lines << "#{names.length} of 1475 corpus documents render differently from the spec"
    "#{lines.join("\n")}\n"
  end

  def clean_log
    "packaged gem carve-lang-0.1.2.gem: 1475 of 1475 declared corpus documents byte-identical\n"
  end

  # Exit status only. `capture` returns it; nothing here greps stdout for a
  # verdict.
  def run_gate(log_body, ledger_body, extra = [])
    Dir.mktmpdir("drift-gate") do |dir|
      log = File.join(dir, "drift.log")
      ledger = File.join(dir, "ledger.txt")
      File.write(log, log_body) if log_body
      File.write(ledger, ledger_body)
      args = ["python3", SCRIPT, "--ledger", ledger, *extra]
      args.push("--log", log) if log_body
      system(*args, out: File::NULL, err: File::NULL)
      $?.exitstatus
    end
  end

  def test_an_undeclared_divergence_fails
    assert_equal 1, run_gate(diverging_log("367-002", "412-001"), "# nothing declared\n"),
                 "a diverging document nobody wrote down is the state #100 found; it must fail"
  end

  def test_a_declared_divergence_passes
    ledger = "# reasoned elsewhere\n367-002  # carve-rs has not shipped the rule yet\n412-001\n"
    assert_equal 0, run_gate(diverging_log("367-002", "412-001"), ledger),
                 "a declared window is the normal spec-ahead state and must not fail per-PR"
  end

  def test_one_undeclared_among_declared_still_fails
    ledger = "367-002\n"
    assert_equal 1, run_gate(diverging_log("367-002", "412-001"), ledger),
                 "the verdict is per document, not a count against a threshold"
  end

  def test_a_clean_run_passes
    assert_equal 0, run_gate(clean_log, "")
  end

  # The guard the old shape did have, kept: a run that measured nothing is not a
  # run that found nothing.
  def test_a_log_with_no_count_at_all_fails
    assert_equal 1, run_gate("bundler: command not found: rake\n", "")
  end

  def test_a_headline_with_no_per_document_lines_fails
    log = "50 of 1475 corpus documents render differently from the spec\n"
    assert_equal 1, run_gate(log, ""),
                 "a divergence count with no mismatch lines would be compared against an empty set"
  end

  # The same hole one layer in, and the one that would let a declared subset
  # certify undeclared drift: requiring merely that SOME line printed leaves the
  # omitted documents uncompared.
  def test_a_partial_mismatch_list_fails_even_when_every_printed_row_is_declared
    log = "corpus mismatch: 367-002\n" \
          "50 of 1475 corpus documents render differently from the spec\n"
    assert_equal 1, run_gate(log, "367-002\n"),
                 "one printed line out of fifty counted is not a measurement of the fifty"
  end

  def test_a_stale_declaration_is_reported_and_does_not_fail
    assert_equal 0, run_gate(clean_log, "367-002  # closed by a bump, row not yet dropped\n"),
                 "a row to delete is a notice per-PR; the release gate is what refuses it"
  end

  # The release half of the split.
  def test_release_mode_refuses_a_non_empty_ledger
    assert_equal 1, run_gate(nil, "367-002\n", ["--require-empty-ledger"]),
                 "a declared window is still open, and a tag must not ship one"
  end

  def test_release_mode_accepts_an_empty_ledger
    assert_equal 0, run_gate(nil, "# only comments\n", ["--require-empty-ledger"])
  end

  # The ledger this repository actually ships has to parse under the same reader,
  # or every verdict above is about a file the gate cannot read.
  def test_the_repository_ledger_parses
    Dir.mktmpdir("drift-gate") do |dir|
      log = File.join(dir, "drift.log")
      File.write(log, clean_log)
      assert system("python3", SCRIPT, "--ledger", LEDGER, "--log", log,
                    out: File::NULL, err: File::NULL),
             "resources/spec-drift.txt does not parse"
    end
  end
end

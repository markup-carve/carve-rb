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
require "yaml"

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

  # The shape a real run actually produces: minitest's progress dots arrive with
  # no newline, so the first printed line is glued to them. A reader anchored at
  # the line start drops that document, which is what happened on the first run
  # of this gate - one of three went missing, and only the count check saw it.
  def dot_glued_log(*names)
    log = diverging_log(*names)
    log.sub("corpus mismatch:", "..F.corpus mismatch:")
  end

  # A ledger carrying REASONED rows. Every row needs one since
  # markup-carve/carve-rb#174: the reason used to be discarded by the parser, so
  # a fixture could declare a document with no justification at all and the gate
  # could not tell. Four fixtures here did exactly that, and three of them began
  # passing for the wrong reason rather than failing, which is why they are all
  # routed through this.
  def declared(*names)
    names.map { |name| "#{name}  # carve-rs has not shipped the rule yet\n" }.join
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

  # THE REASON HAS TO BE READ, OR IT CANNOT EXPIRE.
  #
  # read_ledger used to be `line.split("#", 1)[0].strip()`, so everything after
  # the `#` was discarded and three ledgers differing only in their reason all
  # exited 0 (markup-carve/carve-rb#174). That is how 21 rows reading "the
  # pinned engine predates it" survived the bump that made every one of them
  # false (markup-carve/carve-rb#167).
  #
  # The pin these fixtures name is the one ext/carve/Cargo.toml carries, read
  # from the manifest rather than written here, so a bump does not silently turn
  # the passing case into a vacuous one.
  def pinned_engine
    manifest = File.read(File.join(ROOT, "ext/carve/Cargo.toml"))
    entry = manifest.lines.find { |line| line.start_with?("carve_rs = ") }
    flunk("no engine dependency in ext/carve/Cargo.toml") unless entry
    if (revision = entry[/rev = "([^"]+)"/, 1])
      "rev #{revision}"
    elsif (version = entry[/version = "=([^"]+)"/, 1])
      "carve-lang #{version}"
    else
      flunk("no exact engine pin in ext/carve/Cargo.toml")
    end
  end

  def test_a_row_with_no_reason_is_refused
    assert_equal 1, run_gate(diverging_log("367-002"), "367-002\n"),
                 "the format puts a reason after `#` and the header calls it the point of the row"
  end

  def test_a_predates_reason_that_names_no_pin_is_refused
    ledger = "367-002  # the pinned engine predates it\n"
    assert_equal 1, run_gate(diverging_log("367-002"), ledger),
                 "that wording is true for one pin only and cannot expire without naming it"
  end

  def test_a_predates_reason_naming_a_superseded_pin_has_expired
    ledger = "367-002  # the pinned engine carve-lang 0.0.1 predates it\n"
    assert_equal 1, run_gate(diverging_log("367-002"), ledger),
                 "a reason about an engine the manifest no longer pins is a waiver nobody re-checked"
  end

  def test_a_predates_reason_naming_the_current_pin_stands
    ledger = "367-002  # the pinned engine #{pinned_engine} predates it\n"
    assert_equal 0, run_gate(diverging_log("367-002"), ledger),
                 "the reason is true while the pin it names is the pin in the manifest"
  end

  def test_an_undeclared_divergence_fails
    assert_equal 1, run_gate(diverging_log("367-002", "412-001"), "# nothing declared\n"),
                 "a diverging document nobody wrote down is the state #100 found; it must fail"
  end

  def test_a_declared_divergence_passes
    ledger = "# reasoned elsewhere\n" + declared("367-002", "412-001")
    assert_equal 0, run_gate(diverging_log("367-002", "412-001"), ledger),
                 "a declared window is the normal spec-ahead state and must not fail per-PR"
  end

  def test_one_undeclared_among_declared_still_fails
    ledger = declared("367-002")
    assert_equal 1, run_gate(diverging_log("367-002", "412-001"), ledger),
                 "the verdict is per document, not a count against a threshold"
  end

  def test_the_first_line_is_found_when_minitest_glues_its_progress_dots_to_it
    ledger = declared("367-002", "412-001")
    assert_equal 0, run_gate(dot_glued_log("367-002", "412-001"), ledger),
                 "a progress dot in front of the first line must not hide that document"
  end

  def test_a_dot_glued_line_that_is_undeclared_still_fails
    assert_equal 1, run_gate(dot_glued_log("367-002", "412-001"), declared("412-001")),
                 "the glued line is the one that would go missing, so it must be the one that fails"
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
    assert_equal 1, run_gate(log, declared("367-002")),
                 "one printed line out of fifty counted is not a measurement of the fifty"
  end

  def test_a_stale_declaration_is_reported_and_does_not_fail
    assert_equal 0, run_gate(clean_log, "367-002  # closed by a bump, row not yet dropped\n"),
                 "a row to delete is a notice per-PR; the release gate is what refuses it"
  end

  # ---- markup-carve/carve#2706: which reading is a gate ------------------
  #
  # The two readings used to share one exit code. ci.yml now asks for the pair
  # that this repository can act on, and these pin both halves - a flag that is
  # only exercised by a workflow file is a flag nothing tests.

  def test_undeclared_drift_can_be_reported_without_failing
    assert_equal 0, run_gate(diverging_log("367-002", "412-001"), "# nothing declared\n",
                             ["--on-undeclared", "notice"]),
                 "the spec moving is not this repository's failure; #2706 moved it to a pull request"
  end

  def test_the_strict_reading_is_still_the_default
    assert_equal 1, run_gate(diverging_log("367-002"), "# nothing declared\n"),
                 "release.yml and a hand run get the strictest reading without passing a flag"
  end

  def test_a_stale_declaration_fails_under_the_flag_ci_passes
    assert_equal 1, run_gate(clean_log, "367-002  # closed by a bump, row not yet dropped\n",
                             ["--on-stale", "error"]),
                 "a row the measurement contradicts is this repository disagreeing with itself"
  end

  def test_a_stale_row_fails_even_while_undeclared_drift_only_reports
    # The exact pair ci.yml passes, and the combination a single exit code could
    # not express: report what upstream caused, refuse what this repository did.
    assert_equal 1, run_gate(diverging_log("412-001"), "367-002  # no longer diverges\n",
                             ["--on-undeclared", "notice", "--on-stale", "error"]),
                 "the stale row must still fail with undeclared drift demoted to a notice"
  end

  def test_the_measurement_guards_survive_both_flags
    # Not "upstream moved" but "nothing was measured", so no flag may weaken it.
    flags = ["--on-undeclared", "notice", "--on-stale", "error"]
    assert_equal 1, run_gate("nothing was measured here\n", "", flags),
                 "a log with no headline measured nothing, whatever the flags say"
    partial = "corpus mismatch: 367-002\n" \
              "50 of 1475 corpus documents render differently from the spec\n"
    assert_equal 1, run_gate(partial, declared("367-002"), flags),
                 "a headline its per-document lines do not account for is not a measurement"
  end

  # The handoff to scripts/declare-spec-drift.sh. The file is the only thing
  # that reaches the automation, so an empty one and a missing one must mean
  # different things: measured and clear, versus never got there.
  def test_the_undeclared_rows_are_written_for_the_automation
    rows = undeclared_file(diverging_log("367-002", "412-001"), declared("412-001"))
    assert_equal ["367-002"], rows,
                 "the automation declares exactly the rows the ledger lacks"
  end

  def test_an_empty_undeclared_file_is_written_when_nothing_is_undeclared
    assert_equal [], undeclared_file(clean_log, ""),
                 "empty means measured and clear; absence must not be able to mean that too"
  end

  def test_no_undeclared_file_is_written_when_nothing_was_measured
    assert_nil undeclared_file("nothing was measured here\n", ""),
               "a run that measured nothing must leave the automation nothing to read"
  end

  # The release half of the split.
  def test_release_mode_refuses_a_non_empty_ledger
    assert_equal 1, run_gate(nil, declared("367-002"), ["--require-empty-ledger"]),
                 "a declared window is still open, and a tag must not ship one"
  end

  def test_release_mode_accepts_an_empty_ledger
    assert_equal 0, run_gate(nil, "# only comments\n", ["--require-empty-ledger"])
  end

  # Returns the written rows, or nil when the script wrote no file at all.
  def undeclared_file(log_body, ledger_body)
    Dir.mktmpdir("drift-gate") do |dir|
      log = File.join(dir, "drift.log")
      ledger = File.join(dir, "ledger.txt")
      out = File.join(dir, "undeclared.txt")
      File.write(log, log_body)
      File.write(ledger, ledger_body)
      system("python3", SCRIPT, "--ledger", ledger, "--log", log,
             "--on-undeclared", "notice", "--write-undeclared", out,
             out: File::NULL, err: File::NULL)
      next nil unless File.exist?(out)

      File.read(out).split("\n").reject(&:empty?)
    end
  end

  # ---- the wiring, not only the script -----------------------------------
  #
  # Every assertion above is about flags, and a flag no workflow passes changes
  # nothing. These read ci.yml, because the whole ruling lives in which pair of
  # flags that file chooses and on which events the pull request opens.

  def ci
    @ci ||= YAML.safe_load_file(File.join(ROOT, ".github/workflows/ci.yml"), aliases: true)
  end

  def drift_step
    ci.dig("jobs", "corpus-drift", "steps")
      .find { |step| step["run"].to_s.include?("check-spec-drift.py") }
  end

  def test_ci_demotes_undeclared_drift_and_gates_on_a_false_declaration
    run = drift_step.fetch("run")

    assert_includes run, "--on-undeclared notice",
                    "ci.yml gating on undeclared drift is what reddened main for a spec change " \
                    "nobody here made (markup-carve/carve#2706, #157)"
    assert_includes run, "--on-stale error",
                    "the half this repository can clear must stay a gate"
  end

  def test_ci_hands_the_undeclared_rows_to_the_automation
    assert_includes drift_step.fetch("run"), "--write-undeclared",
                    "without the file the scheduled job has nothing to open a pull request about"
  end

  def test_the_pull_request_opens_on_the_schedule_only
    condition = ci.dig("jobs", "declare-drift", "if").to_s

    assert_includes condition, "schedule"
    assert_includes condition, "workflow_dispatch"
    assert_includes condition, "refs/heads/main"
    refute_includes condition, "pull_request",
                    "a contributor's pull request is not the place to learn the spec moved, and " \
                    "a bot opening one per topic branch is how a filer gets muted"
  end

  def test_only_that_job_runs_the_automation
    runners = ci.fetch("jobs").select do |_id, job|
      Array(job["steps"]).any? { |step| step["run"].to_s.include?("declare-spec-drift.sh") }
    end

    assert_equal ["declare-drift"], runners.keys,
                 "the pull request channel must have exactly one caller, or two of them race " \
                 "over one branch"
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

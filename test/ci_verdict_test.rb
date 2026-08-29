# frozen_string_literal: true

# The verdict has to REACH somebody, and it has to stop.
#
# A filer that never files is the failure it was written for, restated: the
# 2026-08-29 stale pin was found here at 06:15 and read by a person at 13:40,
# through another repository's ticket (#107). A filer that files on a green run,
# or re-files what is already open, is worse - a repeating ticket is muted, and
# then the next real one is muted with it.
#
# Neither can be checked by watching CI, because the interesting runs are the
# red ones and they are rare on purpose. So the script is driven here against
# canned run payloads with `gh` stubbed on PATH, and what it WOULD do is read
# back from the calls it made.

require "minitest/autorun"
require "json"
require "tmpdir"
require "yaml"

class CiVerdictTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "scripts/file-ci-verdict.sh")
  MARKER = "<!-- ci-verdict ref=main -->"

  # The name the workflow passes as VERDICT_JOB_NAME. Asserted against ci.yml
  # below: if the two drift apart the script stops recognizing itself, counts
  # its own result, and every run files a ticket about the filer.
  SELF_NAME = "The verdict reaches a person"

  def job(name, conclusion)
    { "name" => name, "conclusion" => conclusion, "status" => "completed" }
  end

  def run_script(jobs:, issues: [], ref: "main", event: "schedule")
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "jobs.json"), JSON.generate({ "jobs" => jobs }))
      File.write(File.join(dir, "issues.json"), JSON.generate(issues))

      bin = File.join(dir, "bin")
      Dir.mkdir(bin)
      File.write(File.join(bin, "gh"), gh_stub(dir))
      File.chmod(0o755, File.join(bin, "gh"))

      env = {
        "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
        "REPO" => "markup-carve/carve-rb",
        "RUN_ID" => "1",
        "RUN_URL" => "https://example.invalid/run/1",
        "HEAD_SHA" => "abc1234",
        "REF_NAME" => ref,
        "DEFAULT_BRANCH" => "main",
        "EVENT_NAME" => event,
        "VERDICT_JOB_NAME" => SELF_NAME,
        "GITHUB_STEP_SUMMARY" => "",
      }
      out = IO.popen(env, ["bash", SCRIPT], err: %i[child out], &:read)
      calls = File.exist?(File.join(dir, "calls.log")) ? File.read(File.join(dir, "calls.log")) : ""
      body = File.exist?(File.join(dir, "sent-body.md")) ? File.read(File.join(dir, "sent-body.md")) : ""
      [calls, body, out, $?]
    end
  end

  # Answers the two reads the script makes and records everything else. The
  # body file is copied out because the script deletes its own work directory.
  def gh_stub(dir)
    <<~STUB
      #!/usr/bin/env bash
      echo "$*" >> "#{dir}/calls.log"
      prev=""
      for arg in "$@"; do
        if [ "$prev" = "--body-file" ]; then cp "$arg" "#{dir}/sent-body.md"; fi
        prev="$arg"
      done
      case "$*" in
        *actions/runs/*/jobs*) cat "#{dir}/jobs.json" ;;
        *issues?state=open*)   cat "#{dir}/issues.json" ;;
        *) : ;;
      esac
      exit 0
    STUB
  end

  def open_issue(number, jobs, wrote_by: nil)
    recorded = (["<!-- ci-verdict-jobs"] + jobs + ["-->"]).join("\n")
    stamp = wrote_by ? "<!-- ci-verdict-run #{wrote_by} -->\n" : ""
    { "number" => number, "pull_request" => nil, "body" => "#{MARKER}\n#{stamp}#{recorded}\n" }
  end

  RED = [
    { "name" => "build", "conclusion" => "success", "status" => "completed" },
    { "name" => "The gem's tree is carve-rs's tree", "conclusion" => "failure", "status" => "completed" },
  ].freeze

  def test_a_red_run_files_a_labeled_ticket
    calls, body, = run_script(jobs: RED)

    assert_includes calls, "issue create",
                    "a red run filed nothing. That is the state #107 describes: the run knows, " \
                    "and the knowledge stays on the Actions tab. calls:\n#{calls}"
    assert_includes calls, "--label bug"
    assert_includes calls, "--label area:tooling",
                    "the ticket is filed without an area label, which is what makes a backlog " \
                    "unfilterable. calls:\n#{calls}"
    assert_includes body, MARKER, "the ticket carries no marker, so the next red run cannot find it"
    assert_includes body, "The gem's tree is carve-rs's tree",
                    "the ticket does not name the job that failed"
  end

  def test_a_second_red_run_edits_the_ticket_it_already_filed
    calls, = run_script(jobs: RED, issues: [open_issue(42, ["build"])])

    assert_includes calls, "issue edit 42", "the second red run did not update the open ticket"
    refute_includes calls, "issue create",
                    "a ticket already stood and this filed another. A repeating ticket is muted, " \
                    "and the next real one is muted with it. calls:\n#{calls}"
  end

  def test_a_green_run_closes_the_open_ticket
    green = [job("build", "success"), job("The gem's tree is carve-rs's tree", "success")]
    calls, = run_script(jobs: green, issues: [open_issue(42, ["build", "The gem's tree is carve-rs's tree"])])

    assert_includes calls, "issue close 42",
                    "green and the ticket stayed open. A ticket that outlives its cause is the " \
                    "same mute. calls:\n#{calls}"
  end

  def test_a_green_run_files_nothing_when_no_ticket_is_open
    green = [job("build", "success")]
    calls, = run_script(jobs: green)

    refute_includes calls, "issue create", "a green run filed a ticket"
    refute_includes calls, "issue close", "a green run tried to close a ticket that does not exist"
  end

  # The floor that keeps a half-run from clearing a ticket a full run opened.
  def test_a_run_that_skipped_the_failing_job_does_not_close_the_ticket
    partial = [job("build", "success")]
    open = open_issue(42, ["build", "The gem's drift from spec main is declared"])
    calls, = run_script(jobs: partial, issues: [open])

    refute_includes calls, "issue close",
                    "the drift job never ran in this run, and its ticket was closed anyway. " \
                    "Not running a check is not the same as passing it. calls:\n#{calls}"
    assert_includes calls, "issue comment 42",
                    "the ticket was left open with no word about why. calls:\n#{calls}"
  end

  # If the filer counted itself, its own `if: always()` result would decide the
  # verdict, and a green run whose filer errored once would file forever.
  def test_the_filer_does_not_report_on_itself
    green_but_self_red = [job("build", "success"), job(SELF_NAME, "failure")]
    calls, = run_script(jobs: green_but_self_red)

    refute_includes calls, "issue create",
                    "the filer counted its own job as a failure and filed a ticket about itself. " \
                    "calls:\n#{calls}"
  end

  # Actions has more ways to not pass than `failure`. A job that never started
  # reports `startup_failure`, and reading only the three obvious conclusions
  # made that a green run - which does not merely under-report, it CLOSES the
  # open ticket.
  def test_a_job_that_never_started_is_not_a_pass
    %w[startup_failure action_required stale cancelled timed_out].each do |conclusion|
      jobs = [job("build", "success"), job("The gem's tree is carve-rs's tree", conclusion)]
      calls, = run_script(jobs: jobs)

      assert_includes calls, "issue create",
                      "a job concluded `#{conclusion}` and the run was read as green. calls:\n#{calls}"
    end
  end

  def test_a_job_skipped_by_its_own_condition_is_not_a_failure
    jobs = [job("build", "success"), job("binding-parity", "skipped")]
    calls, = run_script(jobs: jobs)

    refute_includes calls, "issue create",
                    "a skipped job filed a ticket. Jobs here skip by their own `if:` for " \
                    "reasons that are nobody's problem. calls:\n#{calls}"
  end

  # Runs on the default branch overlap and finish in whatever order they
  # finish. The dangerous direction is an older GREEN run landing last and
  # closing the ticket a newer red run just filed - silence again, by the
  # mechanism this whole script removes.
  def test_an_older_run_does_not_close_a_ticket_a_newer_run_wrote
    green = [job("build", "success")]
    calls, = run_script(jobs: green, issues: [open_issue(42, ["build"], wrote_by: 999)])

    refute_includes calls, "issue close",
                    "a run older than the one that wrote the ticket closed it. RUN_ID here is " \
                    "1 and the ticket says 999. calls:\n#{calls}"
  end

  def test_a_newer_run_still_closes_it
    green = [job("build", "success")]
    calls, = run_script(jobs: green, issues: [open_issue(42, ["build"], wrote_by: 0)])

    assert_includes calls, "issue close 42",
                    "the stand-down guard is refusing runs it should let through. calls:\n#{calls}"
  end

  # The floor records the jobs that REACHED a verdict, and a job can reach one
  # without either passing or failing. Recording only success and failure left a
  # cancelled job out of the floor, so the ticket it opened could be cleared by a
  # later run that merely skipped it.
  def test_a_ticket_opened_by_a_cancelled_job_survives_a_run_that_skips_it
    opened_by = [job("build", "success"), job("corpus-drift", "cancelled")]
    calls, body, = run_script(jobs: opened_by)

    assert_includes calls, "issue create"
    assert_includes body, "corpus-drift",
                    "the cancelled job was left out of the recorded floor, so nothing will " \
                    "insist it ever runs again. body:\n#{body}"

    later = [job("build", "success"), job("corpus-drift", "skipped")]
    calls, = run_script(jobs: later, issues: [open_issue(42, ["build", "corpus-drift"])])

    refute_includes calls, "issue close",
                    "a run that SKIPPED the job which opened the ticket closed it anyway. " \
                    "calls:\n#{calls}"
  end

  def test_a_topic_branch_files_nothing
    calls, _body, out, = run_script(jobs: RED, ref: "chore/whatever", event: "push")

    refute_includes calls, "issue create",
                    "a red topic branch filed a ticket. Every broken push would open one."
    assert_match(/scoped to main/, out)
  end

  # WIRING. The script above can be perfect and never run, or run under a name
  # it does not answer to.
  def ci
    @ci ||= YAML.safe_load_file(File.join(ROOT, ".github/workflows/ci.yml"), aliases: true)
  end

  def verdict_job
    ci.fetch("jobs").find { |_id, j| Array(j["steps"]).any? { |s| s["run"].to_s.include?("file-ci-verdict.sh") } }
  end

  def test_the_workflow_runs_the_filer
    refute_nil verdict_job,
               "no job in ci.yml runs scripts/file-ci-verdict.sh, so a red scheduled run is " \
               "silent again. jobs: #{ci.fetch('jobs').keys.inspect}"
  end

  def test_the_filer_runs_even_though_the_jobs_it_reports_on_failed
    _id, job_def = verdict_job

    assert_equal "always()", job_def["if"].to_s.strip,
                 "the verdict job is not `if: always()`, so it is skipped exactly when a job " \
                 "ahead of it fails - which is the only time it has anything to say."
  end

  def test_the_filer_waits_for_every_other_job
    id, job_def = verdict_job
    others = ci.fetch("jobs").keys - [id]

    assert_empty others - Array(job_def["needs"]),
                 "the verdict job does not `needs:` every other job, so it can read the run " \
                 "before they finish and report a failure as if it had not happened."
  end

  # Naming any permission opts a job out of the defaults for ALL of them, so
  # this asserts the whole set rather than the one scope the job is "about".
  # Each missing scope kills the job at a different point and all three end the
  # same way: nothing filed, which is the silence this job exists to end.
  # The filer reads the ticket, decides, then writes. That is not atomic, so two
  # overlapping runs can both read "no ticket" and both file one.
  def test_only_one_verdict_runs_at_a_time
    _id, job_def = verdict_job
    concurrency = job_def["concurrency"] || {}

    refute_nil concurrency["group"],
               "the verdict job has no concurrency group, so two overlapping runs on this " \
               "branch can interleave their read-check-write and file the ticket twice."
    assert_equal false, concurrency["cancel-in-progress"],
                 "the verdict job cancels itself in progress. A cancelled verdict is a run " \
                 "that reported nothing, which is the silence this job exists to end."
  end

  def test_the_filer_holds_every_permission_it_uses
    _id, job_def = verdict_job
    permissions = job_def["permissions"] || {}

    assert_equal({ "actions" => "read", "contents" => "read", "issues" => "write" },
                 permissions,
                 "the verdict job's permissions are not the set the script uses: `contents` " \
                 "for actions/checkout, `actions` to read this run's jobs, `issues` to file. " \
                 "A job-level block replaces the defaults rather than adding to them, so a " \
                 "scope left out here is `none`.")
  end

  def test_the_name_the_script_answers_to_is_the_name_the_job_carries
    _id, job_def = verdict_job
    passed = Array(job_def["steps"]).filter_map { |s| s.dig("env", "VERDICT_JOB_NAME") }.first

    assert_equal job_def["name"], passed,
                 "VERDICT_JOB_NAME does not match the job's own name. The script excludes " \
                 "itself by that string; mismatched, it counts its own result and every run " \
                 "files a ticket about the filer."
  end
end

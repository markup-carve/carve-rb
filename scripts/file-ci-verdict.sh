#!/usr/bin/env bash
#
# Turn a red run on the default branch into a ticket, and close it on green.
#
# The scheduled run is the only thing here that can see the engine or the spec
# moving, because both move without a commit in this repository. Until #107 a
# red one left nothing behind but a dot on the Actions tab: on 2026-08-29 the
# 06:15 run named a stale pin and the exact remedy, and the signal that reached
# a person came four hours later from markup-carve/carve's workflow instead.
set -euo pipefail

: "${REPO:?}" "${RUN_ID:?}" "${RUN_URL:?}" "${HEAD_SHA:?}"
: "${REF_NAME:?}" "${DEFAULT_BRANCH:?}" "${EVENT_NAME:?}" "${VERDICT_JOB_NAME:?}"

MARKER="<!-- ci-verdict ref=$REF_NAME -->"
JOBS_OPEN="<!-- ci-verdict-jobs"
TITLE="CI is failing on $REF_NAME"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat >> "$GITHUB_STEP_SUMMARY"
  else
    cat
  fi
}

# In dry-run every mutating call is printed instead of made, so the verdict can
# be exercised against a real past run without filing anything.
gh_write() {
  if [ -n "${VERDICT_DRY_RUN:-}" ]; then
    printf 'WOULD RUN: gh %s\n' "$*"
    # The body is the part worth reading back, and it lives in a directory the
    # exit trap removes.
    local prev=""
    for arg in "$@"; do
      [ "$prev" = "--body-file" ] && { echo "--- body ---"; cat "$arg"; echo "--- end body ---"; }
      prev="$arg"
    done
    return 0
  fi
  gh "$@"
}

# Tickets are scoped to the default branch. A red run on a topic branch is the
# author's to read; filing for it would put a ticket on every broken push.
if [ "$REF_NAME" != "$DEFAULT_BRANCH" ]; then
  echo "CI verdict tickets are scoped to $DEFAULT_BRANCH; $REF_NAME keeps its Actions verdict only."
  exit 0
fi

jobs_json="$WORK/jobs.json"
gh api "repos/$REPO/actions/runs/$RUN_ID/jobs" --paginate > "$jobs_json"

# This job is excluded from every reading below. It runs with `if: always()`
# beside the jobs it reports on, so counting itself would make the verdict a
# function of its own result.
jq_jobs() { jq -r --arg self "$VERDICT_JOB_NAME" "$1" < "$jobs_json"; }

# Anything that is not a pass is a failure, listed that way round on purpose.
# Naming the failing conclusions instead (failure, cancelled, timed_out) leaves
# `startup_failure`, `action_required` and `stale` reading as GREEN, and green
# here does not merely under-report - it CLOSES an open ticket.
#
# `skipped` and `neutral` are not failures: a job can be skipped by its own
# `if:` for a reason that is nobody's problem. A skipped job is instead absent
# from the measured set below, so it cannot close anything either.
failed="$(jq_jobs '
  .jobs[] | select(.name != $self)
  | select(.conclusion != null)
  | select(.conclusion as $c | ["success", "skipped", "neutral"] | index($c) | not)
  | "- `" + .name + "` (" + .conclusion + ")"')"

# The jobs that actually reached a verdict, discovered from the run rather than
# listed here: a hand-kept list goes stale the first time a job is added, and a
# job it forgot to name is a job whose failure is invisible again.
#
# "Reached a verdict" is every conclusion except `skipped` and null, NOT just
# success and failure. Recording only those two left a job that was `cancelled`
# out of the floor below, so the ticket it opened could be closed by a later run
# that merely SKIPPED it - the floor's own failure mode, one conclusion over.
jq_jobs '.jobs[] | select(.name != $self)
  | select(.conclusion != null and .conclusion != "skipped") | .name' \
  | sort -u > "$WORK/measured.txt"

# Matched on the marker rather than the title, so renaming the ticket does not
# fork it into two, and LISTED rather than searched: the search index lags a
# fresh issue by long enough to file a duplicate.
#
# The whole issue is kept, not just its number: the recorded job set is read
# back out of this same object below. Fetching the body again would be a second
# answer to a question already answered, and the two can disagree.
gh api "repos/$REPO/issues?state=open&per_page=100" --paginate \
  | jq -s --arg m "$MARKER" \
      '[.[][] | select(.pull_request == null) | select((.body // "") | contains($m))] | first // empty' \
  > "$WORK/issue.json"

issue="$(jq -r '.number // empty' < "$WORK/issue.json")"
jq -r '.body // ""' < "$WORK/issue.json" > "$WORK/body.txt"
sed -n "/^$JOBS_OPEN\$/,/^-->\$/p" < "$WORK/body.txt" | sed '1d;$d' > "$WORK/previous.txt"

# Runs on the default branch overlap - a push and the 06:15 schedule, or two
# pushes - and they finish in whatever order they finish. An OLDER run reaching
# this point last would otherwise close a ticket a NEWER red run just filed,
# which is silence again, by the mechanism this script exists to remove.
#
# Run ids increase monotonically within a repository, so the ticket carries the
# id of the run that last wrote it and an older run stands down. Equal ids are a
# re-run of the same run and may proceed.
last_run="$(sed -n 's/^<!-- ci-verdict-run \([0-9]*\) -->$/\1/p' < "$WORK/body.txt" | head -n 1)"
if [ -n "$last_run" ] && [ "$last_run" -gt "$RUN_ID" ]; then
  echo "Run $last_run already wrote #$issue and is newer than this run ($RUN_ID). Standing down."
  printf 'A newer run (%s) already wrote #%s. This run wrote nothing.\n' "$last_run" "$issue" | summary
  exit 0
fi
sort -u "$WORK/measured.txt" "$WORK/previous.txt" > "$WORK/required.txt"

if [ -z "$failed" ]; then
  # A run that SKIPPED the job which failed last time is not evidence that it
  # passes. Without this floor, a run whose `build` died early would close a
  # ticket opened by the corpus job that never got to run.
  missing="$(comm -23 "$WORK/required.txt" "$WORK/measured.txt")"
  if [ -n "$issue" ] && [ -n "$missing" ]; then
    missing_list="$(printf '%s\n' "$missing" | sed 's/^/- `/; s/$/`/')"
    gh_write issue comment "$issue" --repo "$REPO" --body \
      "This run is green for the jobs it ran, but it did not close the ticket because it never ran jobs an earlier red run measured:"$'\n\n'"$missing_list"$'\n\n'"A green run that reaches them can close it."
    printf 'CI is green on `%s` for the jobs this run ran, but #%s stays open: %s\n' \
      "$HEAD_SHA" "$issue" "$(printf '%s' "$missing" | tr '\n' ' ')" | summary
    exit 0
  fi
  if [ -n "$issue" ]; then
    gh_write issue comment "$issue" --repo "$REPO" --body \
      "Green again: run $RUN_URL on \`$HEAD_SHA\`. Closing. The next red run files a fresh ticket rather than reopening this one."
    gh_write issue close "$issue" --repo "$REPO"
    echo "Closed #$issue."
  fi
  printf 'CI green on `%s`. Nothing filed.\n' "$HEAD_SHA" | summary
  exit 0
fi

{
  echo "$MARKER"
  echo "<!-- ci-verdict-run $RUN_ID -->"
  echo "$JOBS_OPEN"
  cat "$WORK/required.txt"
  echo "-->"
  echo
  echo "CI is failing on \`$REF_NAME\`. The corpus and binding jobs here can go red"
  echo "without a commit in this repository - the spec and the engine both move on"
  echo "their own - so a scheduled run is what finds it, and no pull request gate"
  echo "will show it to you."
  echo
  echo "| | |"
  echo "| --- | --- |"
  echo "| run | $RUN_URL |"
  echo "| commit | \`$HEAD_SHA\` |"
  echo "| ref | \`$REF_NAME\` |"
  echo "| trigger | \`$EVENT_NAME\` |"
  echo
  echo "### Failing jobs"
  echo
  printf '%s\n' "$failed"
  echo
  echo "### Before acting on this"
  echo
  echo "Read the run's own error before anything else. Both drift jobs name the"
  echo "remedy in full, including which file to edit, and that message is more"
  echo "specific than this ticket can be."
  echo
  echo "If the cause is a stale engine pin, the fix is to bump the carve-rs"
  echo "revision in \`ext/carve/Cargo.toml\`, commit the regenerated"
  echo "\`ext/carve/Cargo.lock\`, and let this run again."
  echo
  echo "This ticket is filed and maintained by the workflow. It is EDITED by each"
  echo "later red run and CLOSED by the first green one. Closing it by hand does"
  echo "not silence it: the next red run files a new one."
} > "$WORK/verdict.md"

# One ordering is knowingly left unhandled: a newer GREEN run closing the ticket
# before an older RED run gets here, which then finds nothing open and files for
# a failure that is already fixed. Catching it means reading closed tickets too,
# on every run, for an ordering that needs a push and the 06:15 schedule to
# overlap AND to finish backwards.
#
# It is left because of which way it fails. A stale ticket is noise, and the next
# green run closes it - its run id is higher than the stamp, so the guard above
# lets it through. The failure this file exists to remove is the opposite one,
# and it does not clear itself: nobody is told, and nobody is told again
# tomorrow.
if [ -n "$issue" ]; then
  gh_write issue edit "$issue" --repo "$REPO" --body-file "$WORK/verdict.md"
  echo "Updated #$issue."
else
  gh_write issue create --repo "$REPO" --title "$TITLE" \
    --body-file "$WORK/verdict.md" --label bug --label area:tooling
fi

printf 'CI is red on `%s`. Failing jobs:\n\n%s\n' "$HEAD_SHA" "$failed" | summary

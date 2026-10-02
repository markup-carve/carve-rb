#!/usr/bin/env bash
# Turn undeclared spec drift into a pull request instead of a red run.
#
# markup-carve/carve#2706: a drift-against-upstream check opens a pull request,
# it does not fail a scheduled run. "The spec moved" is not a failure of this
# gem's code, and painting `main` red for it taught people that red is normal -
# measured on 2026-10-02, vscode-carve's engine-drift had been red since 09-14
# and intellij-carve's since 09-18 with nobody acting on either. It is also
# unwinnable as a red: the corpus gains documents faster than this pin moves,
# so the job returns to red by design.
#
# The measurement is untouched and still runs daily. What changes is where its
# answer lands. Given the undeclared basenames, this writes them into
# resources/spec-drift.txt with their reason and opens - or updates - ONE pull
# request on `automation/declare-spec-drift`. The diff is information a red run
# could not carry.
#
# A DECLARATION IS NOT THE BEST FIX AND THE PULL REQUEST SAYS SO. Bumping the
# carve-rs revision closes the window; declaring it only makes the window known.
# Choosing a revision needs a build this script does not do and a human judging
# what the bump drags in, so the automation does the mechanical half and names
# the other.
#
# Usage:
#   scripts/declare-spec-drift.sh --undeclared undeclared.txt --spec <sha> \
#       [--ledger resources/spec-drift.txt] [--repo owner/name] [--dry-run]
#
# Needs `gh` authenticated and push rights for the branch. Appends to
# GITHUB_STEP_SUMMARY when it is set.
#
# Exit codes: 0 nothing to do, or a pull request is open and current.
#             1 refused: nothing was measured, the branch moved under it, or a
#               merge conflicted.
#             2 usage.
set -uo pipefail

BRANCH="automation/declare-spec-drift"
LEDGER="resources/spec-drift.txt"
UNDECLARED=""
SPEC=""
REPO="${GITHUB_REPOSITORY:-}"
DRY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --undeclared) UNDECLARED="$2"; shift 2 ;;
    --spec) SPEC="$2"; shift 2 ;;
    --ledger) LEDGER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "declare-spec-drift: unknown argument $1" >&2; exit 2 ;;
  esac
done

[ -n "$UNDECLARED" ] || { echo "declare-spec-drift: --undeclared is required" >&2; exit 2; }
[ -n "$SPEC" ] || { echo "declare-spec-drift: --spec is required" >&2; exit 2; }
[ -n "$REPO" ] || { echo "declare-spec-drift: --repo is required outside Actions" >&2; exit 2; }

say() {
  echo "$*"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "$*" >> "$GITHUB_STEP_SUMMARY"
  fi
  return 0
}

# A MISSING FILE IS NOT AN EMPTY ONE. check-spec-drift.py writes this file on
# every run whose comparison happened, empty when nothing is undeclared, so
# absence means the measurement never got that far and there is nothing to act
# on. Treating the two alike is how an automation reports "all clear" about a
# run that did not happen (markup-carve/carve#755).
if [ ! -f "$UNDECLARED" ]; then
  echo "declare-spec-drift: no $UNDECLARED, so nothing was measured; refusing to conclude anything" >&2
  exit 1
fi

mapfile -t ROWS < <(grep -v '^[[:space:]]*$' "$UNDECLARED" || true)

BOT_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"
open_pr="$(gh pr list --repo "$REPO" --head "$BRANCH" --state open --json number --jq '.[0].number // empty')"

if [ "${#ROWS[@]}" -eq 0 ]; then
  # NO DRIFT. Nothing is closed and no branch deleted from here: an open pull
  # request may carry a human's edit, and the next run asks the question again.
  # Say which state this is, because "the automation did nothing" and "the
  # automation did not run" look identical in a log otherwise.
  if [ -n "$open_pr" ]; then
    say "declare-spec-drift: no undeclared divergence at spec ${SPEC}; leaving #${open_pr} to a human."
  else
    say "declare-spec-drift: no undeclared divergence at spec ${SPEC}; nothing to open."
  fi
  exit 0
fi

# ---- Never clobber a human's commits on the branch ------------------------
# This script re-pushes the branch on every run that finds drift, and a lane in
# this org had its work overwritten by exactly that shape. So read the branch's
# tip NOW and hold the push to it as a lease, and count the commits ahead of
# main that this script did not author.
#
# gh prints a 404 body on STDOUT, so a missing branch arrives as JSON rather
# than as the empty string; anything that is not a full sha means "not there",
# which the push below spells as "must still not exist".
observed="$(gh api "repos/$REPO/git/ref/heads/$BRANCH" --jq '.object.sha' 2>/dev/null || true)"
printf '%s' "$observed" | grep -Eq '^[0-9a-f]{40}$' || observed=""

# THE SCAN MUST FAIL CLOSED. This call is the only thing standing between a
# force-push and somebody's commits, and a `gh api` that errors - a secondary
# rate limit, a network blip, a renamed default branch - used to leave `foreign`
# at its initial 0 and read as "nobody has touched it". The one failure mode
# this guard exists to prevent was reachable by the guard's own call failing.
# So an unreadable compare means PRESERVE, which costs a skipped run and loses
# nothing. Only a compare that was actually read may authorize the force-push.
foreign=0
if ahead="$(gh api "repos/$REPO/compare/main...$BRANCH" \
      --jq '.commits[] | "\(.commit.author.email)|\(.commit.committer.email)"' 2>/dev/null)"; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Either identity differing from the bot counts as human. Conservative in
    # the safe direction: an unrecognized author means preserve.
    if [ "${line%%|*}" != "$BOT_EMAIL" ] || [ "${line##*|}" != "$BOT_EMAIL" ]; then
      foreign=$((foreign + 1))
    fi
  done <<< "$ahead"
elif [ -n "$observed" ]; then
  # The branch exists (a sha was read above) and its history could not be read,
  # so treat every commit on it as somebody else's.
  foreign=1
  echo "::warning::could not read repos/$REPO/compare/main...$BRANCH, so this run treats $BRANCH as carrying work it did not write"
fi

# Commits stay ahead of `main` BY AUTHOR whatever became of their content, so a
# squash-merged or closed branch reads as human work forever. With no pull
# request open there is nobody working on it, no reviewer and no comment target,
# so preserving it buys nothing and wedges every later run - that is how
# tree-sitter-carve sat wedged for eight commits (markup-carve/carve#971).
preserve=""
if [ "$foreign" -gt 0 ] && [ -n "$open_pr" ]; then
  preserve=1
fi

if [ -n "${GITHUB_ACTIONS:-}" ]; then
  git config user.name "github-actions[bot]"
  git config user.email "$BOT_EMAIL"
fi

if [ -n "$preserve" ]; then
  echo "$BRANCH carries $foreign commit(s) this script did not write and #${open_pr} is open -> preserving"
  git fetch origin "$BRANCH" || { echo "declare-spec-drift: cannot fetch $BRANCH" >&2; exit 1; }
  git checkout -B "$BRANCH" "origin/$BRANCH" || exit 1
  if ! git merge --no-edit origin/main; then
    git merge --abort 2>/dev/null || true
    msg="Declaring spec drift aborted: merging main into ${BRANCH} conflicts, and the branch carries ${foreign} commit(s) this workflow did not write, so it will not force-push over them. Resolve the conflict on the branch, then re-run."
    echo "::error::$msg"
    say "$msg"
    gh pr comment "$open_pr" --repo "$REPO" --body "$msg" >/dev/null 2>&1 || true
    exit 1
  fi
else
  git checkout -B "$BRANCH" || exit 1
fi

# Append only the rows the ledger does not already carry, so a re-push over a
# preserved branch does not duplicate a line somebody already wrote.
python3 - "$LEDGER" "$SPEC" "${ROWS[@]}" <<'PY'
import datetime, sys
from pathlib import Path

ledger, spec, rows = Path(sys.argv[1]), sys.argv[2], sys.argv[3:]
text = ledger.read_text(encoding="utf-8")
have = {line.split("#", 1)[0].strip() for line in text.splitlines()}
today = datetime.date.today().isoformat()
new = [row for row in rows if row not in have]
if new:
    if not text.endswith("\n"):
        text += "\n"
    reason = f"# undeclared at spec main {spec} on {today}; the pinned engine predates it"
    text += "".join(f"{name} {reason}\n" for name in new)
    ledger.write_text(text, encoding="utf-8")
print(f"declare-spec-drift: {len(new)} row(s) added to {ledger}")
PY

if git diff --quiet -- "$LEDGER" && [ -z "$preserve" ]; then
  say "declare-spec-drift: ${LEDGER} already declares every divergence at spec ${SPEC}; nothing to push."
  exit 0
fi

BODY_FILE="$(mktemp)"
{
  printf 'The daily drift measurement found %s corpus document(s) that this gem renders\n' "${#ROWS[@]}"
  printf 'differently from spec main (`%s`) with nothing in `%s` saying so.\n' "$SPEC" "$LEDGER"
  printf 'This pull request writes them down.\n\n'
  printf 'Until markup-carve/carve#2706 that reading failed a scheduled run on `main`. It is\n'
  printf "not a failure of this gem's code - the spec gains documents and the pinned engine\\n"
  printf 'implements them later - and a red default branch for it blocked unrelated pull\n'
  printf 'requests while nobody could clear it.\n\n'
  printf '### The better fix\n\n'
  printf 'Declaring a window makes it known; bumping the pin closes it. If the carve-rs\n'
  printf 'revision in `ext/carve/Cargo.toml` has since implemented these rules, bump it and\n'
  printf 'commit the regenerated `ext/carve/Cargo.lock` instead of merging this, then delete\n'
  printf 'the rows the bump closes.\n\n'
  printf '### Documents\n\n'
  printf -- '- `%s`\n' "${ROWS[@]}"
  printf '\nOpened and updated by `scripts/declare-spec-drift.sh`. It re-pushes this branch, so\n'
  printf 'it checks first: any commit on it that this workflow did not author is merged with\n'
  printf '`main` rather than overwritten, and the push is held to a lease read at the start of\n'
  printf 'the run.\n'
} > "$BODY_FILE"

if [ -n "$DRY" ]; then
  if [ -n "$open_pr" ]; then
    say "declare-spec-drift: --dry-run, so not pushing. Would have updated #${open_pr} with ${#ROWS[@]} row(s)."
  else
    say "declare-spec-drift: --dry-run, so not pushing. Would have opened a pull request with ${#ROWS[@]} row(s)."
  fi
  git --no-pager diff --stat -- "$LEDGER"
  echo "--- body ---"
  cat "$BODY_FILE"
  exit 0
fi

git add -- "$LEDGER"
git commit -q -m "ci: declare ${#ROWS[@]} corpus document(s) the pinned engine predates" || true

if [ -n "$preserve" ]; then
  # A plain push is the safety net on this path: the branch is somebody else's,
  # so a push rejected for having moved is the right outcome.
  if ! git push origin "$BRANCH"; then
    msg="Declaring spec drift aborted: ${BRANCH} moved and this run will not force-push over ${foreign} commit(s) it did not write. Nothing was lost; re-run."
    echo "::error::$msg"
    say "$msg"
    exit 1
  fi
else
  # The lease makes the scan and the push ONE decision, evaluated by the remote
  # at the instant of the push. Anything that landed after `observed` was read
  # rejects the push instead of losing to it. An empty lease means the branch
  # must still not exist.
  if ! git push --force-with-lease="${BRANCH}:${observed}" origin "$BRANCH"; then
    msg="Declaring spec drift aborted: ${BRANCH} moved after this run read it (lease ${observed:-<absent>}), so the push was refused rather than overwriting the new commits. Nothing was lost; re-run."
    echo "::error::$msg"
    say "$msg"
    exit 1
  fi
fi

# `open_pr` was read before the push, and minutes can pass. Ask again: a pull
# request that closed in between must not be silently "updated" into a closed
# state, which leaves the branch current and nothing for anyone to read. Seen
# for real while proving this script, when the branch was reset by hand and
# GitHub auto-closed the pull request.
if [ -n "$open_pr" ]; then
  state="$(gh pr view "$open_pr" --repo "$REPO" --json state --jq '.state' 2>/dev/null || true)"
  if [ "$state" != "OPEN" ]; then
    echo "::warning::#${open_pr} is ${state:-unreadable}, not OPEN; reopening it for this declaration"
    gh pr reopen "$open_pr" --repo "$REPO" >/dev/null 2>&1 || open_pr=""
  fi
fi

if [ -n "$open_pr" ]; then
  # NOT `gh pr edit --body-file`. It exits 0 on this repository and leaves the
  # body unchanged - measured on 2026-10-02 while proving this script, where the
  # first update reported success and the pull request still described six
  # documents instead of seven. gh reaches the body through GraphQL, which
  # answers with a Projects-Classic deprecation error here, and the exit status
  # does not carry it. The REST route works, and the body is read back rather
  # than trusted: an update nobody can see is worse than none, because the run
  # says it happened.
  gh api "repos/$REPO/pulls/$open_pr" -X PATCH -F "body=@$BODY_FILE" >/dev/null
  # Normalized, not byte-compared: GitHub stores the body with CRLF line endings
  # and `gh api --jq` appends a newline of its own, so a raw diff reports a
  # mismatch on an update that landed perfectly - which would make this check
  # cry wolf on every run and teach the reader to ignore it, the same erosion
  # #2706 is about.
  if ! gh api "repos/$REPO/pulls/$open_pr" --jq '.body' \
       | python3 -c 'import sys;sys.exit(0 if sys.stdin.read().replace("\r","").rstrip("\n") == open(sys.argv[1],encoding="utf-8").read().rstrip("\n") else 1)' "$BODY_FILE"; then
    msg="Declaring spec drift: pushed ${#ROWS[@]} row(s) to ${BRANCH} but the body of #${open_pr} did not take the update. The diff on the branch is current; the description is not."
    echo "::warning::$msg"
    say "$msg"
  fi
  say "declare-spec-drift: updated ${REPO}#${open_pr} with ${#ROWS[@]} undeclared row(s) at spec ${SPEC}."
else
  url="$(gh pr create --repo "$REPO" --base main --head "$BRANCH" \
    --title "ci: declare the corpus documents the pinned engine predates" \
    --label chore --label area:tooling --body-file "$BODY_FILE")"
  say "declare-spec-drift: opened $url with ${#ROWS[@]} undeclared row(s) at spec ${SPEC}."
fi

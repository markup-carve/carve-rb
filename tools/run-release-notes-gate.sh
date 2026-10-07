#!/usr/bin/env bash
# The pre-publish release-notes gate, shared by release.yml and rehearse-release-notes.yml.
#
# Usage: tools/run-release-notes-gate.sh <tag> [--release-out FILE]
#        (reads GH_TOKEN and GITHUB_REPOSITORY)
#
# --release-out writes the release object this gate already fetched, so the
# publish step can read the draft id from it instead of fetching and checking a
# second time. release.yml carried a verbatim copy of the pipeline below for
# exactly that reason, and the two drifted: both spelled `python` rather than
# `python3`, so fixing this script alone left the copy broken
# (markup-carve/carve-rb#169, #171). The file is written only on success, so a
# caller that reads it is reading a release this gate passed.
set -eo pipefail

tag="$1"
shift || true
release_out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --release-out) release_out="$2"; shift 2 ;;
    *) echo "run-release-notes-gate: unknown argument $1" >&2; exit 2 ;;
  esac
done

release="$(gh api "repos/$GITHUB_REPOSITORY/releases?per_page=100" --paginate \
  | jq -cs --arg tag "$tag" '[.[][] | select(.tag_name == $tag)] | first // empty')"
if [ -z "$release" ]; then
  echo "::error::No release for $tag. Write its notes first."
  exit 1
fi
printf '%s' "$release" | python3 tools/check-release-notes.py \
  --tag "$tag" --repo "$GITHUB_REPOSITORY"
if [ -n "$release_out" ]; then
  printf '%s' "$release" > "$release_out"
fi

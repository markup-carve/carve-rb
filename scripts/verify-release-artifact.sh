#!/usr/bin/env bash
#
# Build-and-verify the artifact, in the order a release actually has to do it:
# install the .gem the way an embedder would, then drive the whole spec corpus
# through what that install produced.
#
# Usage:
#   CARVE_SPEC_CORPUS=<spec>/tests/corpus scripts/verify-release-artifact.sh <path/to/foo.gem>
#
# Exits non-zero if the gem cannot be installed, cannot be loaded, is not the
# package it claims to be, or renders any corpus document differently from the
# spec. release.yml runs this in a job the publish job `needs:`, so a non-zero
# exit here means the publish step never starts.
#
# The install goes into a GEM_HOME created for this run, and GEM_PATH is pinned
# to it alone. That is not tidiness: with the ambient gem path visible, an
# unrelated carve-lang already on the machine outranks the freshly installed one
# and `require "carve"` answers from it. That happened on the first local run of
# this script. The isolation makes it unlikely and the assertion inside
# verify-packaged-gem.rb makes it impossible to miss.

set -euo pipefail

GEM_FILE="${1:-}"
if [ -z "$GEM_FILE" ]; then
  echo "usage: $0 <path/to/carve-lang-X.Y.Z.gem>" >&2
  exit 2
fi
if [ ! -f "$GEM_FILE" ]; then
  echo "::error::no gem at $GEM_FILE" >&2
  exit 2
fi
if [ -z "${CARVE_SPEC_CORPUS:-}" ]; then
  echo "::error::CARVE_SPEC_CORPUS is not set; it must name the spec's tests/corpus directory." >&2
  echo "This gate never skips: an unset corpus path is a failure, not a pass." >&2
  exit 2
fi

GEM_FILE="$(cd "$(dirname "$GEM_FILE")" && pwd)/$(basename "$GEM_FILE")"
# Absolute, because the verifier runs from a scratch directory.
CARVE_SPEC_CORPUS="$(cd "$CARVE_SPEC_CORPUS" && pwd)"
export CARVE_SPEC_CORPUS
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Read from the metadata of the file being installed rather than from
# lib/carve/version.rb, so that the gate compares the package against itself
# and notices an install that resolved to some other build. Not from the file
# name: a platform gem's ends in its platform (carve-lang-0.1.0-x86_64-linux).
GEM_VERSION="$(ruby -rrubygems/package -e 'puts Gem::Package.new(ARGV[0]).spec.version' "$GEM_FILE")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/carve-release-gate.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# CARVE_GATE_GEM_HOME keeps the install for a second corpus run in the same job
# (ci.yml measures spec main after gating on the pinned corpus), so the native
# extension is compiled once. It is reused only for the identical .gem file.
if [ -n "${CARVE_GATE_GEM_HOME:-}" ]; then
  mkdir -p "$CARVE_GATE_GEM_HOME"
  GEM_HOME="$(cd "$CARVE_GATE_GEM_HOME" && pwd)"
else
    GEM_HOME="$WORK/gems"
fi
export GEM_HOME
export GEM_PATH="$GEM_HOME"
# Bundler's environment reaches into a `gem install` and a `ruby` run alike, and
# it points at this checkout's Gemfile -- which would put the source tree back
# on the load path, i.e. undo the one thing this script is for.
unset RUBYOPT BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_PATH RUBYLIB

GEM_SUM="$(sha256sum "$GEM_FILE" | cut -d' ' -f1)"
STAMP="$GEM_HOME/.carve-gate-installed"
if [ -n "${CARVE_GATE_GEM_HOME:-}" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$GEM_SUM" ]; then
  echo "==> reusing the install of $(basename "$GEM_FILE") in $GEM_HOME"
else
  echo "==> installing $(basename "$GEM_FILE") into $GEM_HOME"
  # Not --local: the gem declares rb_sys as a runtime dependency, and it has to be
  # resolvable inside the isolated GEM_PATH at require time, not merely present
  # somewhere on the machine. minitest carries the assertions that
  # test/corpus_population.rb -- the single derivation of the expected corpus
  # size, shared with the ordinary corpus gate -- is written against.
  gem install --no-document minitest
  gem install --no-document "$GEM_FILE"
  if [ -n "${CARVE_GATE_GEM_HOME:-}" ]; then echo "$GEM_SUM" > "$STAMP"; fi
fi

echo "==> corpus: $CARVE_SPEC_CORPUS"
cd "$WORK"
CARVE_PACKAGED_GEM_ROOT="$GEM_HOME" \
CARVE_PACKAGED_GEM="$GEM_FILE" \
CARVE_PACKAGED_GEM_VERSION="$GEM_VERSION" \
CARVE_SPEC_CORPUS="$CARVE_SPEC_CORPUS" \
  ruby -I "$REPO_ROOT/test" "$REPO_ROOT/scripts/verify-packaged-gem.rb"

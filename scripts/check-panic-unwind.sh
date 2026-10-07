#!/usr/bin/env bash
#
# check-panic-unwind.sh
#
# Regression guard for the FFI panic-safety net.
#
# A Rust panic in this extension unwinds, is caught, and is raised to Ruby as
# `Carve::EnginePanic` -- a StandardError a host can rescue. Two separate pieces
# produce that, and this script guards the first:
#
#   1. `panic = "unwind"` (the Cargo default) makes the panic unwindable at all,
#      so catch_unwind can run and the panic report keeps its location and any
#      RUST_BACKTRACE output.
#   2. `guard` in ext/carve/src/lib.rs catches that unwind and converts it.
#      Without it the panic still reaches Ruby -- magnus catches it too -- but as
#      `fatal`, which no host can rescue, so the process ends anyway
#      (markup-carve/carve-rb#170). `test/panic_unwind_test.rb` covers that half.
#
# If anyone later adds `panic = "abort"` to a tracked Cargo.toml (this crate or
# an inherited workspace profile), the unwind is silently removed: there is
# nothing left to catch or convert, and a panic aborts the Ruby interpreter.
#
# This script fails if any tracked Cargo.toml sets `panic = "abort"`.
# It is intentionally cheap so it can gate every CI run.
set -euo pipefail

cd "$(dirname "$0")/.."

# Only inspect git-tracked Cargo.toml files, so vendored/dependency copies
# under target/ or vendor/ cannot trip (or defeat) the guard.
mapfile -t cargo_tomls < <(git ls-files '*Cargo.toml' 'Cargo.toml')

if [ "${#cargo_tomls[@]}" -eq 0 ]; then
  echo "check-panic-unwind: no tracked Cargo.toml found" >&2
  exit 1
fi

# Match only an actual setting: `panic = "abort"` at the start of a line
# (optional leading whitespace). Lines beginning with `#` are comments (such as
# the explanatory note in Cargo.toml) and are intentionally NOT matched.
if grep -nE '^[[:space:]]*panic[[:space:]]*=[[:space:]]*"abort"' "${cargo_tomls[@]}"; then
  echo >&2
  echo "ERROR: 'panic = \"abort\"' found in a tracked Cargo.toml." >&2
  echo "This extension relies on catch_unwind (panic = \"unwind\") to convert a" >&2
  echo "Rust panic into a rescuable Carve::EnginePanic; 'abort' removes the" >&2
  echo "unwind entirely and would let a panic kill the host." >&2
  echo "Remove the 'panic = \"abort\"' setting." >&2
  exit 1
fi

echo "check-panic-unwind: OK (no panic = \"abort\" in tracked Cargo.toml)"

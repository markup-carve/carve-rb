#!/usr/bin/env bash
#
# check-panic-unwind.sh
#
# Regression guard for the FFI panic-safety net.
#
# magnus wraps every Rust call this extension exposes in catch_unwind, so a
# Rust panic surfaces as a Ruby exception instead of aborting the host process.
# That conversion ONLY works when the extension crate is compiled with
# `panic = "unwind"` (the Cargo default). If anyone later adds
# `panic = "abort"` to a tracked Cargo.toml (this crate or an inherited
# workspace profile), catch_unwind is silently removed and a panic would abort
# the Ruby interpreter.
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
  echo "magnus relies on catch_unwind (panic = \"unwind\") to turn Rust panics" >&2
  echo "into Ruby exceptions; 'abort' would let a panic kill the host." >&2
  echo "Remove the 'panic = \"abort\"' setting." >&2
  exit 1
fi

echo "check-panic-unwind: OK (no panic = \"abort\" in tracked Cargo.toml)"

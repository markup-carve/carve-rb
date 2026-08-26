#!/usr/bin/env python3
"""Enforce the spec-main drift report against the declared window.

The drift comparison in ci.yml used to report and never fail. It failed only
when NO count had been logged at all, so the one thing it could not do was fail
on a count - and on 2026-08-23 it printed `50 of 1475 corpus documents render
differently at spec main` and passed, in the same run where the pin was 44
commits behind and the age-based `engine-pin` guard also passed
(markup-carve/carve-rb#100).

This script is the failure condition that was missing. It reads the drift log,
takes the set of documents that actually diverge, and compares it against
resources/spec-drift.txt:

    UNDECLARED  diverging and not in the ledger  -> FAILS
    declared    diverging and in the ledger      -> passes, reported
    stale       in the ledger and not diverging  -> reported, does not fail
                (it fails under --require-empty-ledger)

That split is markup-carve/carve#1811's ruling, applied here: a declared window
is the normal consequence of the spec leading the engine and exists to be
described, an undeclared one is the state nobody knows they are in. Both are
cleared by an action taken in THIS repository - bump the pin, or write the row
down - which is what distinguishes this from the age and distance proxies
markup-carve/carve-go#44 deleted rather than retuned.

--require-empty-ledger is the release gate's mode: at a tag, every declared
window must be closed, so a non-empty ledger is a refusal.

It also keeps the guard the old shape had, because that guard was real: a run
that logged NEITHER a divergence count nor a byte-identical count measured
nothing, and a comparison that silently measures nothing is the check that
cannot fail (markup-carve/carve#755). That is still a failure.

Usage:
  scripts/check-spec-drift.py --log drift.log [--ledger resources/spec-drift.txt]
                              [--spec <short-sha>] [--github]
  scripts/check-spec-drift.py --require-empty-ledger [--ledger ...] [--github]

Exit codes: 0 clear, 1 refused, 2 misuse.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# `corpus mismatch: <basename>`, one line per diverging document, printed by
# scripts/verify-packaged-gem.rb. Parsing THAT rather than the assertion message
# is deliberate: the message truncates at twenty names and appends `...`, so a
# ledger comparison built on it would call every document past the twentieth
# undeclared no matter what the ledger says.
MISMATCH = re.compile(r"^corpus mismatch: (\S+)\s*$", re.M)
# The two headline counts. Their presence is the evidence that a comparison ran
# at all; only the mismatch lines decide the verdict.
DIVERGING = re.compile(r"(\d+) of (\d+) corpus documents render differently")
IDENTICAL = re.compile(r"(\d+) of (\d+) declared corpus documents byte-identical")


def annotate(level: str, message: str, github: bool) -> None:
    if github:
        print(f"::{level}::{message}")
    stream = sys.stderr if level == "error" else sys.stdout
    print(f"{level}: {message}", file=stream)


def read_ledger(path: Path) -> list[str]:
    if not path.exists():
        raise SystemExit(f"check-spec-drift: no ledger at {path}")
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        row = line.split("#", 1)[0].strip()
        if row:
            rows.append(row)
    return rows


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--log", type=Path, help="the drift run's log")
    p.add_argument(
        "--ledger",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "resources" / "spec-drift.txt",
    )
    p.add_argument("--spec", default="", help="short sha of the spec the log was measured against")
    p.add_argument(
        "--require-empty-ledger",
        action="store_true",
        help="release mode: refuse a non-empty ledger, with or without a log",
    )
    p.add_argument("--github", action="store_true", help="emit GitHub Actions annotations")
    args = p.parse_args(argv)

    declared = read_ledger(args.ledger)

    if args.require_empty_ledger:
        if declared:
            annotate(
                "error",
                f"{len(declared)} declared drift row(s) in {args.ledger} are still open: "
                f"{', '.join(declared[:20])}"
                f"{' ...' if len(declared) > 20 else ''}. A declared window is a window "
                "still open, and a tag must not ship one. Bump the carve-rs revision in "
                "ext/carve/Cargo.toml, commit the regenerated ext/carve/Cargo.lock, and "
                "delete the rows the bump closed.",
                args.github,
            )
            return 1
        print(f"check-spec-drift: {args.ledger} declares no open drift; clear to tag.")
        if not args.log:
            return 0

    if not args.log:
        p.error("--log is required unless --require-empty-ledger is given alone")
    if not args.log.exists():
        annotate("error", f"no drift log at {args.log}, so nothing was measured", args.github)
        return 1

    log = args.log.read_text(encoding="utf-8", errors="replace")
    diverging = sorted(set(MISMATCH.findall(log)))
    headline_diverging = DIVERGING.search(log)
    headline_identical = IDENTICAL.search(log)

    # The old guard, kept. A log with neither headline is a run whose comparison
    # never happened - a corpus that moved, a spec layout this no longer finds, a
    # gem that will not install - and an empty diverging set then means "nothing
    # measured", not "nothing wrong".
    if not headline_diverging and not headline_identical:
        annotate(
            "error",
            "the drift run logged neither a divergence count nor a byte-identical count, "
            "so nothing was measured",
            args.github,
        )
        sys.stderr.write("".join(log.splitlines(keepends=True)[-40:]))
        return 1

    # A headline that counts divergence but no per-document lines is the same
    # hole one layer in: the verdict would be computed from an empty set.
    if headline_diverging and int(headline_diverging.group(1)) and not diverging:
        annotate(
            "error",
            f"the log reports {headline_diverging.group(1)} diverging document(s) but printed "
            "no `corpus mismatch:` lines, so the ledger comparison had nothing to compare. "
            "scripts/verify-packaged-gem.rb prints one line per mismatch; that print is what "
            "this gate reads.",
            args.github,
        )
        return 1

    at_spec = f" at spec main ({args.spec})" if args.spec else ""
    total = headline_diverging.group(2) if headline_diverging else (
        headline_identical.group(2) if headline_identical else "?"
    )

    undeclared = [name for name in diverging if name not in declared]
    stale = [name for name in declared if name not in diverging]

    print(f"declared drift rows: {len(declared)}")
    print(f"diverging documents: {len(diverging)} of {total}{at_spec}")
    for name in diverging:
        print(f"  {'UNDECLARED' if name in undeclared else 'declared  '} {name}")

    if stale:
        annotate(
            "notice",
            f"{len(stale)} declared drift row(s) no longer diverge and can be dropped from "
            f"{args.ledger}: {', '.join(stale[:20])}{' ...' if len(stale) > 20 else ''}",
            args.github,
        )

    if undeclared:
        annotate(
            "error",
            f"{len(undeclared)} of {len(diverging)} diverging document(s){at_spec} are "
            f"UNDECLARED: {', '.join(undeclared[:20])}"
            f"{' ...' if len(undeclared) > 20 else ''}. This gem renders them differently from "
            "the spec and nothing said so. Either bump the carve-rs revision in "
            "ext/carve/Cargo.toml (with the regenerated ext/carve/Cargo.lock) so they stop "
            f"diverging, or declare them in {args.ledger} with the reason.",
            args.github,
        )
        return 1

    if diverging:
        print(
            f"check-spec-drift: all {len(diverging)} diverging document(s) are declared. "
            "The window is known; it must be closed before a tag."
        )
    else:
        print(f"check-spec-drift: no document diverges from spec main{at_spec}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

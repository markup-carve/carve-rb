#!/usr/bin/env python3
"""Print the newest carve-lang version published on crates.io.

WHY THIS EXISTS. Since markup-carve/carve-rb#136 the gem pins a PUBLISHED
crate rather than a carve-rs revision, so "the newest engine this repository
can be on" became a crates.io fact. The binding-parity gate needs it to tell
apart two states its failure message used to merge:

  * the pin is behind a published carve-lang - one line in ext/carve/Cargo.toml
    plus the lock closes it, which is the property that gate was built on;
  * carve-rs has merged past its last release - nothing here can close that,
    because there is no version for the pin to move to.

Reads the sparse index rather than the web API: it is the file cargo itself
resolves against, it needs no token and no user-agent rule, and it carries the
yank flag this has to honor.

`--index PATH` reads a local copy instead, which is how the test covers the
ordering without a network call. Ordering is numeric per component on purpose:
`sort` puts 0.1.10 before 0.1.9.

Exit codes: 0 the version was printed, 1 the index answered nothing usable,
2 it could not be read. There is no fallback to a guess - a wrong answer here
turns a stale pin into a declared window.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

INDEX_URL = "https://index.crates.io/ca/rv/carve-lang"

# Releases only. A prerelease is not something this gem's pin should track, and
# it must never be read as "the pin is already current".
RELEASE_RE = re.compile(r"(\d+)\.(\d+)\.(\d+)")


def newest(body: str, source: str) -> str:
    published: list[tuple[tuple[int, int, int], str]] = []
    for line in body.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError as error:
            print(
                f"newest-published-engine: {source} is not newline-delimited JSON: {error}",
                file=sys.stderr,
            )
            raise SystemExit(1)
        if entry.get("yanked"):
            continue
        version = str(entry.get("vers", ""))
        match = RELEASE_RE.fullmatch(version)
        if match:
            published.append(((int(match[1]), int(match[2]), int(match[3])), version))

    if not published:
        print(
            f"newest-published-engine: {source} lists no released carve-lang version.",
            file=sys.stderr,
        )
        raise SystemExit(1)

    return max(published)[1]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--index", type=Path, help="read a local copy of the sparse index entry")
    arguments = parser.parse_args(argv)

    if arguments.index is not None:
        try:
            body = arguments.index.read_text(encoding="utf-8")
        except OSError as error:
            print(f"newest-published-engine: {arguments.index} is not readable: {error}", file=sys.stderr)
            return 2
        print(newest(body, str(arguments.index)))
        return 0

    try:
        with urllib.request.urlopen(INDEX_URL, timeout=30) as response:
            body = response.read().decode("utf-8")
    except (urllib.error.URLError, OSError, ValueError) as error:
        print(f"newest-published-engine: could not read {INDEX_URL}: {error}", file=sys.stderr)
        return 2

    print(newest(body, INDEX_URL))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

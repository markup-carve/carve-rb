#!/usr/bin/env python3
"""Print the spec commit that the carve-rs revision this package pins was written against.

WHY THIS EXISTS. The blocking corpus gate used to check out markup-carve/carve
at its DEFAULT BRANCH. That asks: is this artifact conformant with the spec as
it stands right now? No change in this repository can answer yes to that. The
spec adds documents continuously - it gained a whole category on 2026-08-18
while a release was in flight - and an engine implements them some time later.
In between, every pull request here is red for a reason that has nothing to do
with its diff, and the fix lives in another repository.

That is how it actually failed. carve-py's v0.1.1 tag built all three wheels,
published its GitHub release, and then SKIPPED `Publish to PyPI` because the
gate held the wheel to corpus category 367, which does not exist at the spec
commit that release pins and which no engine revision available that day
rendered. The tag said 0.1.1 and `pip install` served the vulnerable 0.1.0.

A gate in that state cannot pass by construction whenever the spec moves after
an engine is tagged, which is always. And a gate that cannot pass is a gate
everyone learns to skip - the "check that cannot fail" of markup-carve/carve#755
arriving by the opposite road.

The question this repository CAN answer, and the only one it can act on, is
whether the artifact is as conformant as the engine it was built from. The
pinned carve-rs revision's `tests/spec` gitlink names the spec that engine was
written against, and the corpus at that commit is what it claims to implement.
That is the commit this prints, and holding the gate to it is what makes the
gate clearable by an action taken here: bump the pin.

WHAT THIS DELIBERATELY DOES NOT BUY. An artifact that is simply OLD - pin and
bytes agreeing on an engine from a month ago - passes the gate that uses this.
That is what the non-blocking `corpus-drift` job reports, and it is why deleting
that job would turn the re-aiming into a loosening.

This is modelled on the same resolution carve-go performs inline in its `corpus`
job. It is a script rather than four copies of a shell snippet because two
workflows here (ci.yml and release.yml) need the identical answer, and two
spellings of one rule is how they come to disagree.

    python3 scripts/pinned-spec-commit.py \
        --engine carve-rs --manifest Cargo.toml --lock Cargo.lock

Exit codes: 0 the commit was resolved and printed on stdout, 1 the pin or the
gitlink could not be resolved, 2 usage or setup error.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - 3.10 and older
    print(
        "pinned-spec-commit: needs Python 3.11+ for tomllib. Parsing Cargo.toml "
        "and Cargo.lock with a regular expression is how a pin gets misread, so "
        "there is no fallback on purpose.",
        file=sys.stderr,
    )
    raise SystemExit(2)

ENGINE_PACKAGE = "carve-lang"
ENGINE_REPO_RE = re.compile(r"carve-rs(\.git)?/?$")
FULL_REV_RE = re.compile(r"^[0-9a-f]{40}$")

# `git+<url>?rev=<rev>#<resolved>` - cargo writes the resolved commit after the
# fragment, and that is the one it actually fetched and built.
LOCK_SOURCE_RE = re.compile(r"^git\+(?P<url>[^?#]+)(\?rev=(?P<rev>[^#]+))?(#(?P<resolved>.+))?$")

SPEC_PATH = "tests/spec"


def fail(message: str) -> None:
    print(f"pinned-spec-commit: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_toml(path: Path) -> dict:
    if not path.is_file():
        fail(f"{path} does not exist, so there is no pin to read.")
    try:
        with path.open("rb") as handle:
            return tomllib.load(handle)
    except OSError as error:
        fail(f"{path} is not readable: {error}")
    except tomllib.TOMLDecodeError as error:
        fail(f"{path} is not valid TOML: {error}")
    raise AssertionError("unreachable")


def manifest_revision(manifest: Path) -> str:
    """The revision the MANIFEST names, found by URL rather than by key.

    The dependency key is spelled differently in every binding (`carve_rs` here
    and in carve-rb, `carve` in carve-wasm) and the crate publishes as
    `carve-lang` rather than `carve`, so a reader that greps for a name finds
    the binding's own package and concludes there is no pin. Match the git URL.
    """
    document = load_toml(manifest)
    found: list[str] = []
    for table in ("dependencies", "dev-dependencies", "build-dependencies"):
        for name, entry in (document.get(table) or {}).items():
            if not isinstance(entry, dict):
                continue
            url = entry.get("git")
            if not isinstance(url, str) or not ENGINE_REPO_RE.search(url.rstrip("/")):
                continue
            rev = entry.get("rev")
            if not isinstance(rev, str):
                fail(
                    f"{manifest} declares `{name}` against {url} without a `rev`. "
                    "A branch or tag dependency does not name a commit, so there is no "
                    "spec commit to hold this artifact to."
                )
            found.append(rev)
    if not found:
        # A reader that quietly finds nothing is the defect this replaces: it
        # would resolve to "no divergence" and certify anything.
        fail(
            f"{manifest} declares no git dependency on carve-rs. The engine pin is what "
            "names the spec this artifact is held to; without it there is nothing to gate on."
        )
    if len(set(found)) != 1:
        fail(f"{manifest} names more than one carve-rs revision: {', '.join(sorted(set(found)))}.")
    return found[0]


def lock_revision(lock: Path) -> str:
    """The revision the LOCKFILE resolved, which is what cargo actually built."""
    document = load_toml(lock)
    found: list[str] = []
    for package in document.get("package") or []:
        if package.get("name") != ENGINE_PACKAGE:
            continue
        source = package.get("source")
        if not isinstance(source, str):
            continue
        match = LOCK_SOURCE_RE.match(source)
        if not match or not ENGINE_REPO_RE.search(match.group("url").rstrip("/")):
            continue
        resolved = match.group("resolved") or match.group("rev")
        if not resolved:
            fail(f"{lock} has a git source for {ENGINE_PACKAGE} that names no commit: {source}")
        found.append(resolved)
    if not found:
        fail(
            f"{lock} carries no git-sourced `{ENGINE_PACKAGE}` package. The crate publishes "
            f"as `{ENGINE_PACKAGE}`, not `carve`; a lockfile without it is not this project's."
        )
    if len(set(found)) != 1:
        fail(f"{lock} resolves more than one carve-rs revision: {', '.join(sorted(set(found)))}.")
    return found[0]


def spec_gitlink(engine: Path, revision: str) -> str:
    """The `tests/spec` gitlink at that revision - the spec the engine was written against."""
    if not (engine / ".git").exists():
        fail(f"--engine {engine} is not a git checkout of carve-rs.")
    try:
        completed = subprocess.run(
            ["git", "-C", str(engine), "ls-tree", revision, SPEC_PATH],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:
        print(f"pinned-spec-commit: could not run git: {error}", file=sys.stderr)
        raise SystemExit(2)
    if completed.returncode != 0:
        fail(
            f"carve-rs {revision} could not be read in {engine}: "
            f"{completed.stderr.strip() or 'git ls-tree failed'}. A shallow clone has only the "
            "tip's tree; check out carve-rs with fetch-depth: 0."
        )
    line = completed.stdout.strip()
    if not line:
        fail(
            f"carve-rs {revision} has no `{SPEC_PATH}` gitlink, so there is no spec commit to "
            "hold this artifact to."
        )
    fields = line.split()
    if len(fields) < 3 or fields[1] != "commit":
        fail(f"`{SPEC_PATH}` at carve-rs {revision} is not a submodule gitlink: {line}")
    spec = fields[2]
    if not FULL_REV_RE.match(spec):
        fail(f"the `{SPEC_PATH}` gitlink at carve-rs {revision} is not a full revision: {spec}")
    return spec


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Resolve the spec commit the pinned engine pins.")
    parser.add_argument("--engine", required=True, type=Path, help="path to a carve-rs checkout")
    parser.add_argument("--manifest", required=True, type=Path, help="path to Cargo.toml")
    parser.add_argument("--lock", required=True, type=Path, help="path to Cargo.lock")
    arguments = parser.parse_args(argv)

    manifest_rev = manifest_revision(arguments.manifest)
    locked_rev = lock_revision(arguments.lock)

    for label, revision in (("manifest", manifest_rev), ("lock", locked_rev)):
        if not FULL_REV_RE.match(revision):
            fail(
                f"the {label} names carve-rs {revision!r}, which is not 40 lowercase hex "
                "characters. An abbreviated or upper-case revision resolves locally and then "
                "matches nothing."
            )

    # Read from the lock's OWN source line rather than from the manifest twice:
    # reading one file twice is what makes two files "agree" without either
    # checking the other.
    if manifest_rev != locked_rev:
        fail(
            f"{arguments.manifest} pins carve-rs {manifest_rev} but {arguments.lock} resolved "
            f"{locked_rev}. The build follows the lock, so it is not the revision the manifest "
            "advertises; regenerate the lock and commit it."
        )

    spec = spec_gitlink(arguments.engine, locked_rev)
    print(f"carve-rs {locked_rev} pins spec {spec}", file=sys.stderr)
    print(spec)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

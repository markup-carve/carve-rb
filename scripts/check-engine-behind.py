#!/usr/bin/env python3
"""Hold resources/engine-behind.txt to the corpus pairs the pinned carve-rs declares.

    python3 scripts/check-engine-behind.py --engine carve-rs [--write]
"""
import argparse
import importlib.util
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import engine_behind  # noqa: E402


def pinned_revision(engine, manifest, lock):
    """The carve-rs commit the lock resolved, a git rev or a published version's tag."""
    path = pathlib.Path(__file__).resolve().parent / "pinned-spec-commit.py"
    spec = importlib.util.spec_from_file_location("pinned_spec_commit", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    pin = module.lock_pin(pathlib.Path(lock))
    if module.manifest_pin(pathlib.Path(manifest)) != pin:
        raise SystemExit(f"check-engine-behind: {manifest} and {lock} pin different engines.")
    return module.resolve_pin(pathlib.Path(engine), pin)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", required=True, help="a full carve-rs checkout")
    parser.add_argument("--manifest", default="ext/carve/Cargo.toml")
    parser.add_argument("--lock", default="ext/carve/Cargo.lock")
    parser.add_argument("--write", action="store_true", help="rewrite resources/engine-behind.txt from the engine")
    arguments = parser.parse_args()

    revision = pinned_revision(arguments.engine, arguments.manifest, arguments.lock)
    source = subprocess.run(
        ["git", "-C", arguments.engine, "show", f"{revision}:tests/corpus.rs"],
        capture_output=True, text=True, check=True,
    ).stdout
    engine = engine_behind.from_engine_source(source)
    if arguments.write:
        engine_behind.write(engine)
        print(f"check-engine-behind: wrote {len(engine)} pair(s) from carve-rs {revision[:12]}")
        return
    local = engine_behind.load()
    if local != engine:
        missing = sorted(set(engine) - set(local))
        extra = sorted(set(local) - set(engine))
        changed = sorted(s for s in set(engine) & set(local) if engine[s] != local[s])
        print(
            f"check-engine-behind: engine-behind.txt does not match carve-rs {revision[:12]}.\n"
            f"  declared by the engine, missing here: {missing}\n"
            f"  listed here, not declared by the engine: {extra}\n"
            f"  declared HTML differs: {changed}\n"
            "Run `python3 scripts/check-engine-behind.py --engine <carve-rs> --write`.",
            file=sys.stderr,
        )
        raise SystemExit(1)
    print(f"check-engine-behind: {len(local)} pair(s) match carve-rs {revision[:12]}")


if __name__ == "__main__":
    main()

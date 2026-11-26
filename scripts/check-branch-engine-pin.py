#!/usr/bin/env python3
"""Check the binding's direct Cargo engine pin against its matching branch."""

import argparse
import datetime as dt
import importlib.util
import pathlib
import subprocess

p = argparse.ArgumentParser()
p.add_argument("--manifest", type=pathlib.Path, required=True)
p.add_argument("--lock", type=pathlib.Path, required=True)
p.add_argument("--engine", type=pathlib.Path, required=True)
p.add_argument("--branch", required=True)
p.add_argument("--max-age-days", type=float)
a = p.parse_args()

spec = importlib.util.spec_from_file_location("pin_reader", pathlib.Path(__file__).with_name("pinned-spec-commit.py"))
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)
declared = reader.manifest_pin(a.manifest)
resolved = reader.lock_pin(a.lock)
if declared != resolved:
    p.error(f"manifest pins {declared}, but lock resolves {resolved}")
revision = reader.resolve_pin(a.engine, resolved)

def git(*args):
    return subprocess.run(["git", "-C", str(a.engine), *args], text=True, capture_output=True)

branch = f"origin/{a.branch}"
if git("rev-parse", "--verify", branch).returncode:
    p.error(f"engine checkout lacks {branch}")
if git("merge-base", "--is-ancestor", revision, branch).returncode:
    p.error(f"engine pin {revision} is not reachable from {branch}")
if a.max_age_days is not None:
    stamp = git("show", "-s", "--format=%ct", revision)
    if stamp.returncode:
        p.error(f"cannot read engine commit {revision}")
    age = (dt.datetime.now(dt.timezone.utc).timestamp() - int(stamp.stdout.strip())) / 86400
    if age > a.max_age_days:
        p.error(f"engine pin is {age:.1f} days old, over {a.max_age_days:g}")
print(f"engine pin {revision} is on {branch} and matches the lock")

#!/usr/bin/env python3
"""Compare a `flutter test --file-reporter json:` report with the Linux baseline.

    flutter test --file-reporter json:suite.json
    python3 tool/ci/compare.py suite.json tool/ci/linux-baseline.tsv

Golden mismatches are left to the Goldens workflow, which renders on macOS.
Every other failure must be listed in the baseline. Prints the counts, each
failure the baseline doesn't list, and each baseline test that passed. Exits 1
on a new failure or on a run that didn't finish.
"""
import json
import re
import sys

GOLDEN = re.compile(r'Pixel test failed|Golden "|non-existent file')

report, baseline_path = sys.argv[1], sys.argv[2]
baseline = set()
for line in open(baseline_path, encoding="utf-8"):
    if line.startswith("#") or not line.strip():
        continue
    _, path, name = line.rstrip("\n").split("\t", 2)
    baseline.add((path, name))

suites, tests, done, errors, golden = {}, {}, {}, {}, set()
finished = False
for line in open(report, encoding="utf-8", errors="replace"):
    if not line.startswith("{"):
        continue
    try:
        e = json.loads(line)
    except json.JSONDecodeError:
        continue
    kind = e.get("type")
    if kind == "suite":
        path = e["suite"]["path"]
        suites[e["suite"]["id"]] = path[path.find("/test/") + 1:] if "/test/" in path else path
    elif kind == "testStart":
        tests[e["test"]["id"]] = e["test"]
    elif kind == "testDone":
        done[e["testID"]] = e
    elif kind in ("error", "print"):
        text = e.get("error") or e.get("message") or ""
        if GOLDEN.search(text):
            golden.add(e["testID"])
        if kind == "error":
            errors.setdefault(e["testID"], text)
    elif kind == "done":
        finished = True

passed = skipped = goldens = 0
new, known, fixed = [], [], []
for tid, d in done.items():
    t = tests[tid]
    key = (suites.get(t["suiteID"], "?"), t["name"])
    if d.get("hidden") and d["result"] == "success":
        continue
    if d.get("skipped"):
        skipped += 1
    elif d["result"] == "success":
        passed += 1
        if key in baseline:
            fixed.append(key)
    elif tid in golden:
        goldens += 1
    elif key in baseline:
        known.append(key)
    else:
        new.append((key, (errors.get(tid, "").strip().splitlines() or [""])[0]))

print(f"passed {passed}, skipped {skipped}, failed {len(new) + len(known) + goldens}: "
      f"{len(known)} in the baseline, {goldens} golden mismatches left to the Goldens "
      f"workflow, {len(new)} new")
if not finished:
    print("- The run didn't finish, so these counts are incomplete.")
for (path, name), why in sorted(new):
    print(f"- NEW `{path}` :: {name} :: {why}")
for path, name in sorted(fixed):
    print(f"- PASSES `{path}` :: {name} :: delete its line from the baseline")
sys.exit(1 if new or not finished else 0)

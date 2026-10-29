"""Plain-words summary of a feature test run, as Markdown.

python summary.py <flutter json report> [crawl report dir]
"""

import glob
import json
import os
import sys
from collections import defaultdict


def server_tests(path):
    suites, tests, errors = {}, {}, defaultdict(list)
    results = {}
    with open(path) as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            t = e.get("type")
            if t == "suite":
                suites[e["suite"]["id"]] = e["suite"].get("path") or "?"
            elif t == "testStart":
                tests[e["test"]["id"]] = e["test"]
            elif t == "error":
                errors[e["testID"]].append(e.get("error", ""))
            elif t == "testDone" and not e.get("hidden"):
                results[e["testID"]] = (
                    "skipped" if e.get("skipped") else e.get("result"))
    by_file = defaultdict(lambda: defaultdict(list))
    for tid, result in results.items():
        test = tests.get(tid, {})
        name = os.path.basename(suites.get(test.get("suiteID"), "?"))
        area = name.replace("_test.dart", "").replace("_", " ")
        by_file[area][result].append((test.get("name", "?"), errors[tid]))
    out = ["## Server tests", ""]
    total = defaultdict(int)
    rows = []
    for area in sorted(by_file):
        r = by_file[area]
        for k, v in r.items():
            total[k] += len(v)
        bad = r["failure"] + r["error"]
        state = "fail" if bad else "pass" if r["success"] else "skipped"
        rows.append(f"| {area} | {state} | {len(r['success'])} | "
                    f"{len(bad)} | {len(r['skipped'])} |")
    out.append(f"{total['success']} passed, "
               f"{total['failure'] + total['error']} failed, "
               f"{total['skipped']} skipped.")
    out += ["", "| Area | Result | Passed | Failed | Skipped |",
            "|---|---|---|---|---|", *rows, ""]
    for area in sorted(by_file):
        for name, errs in by_file[area]["failure"] + by_file[area]["error"]:
            first = (errs[0].strip().splitlines() or ["?"])[0] if errs else "?"
            out.append(f"- **{area}: {name}**: {first[:300]}")
    return out


def crawl(folder):
    out = []
    for path in sorted(glob.glob(os.path.join(folder, "crawl-*.json"))):
        r = json.load(open(path))
        kinds = defaultdict(list)
        for p in r["problems"]:
            kinds[p["kind"]].append(p)
        out += ["", f"## Screen crawl: {r['mode']}", "",
                f"{len(r['pages'])} pages opened, {r['taps']} buttons tapped, "
                f"{len(r['skipped'])} left alone, "
                f"{len(r['problems'])} problems."]
        for kind, ps in kinds.items():
            out += ["", f"### {kind} ({len(ps)})", ""]
            for p in ps[:40]:
                msg = p["message"].splitlines()[0][:200]
                out.append(f"- {p['where']} / {p['control']}: {msg}")
    return out


if __name__ == "__main__":
    lines = []
    if len(sys.argv) > 1 and os.path.exists(sys.argv[1]):
        lines += server_tests(sys.argv[1])
    if len(sys.argv) > 2 and os.path.isdir(sys.argv[2]):
        lines += crawl(sys.argv[2])
    print("\n".join(lines) or "No results.")

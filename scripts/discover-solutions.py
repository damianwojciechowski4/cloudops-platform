#!/usr/bin/env python3
"""
Wykrywa rozwiazania (katalogi z .solution.yml pod cloudformation/ i sam/), ktore
zmienily sie miedzy dwoma commitami.

    discover-solutions.py <base-sha> <head-sha> [repo-root]

Katalog top-level = tool. 'foundation' w sciezce = ignorowane (bootstrap reczny).
Zmiana w <tool>/_shared/ = wszystkie rozwiazania tego toola. base == 40 zer = pelny skan.
Wyjscie: JSON; przy GITHUB_OUTPUT dopisuje solutions=<json> i count=<n>.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import yaml  # pip install pyyaml

TOOLS = ("cloudformation", "sam")
REQUIRED = ("domain", "name", "order", "template")
ZERO_SHA = "0" * 40


def changed_files(repo: Path, base: str, head: str):
    if not base or base == ZERO_SHA:
        return None
    out = subprocess.check_output(["git", "diff", "--name-only", f"{base}..{head}"], cwd=repo, text=True)
    return [line for line in out.splitlines() if line]


def load_solutions(repo: Path, prefix: str):
    solutions = []
    for tool in TOOLS:
        root = repo / tool
        if not root.is_dir():
            continue
        for meta_file in sorted(root.rglob(".solution.yml")):
            rel = meta_file.parent.relative_to(repo)
            if "foundation" in rel.parts:
                continue
            meta = yaml.safe_load(meta_file.read_text()) or {}
            missing = [k for k in REQUIRED if k not in meta]
            if missing:
                sys.exit(f"{rel}/.solution.yml: brak pol {missing}")
            solutions.append({
                "tool": tool,
                "dir": rel.as_posix(),
                "domain": meta["domain"],
                "name": meta["name"],
                "stack_base": f"{prefix}-{meta['domain']}-{meta['name']}",
                "order": int(meta["order"]),
                "template": meta["template"],
                "parameters": meta.get("parameters") or "",
                "capabilities": meta.get("capabilities") or [],
            })
    return solutions


def select(solutions, changed):
    if changed is None:
        return solutions
    shared_tools = {t for t in TOOLS if any(f.startswith(f"{t}/_shared/") for f in changed)}
    return [
        s for s in solutions
        if s["tool"] in shared_tools or any(f.startswith(s["dir"] + "/") for f in changed)
    ]


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    base, head = argv[1:3]
    repo = Path(argv[3] if len(argv) > 3 else os.getcwd()).resolve()
    prefix = os.environ.get("PREFIX", "cloudops")
    result = sorted(select(load_solutions(repo, prefix), changed_files(repo, base, head)),
                    key=lambda s: (s["order"], s["dir"]))
    payload = json.dumps(result)
    print(payload)
    if gh_out := os.environ.get("GITHUB_OUTPUT"):
        with open(gh_out, "a", encoding="utf-8") as fh:
            fh.write(f"solutions={payload}\ncount={len(result)}\n")


if __name__ == "__main__":
    main(sys.argv)

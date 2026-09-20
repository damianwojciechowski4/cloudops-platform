"""pytest scripts/ - testy discover-solutions.py na tymczasowym repo git, bez AWS."""
import importlib.util
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "discover-solutions.py"
spec = importlib.util.spec_from_file_location("discover", SCRIPT)
discover = importlib.util.module_from_spec(spec)
spec.loader.exec_module(discover)


def git(repo, *args):
    return subprocess.check_output(["git", *args], cwd=repo, text=True).strip()


def commit(repo, files: dict, msg="c"):
    for rel, content in files.items():
        p = repo / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
    git(repo, "add", "-A")
    git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", msg)
    return git(repo, "rev-parse", "HEAD")


def sol(domain, name, order):
    return f"domain: {domain}\nname: {name}\norder: {order}\ntemplate: template.yaml\n"


@pytest.fixture
def repo(tmp_path):
    git(tmp_path, "init", "-q", "-b", "main")
    base = commit(tmp_path, {
        "cloudformation/networking/vpc/.solution.yml": sol("net", "vpc", 20),
        "cloudformation/networking/vpc/template.yaml": "a",
        "cloudformation/networking/ipam/.solution.yml": sol("net", "ipam", 10),
        "cloudformation/networking/ipam/template.yaml": "a",
        "cloudformation/foundation/cicd-bootstrap/.solution.yml": sol("cicd", "boot", 1),
        "cloudformation/foundation/cicd-bootstrap/template.yaml": "a",
        "sam/networking/hello/.solution.yml": sol("net", "hello", 30),
        "sam/networking/hello/template.yaml": "a",
    })
    return tmp_path, base


def run(repo, base, head):
    files = discover.changed_files(repo, base, head)
    sols = discover.load_solutions(repo, "cloudops")
    return sorted(discover.select(sols, files), key=lambda s: (s["order"], s["dir"]))


def test_no_changes(repo):
    r, base = repo
    assert run(r, base, base) == []


def test_only_changed_solution_in_same_top_level(repo):
    r, base = repo
    head = commit(r, {"cloudformation/networking/vpc/template.yaml": "b"})
    out = run(r, base, head)
    assert [(s["tool"], s["name"]) for s in out] == [("cloudformation", "vpc")]
    assert out[0]["stack_base"] == "cloudops-net-vpc"


def test_shared_hits_only_that_tool(repo):
    r, base = repo
    head = commit(r, {"cloudformation/_shared/x.yaml": "x"})
    assert [s["name"] for s in run(r, base, head)] == ["ipam", "vpc"]   # bez sam/hello


def test_foundation_ignored(repo):
    r, base = repo
    head = commit(r, {"cloudformation/foundation/cicd-bootstrap/template.yaml": "b"})
    assert run(r, base, head) == []


def test_zero_sha_full_scan_sorted(repo):
    r, base = repo
    assert [s["name"] for s in run(r, "0" * 40, base)] == ["ipam", "vpc", "hello"]

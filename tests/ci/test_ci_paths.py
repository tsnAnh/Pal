from __future__ import annotations

import importlib.machinery
import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest
from ruamel.yaml import YAML

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "ci_paths.py"
WORKFLOWS = REPO / ".github" / "workflows"
sys.path.insert(0, str(SCRIPT.parent))
import ci_paths


def _workflow(name: str) -> dict:
    return YAML(typ="base").load((WORKFLOWS / name).read_text(encoding="utf-8"))


def _scripts_check_names() -> tuple[str, ...]:
    loader = importlib.machinery.SourceFileLoader("scripts_check", str(REPO / "scripts" / "check"))
    spec = importlib.util.spec_from_loader("scripts_check", loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules["scripts_check"] = module
    try:
        loader.exec_module(module)
    finally:
        del sys.modules["scripts_check"]
    return module._CHECKS


def test_every_scripts_check_declares_what_it_reads():
    assert set(_scripts_check_names()) == set(ci_paths.ALL_CHECKS)


def test_every_tracked_file_a_check_reads_selects_a_job_that_runs_it():
    tracked = subprocess.run(["git", "ls-files"], cwd=REPO, capture_output=True, text=True,
                             check=True).stdout.splitlines()
    uncovered = [
        (check, path)
        for check, reads in ci_paths.CHECK_READS.items()
        for path in tracked
        if ci_paths.matches(reads, path)
        and not any(check in ci_paths.JOB_CHECKS[job] and run
                    for job, run in ci_paths.selected_jobs([path]).items())
    ]
    assert uncovered == []


def test_python_workflow_gates_each_job_on_its_table_output():
    jobs = _workflow("python.yml")["jobs"]
    outputs = set(jobs["changes"]["outputs"])
    assert outputs == {"python", "tooling_tests", "ios_guards", "swift", "swift_variant"}
    assert jobs["python"]["if"] == "needs.changes.outputs.python == 'true'"
    assert jobs["ios-guards"]["if"] == "needs.changes.outputs.ios_guards == 'true'"
    assert jobs["tests"]["if"] == "needs.changes.outputs.tooling_tests == 'true'"
    for name in ("swift-build", "swift-variant"):
        assert set(jobs[name]["needs"]) == {"changes", "ios-guards"}
    assert jobs["swift-build"]["if"] == "needs.changes.outputs.swift == 'true'"
    assert jobs["swift-variant"]["if"] == (
        "needs.changes.outputs.swift == 'true' && needs.changes.outputs.swift_variant == 'true'")
    assert jobs["swift"]["if"] == "always()"
    assert set(jobs["swift"]["needs"]) == {"changes", "ios-guards", "swift-build", "swift-variant"}
    assert jobs["ci"]["if"] == "always()"
    assert set(jobs["ci"]["needs"]) == set(jobs) - {"ci"}


def test_workflow_path_filters_match_the_table():
    workflow, job = "faker-kit-checks.yml", "faker-kit"
    on = _workflow(workflow)["on"]
    for event in on.values():
        globs = [p.replace("**", "*") for p in event["paths"]]
        assert globs == [glob for glob, include in ci_paths.JOB_RULES[job] if include]


def _repo_with_change(tmp_path: Path, changed: str) -> tuple[Path, str]:
    def git(*args: str) -> str:
        return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args],
                              cwd=tmp_path, capture_output=True, text=True, check=True).stdout
    git("init", "-q")
    (tmp_path / "README.md").write_text("x\n")
    git("add", ".")
    git("commit", "-qm", "base")
    base = git("rev-parse", "HEAD").strip()
    target = tmp_path / changed
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("y\n")
    git("add", ".")
    git("commit", "-qm", "change")
    return tmp_path, base


def _run(cwd: Path, base: str) -> dict[str, str]:
    out = subprocess.run([sys.executable, str(SCRIPT), "--base", base], cwd=cwd,
                         capture_output=True, text=True, check=True).stdout
    return dict(line.split("=", 1) for line in out.splitlines())


@pytest.mark.parametrize(("changed", "expected"), [
    ("apps/ios/App/View.swift",
     {"python": "false", "tooling_tests": "false", "ios_guards": "true", "swift": "true"}),
    ("apps/ios/Tools/probe.py",
     {"python": "true", "tooling_tests": "false", "ios_guards": "true", "swift": "true"}),
    ("apps/ios/project.yml", {"swift": "true", "swift_variant": "true"}),
    ("apps/ios/Variants/CommNotifications/HermesBots.entitlements",
     {"swift": "true", "swift_variant": "true"}),
    ("apps/ios/NotificationService/NotificationService.swift",
     {"swift": "true", "swift_variant": "true"}),
    ("apps/ios/App/Chat/ChatView.swift", {"swift": "true", "swift_variant": "false"}),
    (".github/workflows/python.yml", {"swift": "true", "swift_variant": "true"}),
    ("gateway/run.py",
     {"python": "true", "tooling_tests": "true", "ios_guards": "false", "swift": "false"}),
    (".github/workflows/python.yml",
     {"python": "true", "tooling_tests": "true", "ios_guards": "true", "faker_kit": "true"}),
    ("scripts/check",
     {"python": "true", "tooling_tests": "true", "ios_guards": "true", "faker_kit": "true"}),
])
def test_changed_paths_select_jobs(tmp_path, changed, expected):
    repo, base = _repo_with_change(tmp_path, changed)
    selected = _run(repo, base)
    assert {k: selected[k] for k in expected} == expected


@pytest.mark.parametrize("base", ["", "0" * 40, "not-a-revision"])
def test_unknown_change_set_runs_everything(tmp_path, base):
    repo, _ = _repo_with_change(tmp_path, "apps/ios/App/View.swift")
    assert set(_run(repo, base).values()) == {"true"}

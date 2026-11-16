import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "kanban_isolated_probe.py"
FIXTURE = Path(__file__).parent / "fixtures" / "kanban_probe_pr139.json"
PR_URL = "https://github.com/tsnAnh/Pal/pull/139"
HEAD = "6e6a3d6204838fcddd47d5f479c47f390c562c94"
MERGE = "b941dadad68e192698bf14dbf950da3af224f23e"
FAKE_TOKEN = "ghp_" + "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8"

FAKE_GH = """#!{python}
import json, sys
fixture = json.load(open({fixture!r}))
argv = sys.argv[1:]
endpoint = argv[1]
if endpoint == "graphql":
    query = next((a[len("query="):] for a in argv if a.startswith("query=")), "")
    pr = fixture["graphql_pull_request"] if "number:139)" in query else None
    print(json.dumps({{"data": {{"repository": {{"pullRequest": pr}}}}}}))
    sys.exit(0)
value = fixture["rest"].get(endpoint)
if value is None:
    sys.stderr.write("gh: Not Found (HTTP 404)\\n")
    sys.exit(1)
print(json.dumps(value))
"""
GH_NO_LOGIN = "#!/bin/sh\necho 'gh: authentication required' >&2\nexit 4\n"


def _load():
    spec = importlib.util.spec_from_file_location("kanban_isolated_probe", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


probe = _load()


def _fixture(*, attach_pull_requests: bool) -> dict:
    data = json.loads(FIXTURE.read_text())
    if attach_pull_requests:
        key = next(k for k in data["rest"] if k.startswith("repos/tsnAnh/Pal/actions/runs?"))
        for page in data["rest"][key]:
            for run in page["workflow_runs"]:
                run["pull_requests"] = [{"number": 139, "base": {"ref": "main"}}]
    return data


def _gh_dir(tmp_path_factory, script: str) -> Path:
    directory = tmp_path_factory.mktemp("fake-gh")
    gh = directory / "gh"
    gh.write_text(script)
    gh.chmod(0o755)
    return directory


def _child_env(gh_dir: Path, home: Path, extra: dict | None = None) -> dict:
    env = {k: v for k, v in os.environ.items() if not k.startswith(("HERMES", "CLAUDE", "GH_", "GITHUB_"))}
    return env | {"PATH": f"{gh_dir}{os.pathsep}{env['PATH']}", "HOME": str(home),
                 "HERMES_STATE_DB_GUARD_BYPASS": "1"} | (extra or {})


def _run_probe(tmp_path_factory, gh_script: str, *, extra_args=(), extra_env=None) -> dict:
    root = tmp_path_factory.mktemp("probe-run")
    scratch = root / "scratch"
    done = subprocess.run(
        [sys.executable, str(SCRIPT), "--home", str(scratch), "--pr-url", PR_URL, "--head", HEAD,
         "--merge-commit", MERGE, *extra_args],
        cwd=REPO, env=_child_env(_gh_dir(tmp_path_factory, gh_script), root / "real-home", extra_env),
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=280, check=False)
    rows = {}
    for line in done.stdout.splitlines():
        cells = [c.strip() for c in line.strip("|").split(" | ")]
        if len(cells) == 3 and cells[1] in ("pass", "fail", "unknown"):
            rows[cells[0].split(" ")[0]] = (cells[1], cells[2])
    return {"rc": done.returncode, "rows": rows, "stdout": done.stdout, "stderr": done.stderr, "scratch": scratch}


@pytest.fixture(scope="module")
def accepted(tmp_path_factory):
    fixture = _fixture(attach_pull_requests=True)
    path = tmp_path_factory.mktemp("fixture") / "pr139.json"
    path.write_text(json.dumps(fixture))
    return _run_probe(tmp_path_factory, FAKE_GH.format(python=sys.executable, fixture=str(path)),
                      extra_args=("--keep", "--github-token-env", "PROBE_TEST_TOKEN"),
                      extra_env={"PROBE_TEST_TOKEN": FAKE_TOKEN})


@pytest.fixture(scope="module")
def recorded(tmp_path_factory):
    fixture = _fixture(attach_pull_requests=False)
    path = tmp_path_factory.mktemp("fixture") / "pr139.json"
    path.write_text(json.dumps(fixture))
    return _run_probe(tmp_path_factory, FAKE_GH.format(python=sys.executable, fixture=str(path)))


@pytest.fixture(scope="module")
def offline(tmp_path_factory):
    return _run_probe(tmp_path_factory, GH_NO_LOGIN)


@pytest.mark.parametrize("step", ["0", "1", "2", "3", "3c", "4", "4a", "4b", "5", "6", "6w"])
def test_every_step_passes_against_recorded_pr139_with_qualifying_ci(accepted, step):
    assert accepted["rows"][step][0] == "pass", accepted["stdout"]
    assert accepted["rc"] == 0


def test_step5_evidence_names_the_real_pr_head_and_a_qualifying_check(accepted):
    evidence = accepted["rows"]["5"][1]
    assert "classification=success" in evidence and "qualifying_checks=1" in evidence


def test_ci_policy_rejects_the_unmodified_pr139_recording(recorded):
    status, evidence = recorded["rows"]["5"]
    assert status == "fail" and "classification=missing" in evidence and "qualifying_checks=0" in evidence
    assert recorded["rc"] == 1
    for step in ("4a", "4b", "6", "6w"):
        assert recorded["rows"][step][0] == "pass", recorded["stdout"]


def test_missing_github_evidence_reads_unknown_never_pass(offline):
    for step in ("4b", "5"):
        assert offline["rows"][step][0] == "unknown", offline["stdout"]
    assert offline["rows"]["4a"][0] == "pass" and offline["rows"]["6"][0] == "pass"
    assert offline["rc"] == 3


def test_output_never_carries_secret_shaped_strings(accepted, recorded, offline):
    for run in (accepted, recorded, offline):
        assert not probe.SECRET_SHAPES.search(run["stdout"] + run["stderr"])
    assert FAKE_TOKEN not in accepted["stdout"] + accepted["stderr"]


def test_github_login_is_removed_from_kept_scratch_home(accepted):
    files = [p for p in accepted["scratch"].rglob("*") if p.is_file()]
    assert files
    assert not any(FAKE_TOKEN.encode() in p.read_bytes() for p in files if p.stat().st_size < 5_000_000)


def test_scratch_home_is_removed_unless_kept(recorded, accepted):
    assert not recorded["scratch"].exists()
    assert (accepted["scratch"] / probe.MARKER).is_file()


@pytest.fixture
def fake_home(tmp_path, monkeypatch):
    home = tmp_path / "home"
    (home / ".hermes").mkdir(parents=True)
    monkeypatch.delenv("HERMES_HOME", raising=False)
    monkeypatch.delenv("HERMES_KANBAN_HOME", raising=False)
    return home


@pytest.mark.parametrize("scratch", [".hermes", ".hermes/probe", "", ".."])
def test_refuses_the_real_default_home_and_anything_around_it(fake_home, scratch):
    root = (fake_home / scratch).resolve()
    with pytest.raises(probe.IsolationError):
        probe.Sandbox(root).assert_isolated(probe.protected_roots({}, fake_home))


def test_refuses_ambient_hermes_and_kanban_homes(fake_home, tmp_path):
    ambient = tmp_path / "elsewhere"
    ambient.mkdir()
    environ = {"HERMES_HOME": str(ambient), "HERMES_KANBAN_HOME": str(ambient / "kanban")}
    protected = probe.protected_roots(environ, fake_home)
    for root in (ambient, ambient / "kanban", ambient / "nested", tmp_path):
        with pytest.raises(probe.IsolationError):
            probe.Sandbox(root.resolve()).assert_isolated(protected)


def test_refuses_nonempty_unmarked_directory_and_accepts_marked_or_empty(fake_home, tmp_path):
    protected = probe.protected_roots({}, fake_home)
    occupied = tmp_path / "occupied"
    occupied.mkdir()
    (occupied / "notes.txt").write_text("keep me")
    with pytest.raises(probe.IsolationError):
        probe.Sandbox(occupied).assert_isolated(protected)
    probe.Sandbox(tmp_path / "absent").assert_isolated(protected)
    empty = tmp_path / "empty"
    empty.mkdir()
    probe.Sandbox(empty).assert_isolated(protected)
    marked = probe.Sandbox(tmp_path / "marked")
    marked.prepare(protected)
    probe.Sandbox(marked.root).assert_isolated(protected)


def test_cleanup_removes_only_what_the_probe_created(fake_home, tmp_path):
    protected = probe.protected_roots({}, fake_home)
    sandbox = probe.Sandbox(tmp_path / "scratch")
    sandbox.prepare(protected)
    sandbox.cleanup()
    assert not sandbox.root.exists()
    sandbox.prepare(protected)
    (sandbox.root / "extra.txt").write_text("not ours")
    sandbox.cleanup()
    assert [p.name for p in sandbox.root.iterdir()] == ["extra.txt"]


def test_cli_refuses_the_default_home_without_creating_anything(fake_home):
    target = fake_home / ".hermes" / "probe"
    done = subprocess.run(
        [sys.executable, str(SCRIPT), "--home", str(target), "--pr-url", PR_URL, "--head", HEAD, "--merge-commit", MERGE],
        cwd=REPO, env={**os.environ, "HOME": str(fake_home)}, stdin=subprocess.DEVNULL, capture_output=True, text=True,
        timeout=120, check=False)
    assert done.returncode == 2 and "refused" in done.stderr
    assert not target.exists()


def test_child_env_carries_no_ambient_hermes_or_credential_variables(tmp_path, monkeypatch):
    monkeypatch.setenv("GH_TOKEN", FAKE_TOKEN)
    monkeypatch.setenv("HERMES_HOME", "/somewhere/real")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-" + "x" * 30)
    sandbox = probe.Sandbox(tmp_path / "s")
    env = sandbox.env(sandbox.profile_home("coordinator"))
    assert env["HERMES_HOME"] == str(sandbox.profile_home("coordinator"))
    assert env["HERMES_KANBAN_HOME"] == str(sandbox.kanban_home) and env["HOME"] == str(sandbox.home)
    assert not {"GH_TOKEN", "OPENAI_API_KEY"} & env.keys()


def test_missing_observation_is_unknown_mismatch_is_fail_and_only_full_match_passes():
    match = probe.Check("a", 1, 1)
    assert probe.Step.judged("x", "t", [match, probe.Check("b", 2, 2)]).status == "pass"
    assert probe.Step.judged("x", "t", [match, probe.Check("b", 2)]).status == "unknown"
    assert probe.Step.judged("x", "t", [match, probe.Check("b", 2, 3)]).status == "fail"
    assert probe.Step.judged("x", "t", [probe.Check("b", 2), probe.Check("c", 2, 3)]).status == "fail"
    assert probe.Step.judged("x", "t", []).status == "pass"


def test_exit_code_orders_fail_over_unknown_over_pass():
    ok, unknown, bad = (probe.Step("k", "t", s, {}) for s in ("pass", "unknown", "fail"))
    assert (probe.exit_code([ok]), probe.exit_code([ok, unknown]), probe.exit_code([ok, unknown, bad])) == (0, 3, 1)


def test_table_renders_unknown_literally_and_redacts_secrets():
    redact = probe.Redactor()
    redact.add("topsecretvalue123")
    steps = [probe.Step("1", "t", "unknown", {"missing": probe.MISSING, "note": f"x {FAKE_TOKEN} topsecretvalue123 Bearer abcdefgh12345"})]
    table = probe.render_table(steps, redact)
    assert "missing=unknown" in table
    assert not probe.SECRET_SHAPES.search(table) and "topsecretvalue123" not in table and FAKE_TOKEN not in table

"""Fleet exact-head CI acceptance (``fleet-ci:`` completion contracts), through the real
collector, the gh subprocess boundary and ``complete_task``, against a local GitHub contract."""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from hermes_cli import kanban as kanban_cli
from hermes_cli import kanban_db as kb
from hermes_cli.kanban_db_connect import connect
from hermes_cli.kanban_pr_acceptance import decode_pages
from hermes_cli.kanban_outcomes_store import OutcomeRefusedError
from tests.hermes_cli.kanban_outcome_support import BOARD, PROFILE, SHA_C, add, claim, complete, merged_payload

pytest_plugins = ["tests.hermes_cli.kanban_outcome_support"]

REPO = "acme/widget"
PR = f"https://github.com/{REPO}/pull/7"
HEAD = "a" * 40
GH_246 = (
    "import json,sys,urllib.request\n"
    "if '--slurp' in sys.argv:\n"
    "    sys.stderr.write('unknown flag: --slurp\\n'); sys.exit(1)\n"
    "value = json.loads(urllib.request.urlopen(URL + sys.argv[2]).read())\n"
    "pages = value if '--paginate' in sys.argv and isinstance(value, list) else [value]\n"
    "sys.stdout.write(''.join(json.dumps(p) + ('\\n' if i % 2 else '') for i, p in enumerate(pages)))\n"
)


def good_state(head=HEAD):
    return {
        "default": "main",
        "pr": {"number": 7, "state": "open", "merged": False, "created_at": "2026-01-01T00:00:00Z",
               "head": {"sha": head, "ref": "feat", "repo": {"full_name": REPO}},
               "base": {"ref": "main", "repo": {"full_name": REPO}}},
        "commit_prs": [], "branch_prs": [{"number": 7, "base": {"ref": "main"}}], "timeline": [{"event": "labeled"}],
        "workflow_runs": [{"id": 1, "check_suite_id": 11, "path": ".github/workflows/ci.yml", "event": "pull_request",
                           "head_sha": head, "head_branch": "feat", "repository": {"full_name": REPO},
                           "head_repository": {"full_name": REPO}, "run_started_at": "2026-01-02T00:00:00Z",
                           "pull_requests": [{"number": 7, "base": {"ref": "main"}}]}],
        "check_runs": [{"id": 100, "name": "build", "head_sha": head, "status": "completed", "conclusion": "success",
                        "check_suite": {"id": 11}, "html_url": "https://github.com/acme/widget/actions/runs/1"}],
        "statuses": [], "sibling_timelines": {},
        "trees": {"main": {".github/workflows/ci.yml": "s1"}, head: {".github/workflows/ci.yml": "s1"}},
        "requests": [], "after_check_runs": None, "envs": [],
    }


@pytest.fixture
def github(coord_env, tmp_path, monkeypatch):
    state = good_state()
    profile_home = coord_env / "profiles" / PROFILE
    profile_home.mkdir(parents=True)
    (profile_home / ".env").write_text("GH_TOKEN=projbot-token\n", encoding="utf-8")
    monkeypatch.setenv("GH_TOKEN", "ambient-launch-token")

    def pages(items, key=None):
        chunks = [items[i:i + 100] for i in range(0, len(items), 100)] or [[]]
        return [{"total_count": len(items), key: c} for c in chunks] if key else [chunks[0]] if len(chunks) == 1 else chunks

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = self.path.lstrip("/")
            state["requests"].append(path)
            route = path.partition("?")[0]
            root = f"repos/{REPO}"
            if route == root:
                value = {"default_branch": state["default"]}
            elif route == f"{root}/pulls/7":
                value = state["pr"]
            elif route.endswith("/pulls") and "/commits/" in route:
                value = state.get("commit_prs_raw") or pages(state["commit_prs"])
            elif route == f"{root}/pulls":
                value = pages(state["branch_prs"])
            elif route.startswith(f"{root}/issues/") and route.endswith("/timeline"):
                number = int(route.split("/")[-2])
                events = state["timeline"] if number == 7 else state["sibling_timelines"].get(number, "gone")
                value = events if not isinstance(events, list) else pages(events)
            elif route == f"{root}/actions/runs":
                value = pages(state["workflow_runs"], "workflow_runs")
            elif route.endswith("/check-runs"):
                value = pages(state["check_runs"], "check_runs")
                if state["after_check_runs"]:
                    state["after_check_runs"]()
            elif route.endswith("/statuses"):
                value = pages(state["statuses"])
            elif "/git/trees/" in route:
                value = {"truncated": False, "tree": [{"path": p, "sha": s} for p, s in state["trees"][route.rsplit("/", 1)[1]].items()]}
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.end_headers()
            self.wfile.write(json.dumps(value).encode())

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    shim = tmp_path / "bin"
    shim.mkdir()
    envlog = tmp_path / "gh-tokens.log"
    gh = shim / "gh"
    gh.write_text(f"#!{sys.executable}\nimport os\nURL='http://127.0.0.1:{server.server_port}/'\n"
                  f"open({str(envlog)!r},'a').write(os.environ.get('GH_TOKEN','-')+'\\n')\n" + GH_246)
    gh.chmod(0o755)
    monkeypatch.setenv("PATH", str(shim) + os.pathsep + os.environ["PATH"])
    state["tokens"] = lambda: envlog.read_text().split() if envlog.exists() else []
    try:
        yield state
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


@pytest.fixture
def conn(coord_env):
    with connect(board=BOARD) as connection:
        yield connection


def receipts(conn, tid):
    return [json.loads(r[0]) for r in conn.execute(
        "SELECT payload FROM task_events WHERE task_id=? AND kind='pr_acceptance' ORDER BY id", (tid,))]


def attempt(conn, contract=f"fleet-ci:{REPO}", assignee=PROFILE, **kw):
    tid = kb.create_task(conn, title="pr", assignee=assignee, completion_contract=contract, **kw)
    done = kb.complete_task(conn, tid, result="done", metadata={"published_pr": PR})
    return tid, done


def merged_shape(s, linked=True):
    s["pr"].update(state="closed", merged=True)
    set_run(s, pull_requests=[])
    s["workflow_runs"].append({**s["workflow_runs"][0], "id": 2, "check_suite_id": 12,
                               "path": ".github/workflows/faker-kit-checks.yml"})
    s["check_runs"].append({**s["check_runs"][0], "id": 101, "name": "kit", "check_suite": {"id": 12}})
    if linked:
        s["commit_prs"].append({"number": 7, "state": "closed", "base": {"ref": "main"}, "head": {"sha": s["pr"]["head"]["sha"]}})


def set_run(state, **changes):
    state["workflow_runs"][0].update(changes)


def add_check(state, **check):
    state["check_runs"].append({"id": 200 + len(state["check_runs"]), "name": "extra", "head_sha": state["pr"]["head"]["sha"],
                                "status": "completed", "conclusion": "success", "check_suite": {"id": 99}, **check})


def kit_only(s):
    set_run(s, path=".github/workflows/faker-kit-checks.yml")


def review_only(s):
    set_run(s, path=".github/workflows/claude-review.yml")


def only_check(s, conclusion):
    s["check_runs"][0]["conclusion"] = conclusion


def spoofed(s):
    s["check_runs"][0]["check_suite"] = {"id": 9999}


def many_skipped(s, failing_at=None):
    for i in range(150):
        add_check(s, id=1000 + i, name=f"n{i}", conclusion="failure" if i == failing_at else "skipped")


def push_run(s, same_workflows):
    set_run(s, event="push", pull_requests=[])
    if not same_workflows:
        s["trees"][s["pr"]["head"]["sha"]] = {".github/workflows/ci.yml": "tampered"}


SUCCESS = [
    ("merged PR whose runs lost pull_requests, proven by the commit-to-PR link", merged_shape),

    ("exact head", lambda s: None),
    ("150 neutral/skipped checks around the success", lambda s: many_skipped(s)),
    ("ignored claude-review job and security-review status", lambda s: (
        s["workflow_runs"].append({**s["workflow_runs"][0], "id": 2, "check_suite_id": 12,
                                   "path": ".github/workflows/claude-review.yml"}),
        add_check(s, conclusion="failure", check_suite={"id": 12}),
        s["statuses"].append({"id": 1, "context": "security-review", "state": "failure"}))),
    ("sibling PR with clean history on the same branch", lambda s: (
        s["branch_prs"].append({"number": 3, "base": {"ref": "main"}}),
        s["sibling_timelines"].update({3: [{"event": "labeled"}]}))),
    ("push run with branch workflows equal to the default branch", lambda s: push_run(s, True)),
]
REFUSED = [
    ("merged shape, commit-to-PR list omits this PR", lambda s: merged_shape(s, linked=False), "missing"),
    ("merged shape, commit-to-PR list names a different PR", lambda s: (
        merged_shape(s, linked=False),
        s["commit_prs"].append({"number": 8, "state": "closed", "base": {"ref": "main"}, "head": {"sha": HEAD}})), "missing"),
    ("merged shape, run lists another PR though this PR is linked", lambda s: (
        merged_shape(s), set_run(s, pull_requests=[{"number": 8, "base": {"ref": "main"}}])), "missing"),
    ("merged shape, linked PR has a non-default base", lambda s: (
        merged_shape(s, linked=False),
        s["commit_prs"].append({"number": 7, "state": "closed", "base": {"ref": "dev"}, "head": {"sha": HEAD}})), "missing"),
    ("merged shape, linked PR head differs", lambda s: (
        merged_shape(s, linked=False),
        s["commit_prs"].append({"number": 7, "state": "closed", "base": {"ref": "main"}, "head": {"sha": "b" * 40}})), "missing"),
    ("merged shape, run on another head", lambda s: (merged_shape(s), set_run(s, head_sha="b" * 40)), "missing"),
    ("merged shape, run from a fork", lambda s: (merged_shape(s), set_run(s, head_repository={"full_name": "fork/widget"})), "missing"),
    ("merged shape, run started before the PR opened", lambda s: (merged_shape(s), set_run(s, run_started_at="2025-12-31T00:00:00Z")), "missing"),
    ("merged shape, run on another branch", lambda s: (merged_shape(s), set_run(s, head_branch="other")), "missing"),
    ("merged shape, push-event run with empty list", lambda s: (merged_shape(s), set_run(s, event="push"), s["trees"].update({HEAD: {}})), "missing"),
    ("merged shape, retargeted sibling", lambda s: (
        merged_shape(s), s["branch_prs"].append({"number": 3, "base": {"ref": "dev"}}), s["sibling_timelines"].update({3: []})), "provenance"),
    ("merged shape, another open PR shares the head", lambda s: (
        merged_shape(s), s["commit_prs"].append({"number": 9, "state": "open", "base": {"ref": "main"}, "head": {"sha": HEAD}})), "provenance"),
    ("merged shape, unreadable commit-to-PR page", lambda s: (merged_shape(s), s.update(commit_prs_raw={"message": "gone"})), "infra"),

    ("pending", lambda s: add_check(s, status="in_progress", conclusion=None), "pending"),
    ("failure beyond the first page", lambda s: many_skipped(s, failing_at=120), "failure"),
    ("failing legacy status", lambda s: s["statuses"].append({"id": 2, "context": "lint", "state": "failure"}), "failure"),
    ("no checks", lambda s: s.update(check_runs=[]), "missing"),
    ("neutral without a qualifying success", lambda s: only_check(s, "neutral"), "missing"),
    ("skipped without a qualifying success", lambda s: only_check(s, "skipped"), "missing"),
    ("spoofed check name from an unrelated suite", spoofed, "missing"),
    ("kit checks only", kit_only, "missing"),
    ("review workflow only", review_only, "missing"),
    ("workflow_dispatch", lambda s: set_run(s, event="workflow_dispatch"), "missing"),
    ("workflow_run", lambda s: set_run(s, event="workflow_run"), "missing"),
    ("pull_request_target", lambda s: set_run(s, event="pull_request_target"), "missing"),
    ("run on another head", lambda s: set_run(s, head_sha="b" * 40), "missing"),
    ("run on another branch", lambda s: set_run(s, head_branch="other"), "missing"),
    ("run from a fork", lambda s: set_run(s, head_repository={"full_name": "fork/widget"}), "missing"),
    ("run attached with a non-default base", lambda s: set_run(s, pull_requests=[{"number": 7, "base": {"ref": "dev"}}]), "missing"),
    ("run attached to a sibling PR", lambda s: set_run(s, pull_requests=[{"number": 8, "base": {"ref": "main"}}]), "missing"),
    ("run started before the PR opened", lambda s: set_run(s, run_started_at="2025-12-31T00:00:00Z"), "missing"),
    ("workflow outside .github/workflows", lambda s: set_run(s, path="scripts/ci.yml"), "missing"),
    ("push run with workflows differing from the default branch", lambda s: push_run(s, False), "missing"),
    ("PR targets a non-default base", lambda s: s["pr"]["base"].update(ref="dev"), "provenance"),
    ("a branch PR once targeted another base", lambda s: (
        s["branch_prs"].append({"number": 3, "base": {"ref": "dev"}}), s["sibling_timelines"].update({3: []})), "provenance"),
    ("timeline base_ref_changed", lambda s: s["timeline"].append({"event": "base_ref_changed"}), "provenance"),
    ("timeline automatic_base_change_failed", lambda s: s["timeline"].append({"event": "automatic_base_change_failed"}), "provenance"),
    ("sibling PR on the branch was retargeted back to the default base", lambda s: (
        s["branch_prs"].append({"number": 3, "base": {"ref": "main"}}),
        s["sibling_timelines"].update({3: [{"event": "base_ref_changed"}]})), "provenance"),
    ("sibling PR timeline unreadable", lambda s: s["branch_prs"].append({"number": 3, "base": {"ref": "main"}}), "infra"),
    ("another open PR at the same head", lambda s: s["commit_prs"].append({"number": 9, "state": "open", "head": {"sha": HEAD}}), "provenance"),
    ("missing timeline pages", lambda s: s.update(timeline={"message": "gone"}), "infra"),
]


@pytest.mark.parametrize("name,mutate", SUCCESS, ids=[c[0] for c in SUCCESS])
def test_fleet_accepts_qualifying_exact_head_ci_without_required_checks(github, conn, name, mutate):
    mutate(github)
    tid, done = attempt(conn)
    assert done and kb.get_task(conn, tid).status == "done"
    receipt = receipts(conn, tid)[-1]
    assert (receipt["ok"], receipt["policy"], receipt["head_sha"]) == (True, "fleet-ci", HEAD)
    assert any(c["qualifying"] for c in receipt["checks"])
    assert github["tokens"] and set(github["tokens"]()) == {"projbot-token"}


@pytest.mark.parametrize("name,mutate,expected", REFUSED, ids=[c[0] for c in REFUSED])
def test_fleet_refuses_everything_the_provenance_rules_reject(github, conn, name, mutate, expected):
    mutate(github)
    tid, done = attempt(conn)
    assert not done and kb.get_task(conn, tid).status != "done"
    assert receipts(conn, tid)[-1]["classification"] == expected
    assert not receipts(conn, tid)[-1]["ok"]


def test_incomplete_check_run_pagination_fails_closed(github, conn, monkeypatch):
    import hermes_cli.kanban_pr_acceptance_fleet as fleet
    real = fleet._api

    def lying(endpoint, **kw):
        value = real(endpoint, **kw)
        if endpoint.endswith("filter=latest"):
            value[0]["total_count"] += 1
        return value
    monkeypatch.setattr(fleet, "_api", lying)
    tid, done = attempt(conn)
    assert not done and receipts(conn, tid)[-1]["classification"] == "infra"


def test_head_change_while_reading_is_stale_and_never_transferable(github, conn):
    def move_head():
        github["pr"]["head"]["sha"] = "b" * 40
    github["after_check_runs"] = move_head
    tid, done = attempt(conn)
    assert not done and receipts(conn, tid)[-1]["classification"] == "stale"
    github["after_check_runs"] = None
    github["pr"]["head"]["sha"] = HEAD
    assert kb.complete_task(conn, tid, result="done", metadata={"published_pr": PR})


def test_run_replaced_while_reading_commits_no_stale_acceptance(github, conn):
    tid = kb.create_task(conn, title="pr", assignee=PROFILE, completion_contract=f"fleet-ci:{REPO}")
    run_id = kb.claim_task(conn, tid).current_run_id

    def reclaim():
        with connect(board=BOARD) as rival:
            assert kb.block_task(rival, tid, reason="reassigned")
            assert kb.unblock_task(rival, tid)
            github["replacement"] = kb.claim_task(rival, tid).current_run_id
    github["after_check_runs"] = reclaim
    assert not kb.complete_task(conn, tid, result="done", expected_run_id=run_id, metadata={"published_pr": PR})
    assert kb.get_task(conn, tid).current_run_id == github["replacement"] != run_id
    assert not receipts(conn, tid) and kb.get_task(conn, tid).status != "done"


def test_policy_and_pr_are_fixed_once_bound(github, conn):
    tid = kb.create_task(conn, title="pr", assignee=PROFILE, completion_contract=f"fleet-ci:{REPO}")
    assert not kb.complete_task(conn, tid, result="done", metadata={"published_pr": "https://github.com/acme/other/pull/7"})
    assert kb.get_task(conn, tid).completion_contract == f"fleet-ci:{REPO}"
    add_check(github, conclusion="failure")
    assert not kb.complete_task(conn, tid, result="done", metadata={"published_pr": PR})
    assert kb.get_task(conn, tid).completion_contract == f"fleet-ci:{PR}"
    github["check_runs"].pop()
    sibling = "https://github.com/acme/widget/pull/8"
    assert not kb.complete_task(conn, tid, result="done", metadata={"published_pr": sibling})
    assert kb.get_task(conn, tid).completion_contract == f"fleet-ci:{PR}"
    assert kb.complete_task(conn, tid, result="done", metadata={"published_pr": PR})


def test_default_policy_still_needs_required_checks(github, conn):
    tid, done = attempt(conn, contract=REPO)
    assert not done and receipts(conn, tid)[-1]["classification"] != "success"


@pytest.mark.parametrize("bad", ["fleet-ci:local-only", "fleet-ci:", "fleet-ci:fleet-ci:a/b", "fleet-ci:not a repo"])
def test_fleet_policy_has_no_local_only_downgrade_or_malformed_form(conn, bad):
    with pytest.raises(ValueError, match="completion_contract"):
        kb.create_task(conn, title="x", assignee=PROFILE, completion_contract=bad)


def test_fleet_policy_is_exposed_through_cli_and_tool_creation(github, conn, monkeypatch):
    out = kanban_cli.run_slash(f"create cli-card --assignee {PROFILE} --completion-contract fleet-ci:{REPO} --json")
    assert kb.get_task(conn, json.loads(out)["id"]).completion_contract == f"fleet-ci:{REPO}"
    from tools import kanban_tools
    monkeypatch.setenv("HERMES_KANBAN_BOARD", BOARD)
    created = json.loads(kanban_tools._handle_create({"title": "tool-card", "assignee": PROFILE, "completion_contract": f"fleet-ci:{PR}"}))
    assert kb.get_task(conn, created["task_id"]).completion_contract == f"fleet-ci:{PR}"


def test_fleet_policy_never_reads_as_the_ambient_login(github, conn):
    tid, done = attempt(conn, assignee=None)
    assert not done and receipts(conn, tid)[-1]["classification"] == "auth"
    assert github["requests"] == []
    ghost, done = attempt(conn, assignee="ghost")
    assert not done and receipts(conn, ghost)[-1]["classification"] == "auth"
    assert github["requests"] == []


def test_denied_read_is_an_auth_receipt(github, conn, monkeypatch, tmp_path):
    (tmp_path / "bin" / "gh").write_text(f"#!{sys.executable}\nimport sys\nsys.stderr.write('HTTP 404')\nsys.exit(1)\n")
    tid, done = attempt(conn)
    assert not done and receipts(conn, tid)[-1]["classification"] == "auth"


def governed_card(conn, contract=f"fleet-ci:{REPO}"):
    tid = kb.create_task(conn, title="governed pr", assignee=PROFILE, completion_contract=contract,
                         outcome_contract={"kind": "merged_pr", "repo": REPO})
    return tid, claim(conn, tid)


def test_merged_outcome_needs_ci_acceptance_and_acceptance_needs_merge(github, conn, fake_github, hooks):
    tid, run_id = governed_card(conn)
    child = kb.create_task(conn, title="child", assignee=PROFILE, parents=(tid,))
    add(conn, tid, run_id, "pr_merged", merged_payload(pr_url=PR, head=HEAD, merge=SHA_C))
    fake_github.update(state="OPEN", head_sha=HEAD)
    with pytest.raises(OutcomeRefusedError):
        complete(conn, tid, run_id, metadata={"published_pr": PR})
    assert github["requests"] == [] and kb.get_task(conn, child).status == "todo"
    fake_github.update(state="MERGED", merge_commit=SHA_C)
    add_check(github, conclusion="failure")
    assert not complete(conn, tid, run_id, metadata={"published_pr": PR})
    assert not kb.complete_task(conn, tid, summary="x", expected_run_id=run_id, actor_profile=PROFILE, force=True,
                                metadata={"published_pr": PR})
    assert kb.get_task(conn, tid).status != "done" and kb.get_task(conn, child).status == "todo" and not [h for h in hooks if h[0] == "kanban_task_completed"]
    github["check_runs"].pop()
    assert complete(conn, tid, run_id, metadata={"published_pr": PR})
    assert kb.get_task(conn, child).status == "ready" and [h for h in hooks if h[0] == "kanban_task_completed"] == [("kanban_task_completed", tid)]
    assert not complete(conn, tid, run_id, metadata={"published_pr": PR})
    assert len(receipts(conn, tid)) == 3 and len([h for h in hooks if h[0] == "kanban_task_completed"]) == 1


def test_evidence_and_acceptance_cannot_name_different_prs_or_heads(github, conn, fake_github):
    tid, run_id = governed_card(conn)
    other, other_run = governed_card(conn, contract=f"fleet-ci:{PR}")
    with pytest.raises(Exception, match="CI acceptance is bound to"):
        add(conn, other, other_run, "pr_merged", merged_payload(pr_url=f"https://github.com/{REPO}/pull/8"))
    fake_github.update(state="MERGED", head_sha="c" * 40, merge_commit=SHA_C)
    add(conn, tid, run_id, "pr_merged", merged_payload(pr_url=PR, head="c" * 40, merge=SHA_C))
    assert not complete(conn, tid, run_id, metadata={"published_pr": PR})
    assert receipts(conn, tid)[-1]["classification"] == "mismatch"
    assert kb.get_task(conn, tid).status != "done"



@pytest.mark.parametrize("text,pages", [
    ('[1,2][3]\n[4]', [[1, 2], [3], [4]]),
    ('[{"a": 1}]', [[{"a": 1}]]),
    ('[]\n', [[]]),
    ('{"total_count": 1, "check_runs": [5]}\n  {"total_count": 1, "check_runs": []}',
     [{"total_count": 1, "check_runs": [5]}, {"total_count": 1, "check_runs": []}]),
    ('\n [1]\n\n\t[2] \n', [[1], [2]]),
])
def test_decode_pages_matches_slurp(text, pages):
    assert decode_pages(text) == pages


@pytest.mark.parametrize("text", ["[1]garbage", "[1][", "", "  \n"])
def test_decode_pages_rejects_garbage(text):
    with pytest.raises(ValueError):
        decode_pages(text)


PHASES = [
    ("pull request read", "/pulls/7"),
    ("repository read", f"repos/{REPO}?"),
    ("commit-to-PR pages", f"/commits/{HEAD}/pulls"),
    ("branch PRs", f"repos/{REPO}/pulls?"),
    ("timeline", "/timeline"),
    ("workflow runs", "/actions/runs"),
    ("workflow tree", "/git/trees/"),
    ("check runs", "/check-runs"),
    ("statuses", "/statuses"),
]


def failing_gh(github, tmp_path, needle, *, after=0, timeout=False):
    shim = tmp_path / "bin" / "gh"
    real = shim.read_text()
    count = tmp_path / "count"
    fail = "import time; time.sleep(60)" if timeout else "sys.stderr.write('HTTP 500 secret-host token=abc'); sys.exit(1)"
    shim.write_text(real.replace(
        "import json,sys,urllib.request\n",
        "import json,sys,urllib.request,pathlib\n"
        f"_e = sys.argv[2] + ('?' if '?' not in sys.argv[2] else '')\n"
        f"if {needle!r} in _e:\n"
        f"    _c = pathlib.Path({str(count)!r}); _n = int(_c.read_text()) if _c.exists() else 0; _c.write_text(str(_n + 1))\n"
        f"    if _n >= {after}:\n        {fail}\n", 1))


@pytest.mark.parametrize("name,needle", PHASES, ids=[p[0] for p in PHASES])
def test_gh_failure_persists_its_phase_without_stderr(github, conn, tmp_path, name, needle):
    if name == "workflow tree":
        github["workflow_runs"][0].update(event="push", pull_requests=[])
    failing_gh(github, tmp_path, needle)
    tid, done = attempt(conn)
    receipt = receipts(conn, tid)[-1]
    assert not done and kb.get_task(conn, tid).status != "done"
    assert receipt["classification"] == "infra"
    assert receipt["detail"].startswith("infra: CalledProcessError (gh exited 1 while reading ")
    assert f"in phase {name};" in receipt["detail"]
    assert "?" not in receipt["detail"].split(" in phase ")[0]
    assert not {"secret-host", "token", "HTTP 500"} & set(receipt["detail"].replace(";", " ").replace("=", " ").split())
    assert "secret-host" not in json.dumps(receipt)


def test_final_reread_failure_names_its_phase(github, conn, tmp_path):
    failing_gh(github, tmp_path, "/pulls/7", after=1)
    tid, done = attempt(conn)
    assert not done
    assert "in phase final re-read;" in receipts(conn, tid)[-1]["detail"]


def test_gh_timeout_persists_its_phase(github, conn, tmp_path, monkeypatch):
    import subprocess
    real = subprocess.run
    monkeypatch.setattr(subprocess, "run", lambda *a, **kw: real(*a, **{**kw, "timeout": 1}))
    failing_gh(github, tmp_path, "/actions/runs", timeout=True)
    tid, done = attempt(conn)
    detail = receipts(conn, tid)[-1]["detail"]
    assert not done and receipts(conn, tid)[-1]["classification"] == "infra"
    assert detail.startswith(f"infra: TimeoutExpired (gh timed out (30s) while reading repos/{REPO}/actions/runs) in phase workflow runs;")


def test_incomplete_pagination_names_its_phase(github, conn, monkeypatch):
    import hermes_cli.kanban_pr_acceptance_fleet as fleet
    real = fleet._api

    def lying(endpoint, **kw):
        value = real(endpoint, **kw)
        if "/actions/runs" in endpoint:
            value[0]["total_count"] += 1
        return value
    monkeypatch.setattr(fleet, "_api", lying)
    tid, done = attempt(conn)
    assert not done
    assert receipts(conn, tid)[-1]["detail"].startswith(
        "infra: ValueError (Incomplete provenance pagination) in phase workflow runs;")


def test_head_without_workflow_runs_is_missing_not_infra(github, conn):
    github.update(workflow_runs=[], check_runs=[])
    tid, done = attempt(conn)
    receipt = receipts(conn, tid)[-1]
    assert not done and receipt["classification"] == "missing"
    assert receipt["detail"] == "No qualifying CI success on this exact head."


def test_missing_profile_login_is_auth_not_infra(github, conn, tmp_path):
    (tmp_path / "bin" / "gh").write_text(f"#!{sys.executable}\nimport sys\nsys.exit(4)\n")
    tid, done = attempt(conn)
    assert not done and receipts(conn, tid)[-1]["classification"] == "auth"

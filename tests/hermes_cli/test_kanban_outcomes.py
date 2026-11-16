"""Outcome contracts: governed cards complete only on verified, attributable evidence."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from hermes_cli import kanban as kanban_cli
from hermes_cli import kanban_db as kb
from hermes_cli import kanban_db_connect as kbc
from hermes_cli import kanban_db_workspace as kbw
from hermes_cli import kanban_swarm as ks
from hermes_cli.kanban_outcomes import EvidenceError, OutcomeContractError, Unverifiable
from hermes_cli.kanban_outcomes_store import OutcomeRefusedError, list_evidence
from tests.hermes_cli.kanban_outcome_support import (
    BOARD, PR_URL, PROFILE, REPO, SHA_A, SHA_B, SHA_C, add, attach_file, claim, complete, event_kinds, governed,
    merged_payload,
)

pytest_plugins = ["tests.hermes_cli.kanban_outcome_support"]

MERGED = {"kind": "merged_pr", "repo": REPO}
ARTIFACT = {"kind": "built_artifact"}
INSTALLED = {"kind": "installed_app"}
OTHER = {"kind": "other", "name": "report", "required_fields": ["url", "checked_by"]}
SHA256_X = "d" * 64


def _with_child(conn, contract):
    parent = governed(conn, contract)
    child = kb.create_task(conn, title="child", assignee=PROFILE, parents=(parent,))
    assert kb.get_task(conn, child).status == "todo"
    run_id = claim(conn, parent)
    task = kb.get_task(conn, parent)
    workspace = kbw.resolve_workspace(task, board=BOARD)
    kbw.set_workspace_path(conn, parent, str(workspace))
    assert workspace.exists()
    return parent, child, run_id, workspace


def _assert_refused_untouched(conn, parent, child, workspace, hooks, code):
    task = kb.get_task(conn, parent)
    assert task.status == "running" and task.result is None
    assert kb.get_task(conn, child).status == "todo"
    assert workspace.exists()
    assert ("kanban_task_completed", parent) not in hooks
    refusals = [e for e in kb.list_events(conn, parent) if e.kind == "outcome_refused"]
    assert refusals and refusals[-1].payload["code"] == code
    assert "outcome_verified" not in event_kinds(conn, parent)


def test_contract_validation_and_immutability(conn):
    for bad in ({"kind": "other"}, {"kind": "other", "name": "x", "required_fields": []},
                {"kind": "merged_pr"}, {"kind": "merged_pr", "repo": "nope"},
                {"kind": "built_artifact", "repo": REPO}, {"kind": "mystery"}, "not json"):
        with pytest.raises(OutcomeContractError):
            governed(conn, bad)
    task_id = governed(conn, MERGED)
    stored = json.loads(kb.get_task(conn, task_id).outcome_contract)
    assert stored == {"kind": "merged_pr", "repo": REPO}
    assert not hasattr(kb, "set_outcome_contract")


def test_merged_pr_requires_evidence_and_refusal_is_actionable_and_deduplicated(conn, fake_github, hooks):
    parent, child, run_id, workspace = _with_child(conn, MERGED)
    with pytest.raises(OutcomeRefusedError) as err:
        complete(conn, parent, run_id)
    assert err.value.code == "missing" and "pr_merged" in err.value.detail
    _assert_refused_untouched(conn, parent, child, workspace, hooks, "missing")
    with pytest.raises(OutcomeRefusedError):
        complete(conn, parent, run_id)
    assert event_kinds(conn, parent).count("outcome_refused") == 1
    assert fake_github["calls"] == []


@pytest.mark.parametrize("payload", [
    {"pr_url": PR_URL, "head_sha": "xyz", "merge_commit": SHA_B},
    {"pr_url": "https://example.com/acme/widget/pull/7", "head_sha": SHA_A, "merge_commit": SHA_B},
    {"pr_url": PR_URL, "head_sha": SHA_A},
    {"pr_url": PR_URL, "head_sha": SHA_A, "merge_commit": SHA_B, "producer_profile": "forged"},
])
def test_malformed_evidence_is_rejected_at_record_time(conn, payload):
    task_id = governed(conn, MERGED)
    run_id = claim(conn, task_id)
    with pytest.raises(EvidenceError) as err:
        add(conn, task_id, run_id, "pr_merged", payload)
    assert err.value.code == "malformed"
    assert list_evidence(conn, task_id) == []


def test_open_but_accepted_pr_does_not_complete(conn, fake_github, hooks):
    parent, child, run_id, workspace = _with_child(conn, MERGED)
    add(conn, parent, run_id, "pr_published", {"pr_url": PR_URL, "head_sha": SHA_A})
    add(conn, parent, run_id, "execution_ref", {"session_id": "s", "runtime": "claude"})
    with pytest.raises(OutcomeRefusedError) as err:
        complete(conn, parent, run_id)
    assert err.value.code == "missing"
    add(conn, parent, run_id, "pr_merged", merged_payload())
    fake_github["state"] = "OPEN"
    with pytest.raises(OutcomeRefusedError) as err:
        complete(conn, parent, run_id)
    assert err.value.code == "mismatch" and "never merges" in err.value.detail
    _assert_refused_untouched(conn, parent, child, workspace, hooks, "mismatch")


@pytest.mark.parametrize("field, value", [("head_sha", SHA_C), ("merge_commit", SHA_C)])
def test_changed_head_or_wrong_merge_commit_is_refused(conn, fake_github, hooks, field, value):
    parent, child, run_id, workspace = _with_child(conn, MERGED)
    add(conn, parent, run_id, "pr_merged", merged_payload())
    fake_github[field] = value
    with pytest.raises(OutcomeRefusedError) as err:
        complete(conn, parent, run_id)
    assert err.value.code == "mismatch"
    _assert_refused_untouched(conn, parent, child, workspace, hooks, "mismatch")


def test_wrong_repo_and_second_pr_are_refused(conn):
    task_id = governed(conn, MERGED)
    run_id = claim(conn, task_id)
    with pytest.raises(EvidenceError, match="requires acme/widget"):
        add(conn, task_id, run_id, "pr_merged", merged_payload(pr_url="https://github.com/other/repo/pull/7"))
    add(conn, task_id, run_id, "pr_published", {"pr_url": PR_URL, "head_sha": SHA_A})
    with pytest.raises(EvidenceError, match="already bound"):
        add(conn, task_id, run_id, "pr_merged", merged_payload(pr_url=f"https://github.com/{REPO}/pull/8"))


def test_unverifiable_github_read_refuses_without_guessing(conn, fake_github, hooks):
    parent, child, run_id, workspace = _with_child(conn, MERGED)
    add(conn, parent, run_id, "pr_merged", merged_payload())
    fake_github["raise"] = Unverifiable("HTTP 404 on graphql acme/widget")
    with pytest.raises(OutcomeRefusedError) as err:
        complete(conn, parent, run_id)
    assert err.value.code == "unverifiable"
    _assert_refused_untouched(conn, parent, child, workspace, hooks, "unverifiable")
    assert fake_github["calls"][0][2] == PROFILE


def test_evidence_from_another_run_never_counts(conn, fake_github):
    task_id = governed(conn, MERGED)
    old = claim(conn, task_id)
    add(conn, task_id, old, "pr_merged", merged_payload())
    assert kb.reclaim_task(conn, task_id, reason="stuck")
    new = claim(conn, task_id)
    with pytest.raises(OutcomeRefusedError) as err:
        complete(conn, task_id, new)
    assert err.value.code == "missing"
    assert kb.get_task(conn, task_id).status == "running"


def test_valid_merged_pr_completes_once_promotes_child_once_and_is_idempotent(conn, fake_github, hooks, coord_env):
    parent, child, run_id, _workspace = _with_child(conn, MERGED)
    first, created = add(conn, parent, run_id, "pr_merged", merged_payload())
    again, created_again = add(conn, parent, run_id, "pr_merged", merged_payload())
    assert created and not created_again and first.id == again.id
    assert complete(conn, parent, run_id)
    assert kb.get_task(conn, parent).status == "done"
    assert kb.get_task(conn, child).status == "ready"
    verified = [e for e in kb.list_events(conn, parent) if e.kind == "outcome_verified"]
    assert len(verified) == 1 and verified[0].payload["verified"]["merge_commit"] == SHA_B
    assert verified[0].payload["evidence"] == [first.id]

    def counts(c):
        return (
            c.execute("SELECT COUNT(*) FROM task_runs WHERE task_id=?", (parent,)).fetchone()[0],
            c.execute("SELECT COUNT(*) FROM task_events WHERE task_id=?", (parent,)).fetchone()[0],
            c.execute("SELECT COUNT(*) FROM task_evidence WHERE task_id=?", (parent,)).fetchone()[0],
            c.execute("SELECT COUNT(*) FROM task_events WHERE task_id=?", (child,)).fetchone()[0],
        )

    before = counts(conn)
    with kbc.connect(board=BOARD) as restarted:
        assert not complete(restarted, parent, run_id)
        with pytest.raises(EvidenceError):
            add(restarted, parent, run_id, "pr_merged", merged_payload())
        assert counts(restarted) == before
    assert hooks.count(("kanban_task_completed", parent)) == 1
    assert event_kinds(conn, parent).count("completed") == 1


def test_evidence_rows_are_immutable(conn):
    task_id = governed(conn, MERGED)
    run_id = claim(conn, task_id)
    item, _ = add(conn, task_id, run_id, "pr_published", {"pr_url": PR_URL, "head_sha": SHA_A})
    for sql in ("UPDATE task_evidence SET kind='pr_merged'", "DELETE FROM task_evidence"):
        with pytest.raises(Exception, match="append-only"):
            conn.execute(sql)
    row = list_evidence(conn, task_id)[0]
    assert row.producer_profile == PROFILE and row.producer_session == "sess-1" and row.source == "github"
    assert row.id == item.id


def test_evidence_requires_live_run_owner_and_legal_kind(conn):
    task_id = governed(conn, MERGED)
    run_id = claim(conn, task_id)
    with pytest.raises(EvidenceError) as err:
        add(conn, task_id, run_id, "pr_merged", merged_payload(), profile="intruder")
    assert err.value.code == "stale"
    with pytest.raises(EvidenceError) as err:
        add(conn, task_id, run_id, "artifact_built", {"sha256": SHA256_X, "name": "a"})
    assert err.value.code == "mismatch"
    ungoverned = kb.create_task(conn, title="plain", assignee=PROFILE)
    plain_run = claim(conn, ungoverned)
    with pytest.raises(EvidenceError, match="no outcome contract"):
        add(conn, ungoverned, plain_run, "execution_ref", {"session_id": "s", "runtime": "r"})


def test_built_artifact_must_match_attached_file(conn, tmp_path, hooks):
    parent, child, run_id, workspace = _with_child(conn, ARTIFACT)
    with pytest.raises(OutcomeRefusedError) as err:
        complete(conn, parent, run_id)
    assert err.value.code == "missing"
    add(conn, parent, run_id, "artifact_built", {"sha256": SHA256_X, "name": "app.zip"})
    with pytest.raises(OutcomeRefusedError, match="attach the built file"):
        complete(conn, parent, run_id)
    digest = attach_file(conn, parent, tmp_path)
    assert digest != SHA256_X
    with pytest.raises(OutcomeRefusedError) as err:
        complete(conn, parent, run_id)
    assert err.value.code == "mismatch"
    _assert_refused_untouched(conn, parent, child, workspace, hooks, "mismatch")
    add(conn, parent, run_id, "artifact_built", {"sha256": digest, "name": "app.zip"})
    assert complete(conn, parent, run_id)
    assert kb.get_task(conn, child).status == "ready"


def _installed_card(conn, tmp_path, **install):
    parent, child, run_id, workspace = _with_child(conn, INSTALLED)
    digest = attach_file(conn, parent, tmp_path)
    return parent, child, run_id, workspace, digest, install


def test_installed_app_needs_matching_readback_not_just_a_build(conn, tmp_path, hooks):
    parent, child, run_id, workspace, digest, _ = _installed_card(conn, tmp_path)
    add(conn, parent, run_id, "artifact_built", {"sha256": digest, "name": "app.zip"})
    with pytest.raises(OutcomeRefusedError) as err:
        complete(conn, parent, run_id)
    assert err.value.code == "missing" and "build alone" in err.value.detail
    add(conn, parent, run_id, "app_installed",
        {"app_id": "dev.acme.app", "artifact_sha256": digest, "readback_sha256": SHA256_X, "host": "mac-1"})
    with pytest.raises(OutcomeRefusedError) as err:
        complete(conn, parent, run_id)
    assert err.value.code == "mismatch"
    _assert_refused_untouched(conn, parent, child, workspace, hooks, "mismatch")
    add(conn, parent, run_id, "app_installed",
        {"app_id": "dev.acme.app", "artifact_sha256": digest, "readback_sha256": digest, "host": "mac-1"})
    assert complete(conn, parent, run_id)


def test_installed_app_artifact_must_equal_the_build(conn, tmp_path):
    parent, _child, run_id, _workspace, digest, _ = _installed_card(conn, tmp_path)
    add(conn, parent, run_id, "artifact_built", {"sha256": digest, "name": "app.zip"})
    add(conn, parent, run_id, "app_installed",
        {"app_id": "a", "artifact_sha256": SHA256_X, "readback_sha256": SHA256_X, "host": "h"})
    with pytest.raises(OutcomeRefusedError) as err:
        complete(conn, parent, run_id)
    assert err.value.code == "mismatch"


def test_other_outcome_needs_declared_contract_and_full_receipt(conn, hooks):
    plain = kb.create_task(conn, title="plain", assignee=PROFILE)
    plain_run = claim(conn, plain)
    with pytest.raises(EvidenceError):
        add(conn, plain, plain_run, "other_result", {"name": "report", "receipt": {"url": "u"}})
    parent, child, run_id, workspace = _with_child(conn, OTHER)
    with pytest.raises(OutcomeRefusedError) as err:
        complete(conn, parent, run_id)
    assert err.value.code == "missing"
    add(conn, parent, run_id, "other_result", {"name": "report", "receipt": {"url": "https://x"}})
    with pytest.raises(OutcomeRefusedError) as err:
        complete(conn, parent, run_id)
    assert err.value.code == "malformed" and "checked_by" in err.value.detail
    add(conn, parent, run_id, "other_result", {"name": "other-name", "receipt": {"url": "u", "checked_by": "x"}})
    with pytest.raises(OutcomeRefusedError) as err:
        complete(conn, parent, run_id)
    assert err.value.code == "mismatch"
    _assert_refused_untouched(conn, parent, child, workspace, hooks, "mismatch")
    add(conn, parent, run_id, "other_result", {"name": "report", "receipt": {"url": "u", "checked_by": "x"}})
    assert complete(conn, parent, run_id)


def test_local_only_completion_contract_cannot_downgrade_a_governed_card(conn):
    task_id = kb.create_task(conn, title="g", assignee=PROFILE, outcome_contract=MERGED, completion_contract="local-only")
    run_id = claim(conn, task_id)
    with pytest.raises(OutcomeRefusedError):
        complete(conn, task_id, run_id)
    assert kb.get_task(conn, task_id).status == "running"


def test_force_waives_the_fence_but_never_the_evidence(conn, fake_github, hooks):
    parent, child, run_id, workspace = _with_child(conn, MERGED)
    with pytest.raises(OutcomeRefusedError):
        kb.complete_task(conn, parent, summary="operator override", force=True)
    _assert_refused_untouched(conn, parent, child, workspace, hooks, "missing")
    assert list_evidence(conn, parent) == []
    add(conn, parent, run_id, "pr_merged", merged_payload())
    assert kb.complete_task(conn, parent, summary="operator override", force=True)
    assert kb.get_task(conn, child).status == "ready"


def test_review_approval_runs_the_same_gate(conn, fake_github, hooks):
    parent, child, run_id, workspace = _with_child(conn, MERGED)
    ok, _ = kb.request_review(conn, parent, summary="please check", expected_run_id=run_id, with_reason=True)
    assert ok and kb.get_task(conn, parent).status == "review"
    with pytest.raises(OutcomeRefusedError):
        kb.complete_task(conn, parent, summary="approved")
    assert kb.get_task(conn, parent).status == "review" and kb.get_task(conn, child).status == "todo"
    assert workspace.exists()


def test_review_approval_succeeds_with_evidence_from_the_review_run(conn, fake_github, hooks):
    parent, child, run_id, _workspace = _with_child(conn, MERGED)
    add(conn, parent, run_id, "pr_merged", merged_payload())
    kb.request_review(conn, parent, summary="please check", expected_run_id=run_id)
    assert kb.complete_task(conn, parent, summary="approved")
    assert kb.get_task(conn, parent).status == "done" and kb.get_task(conn, child).status == "ready"
    assert hooks.count(("kanban_task_completed", parent)) == 1


def test_cli_complete_refuses_then_succeeds(conn, fake_github, as_profile):
    parent, child, run_id, workspace = _with_child(conn, MERGED)
    out = kanban_cli.run_slash(f"complete {parent} --run-id {run_id} --summary done")
    assert "outcome refused (missing)" in out and "unchanged" in out
    assert kb.get_task(conn, child).status == "todo" and workspace.exists()
    bad = kanban_cli.run_slash(f"evidence add {parent} --run-id {run_id} --kind pr_merged --json '{{\"pr_url\":\"x\"}}'")
    assert "malformed" in bad
    payload = json.dumps(merged_payload())
    assert "Recorded" in kanban_cli.run_slash(f"evidence add {parent} --run-id {run_id} --kind pr_merged --json '{payload}'")
    assert "Already recorded" in kanban_cli.run_slash(f"evidence add {parent} --run-id {run_id} --kind pr_merged --json '{payload}'")
    listed = json.loads(kanban_cli.run_slash(f"evidence list {parent} --json"))
    assert [e["kind"] for e in listed] == ["pr_merged"]
    as_profile("intruder")
    assert "does not own" in kanban_cli.run_slash(f"complete {parent} --run-id {run_id} --summary done")
    as_profile(PROFILE)
    assert "Completed" in kanban_cli.run_slash(f"complete {parent} --run-id {run_id} --summary done")
    assert kb.get_task(conn, child).status == "ready"


def test_cli_create_accepts_outcome_contract(coord_env):
    out = kanban_cli.run_slash(
        f"create governed --assignee {PROFILE} --outcome-contract '{json.dumps(MERGED)}' --json")
    assert json.loads(out)["outcome_contract"] == json.dumps(MERGED, sort_keys=True, separators=(",", ":"))


def test_legacy_cards_complete_as_before(coord_env):
    kb.create_board("plain")
    with kbc.connect(board="plain") as plain:
        task_id = kb.create_task(plain, title="legacy", assignee="worker")
        assert kb.claim_task(plain, task_id)
        run_id = kb._current_run_id(plain, task_id)
        assert kb.complete_task(plain, task_id, summary="done", expected_run_id=run_id)
        assert "outcome_verified" not in event_kinds(plain, task_id)


def test_swarm_root_activation_cannot_close_a_governed_card(conn):
    task_id = governed(conn, MERGED)
    conn.execute("UPDATE tasks SET status='blocked' WHERE id=?", (task_id,))
    conn.commit()
    assert not ks._activate_root_inline(conn, task_id, summary="s", metadata={})
    assert kb.get_task(conn, task_id).status == "blocked"


def test_governed_contract_is_refused_on_a_board_that_cannot_provide_evidence(coord_env):
    kb.create_board("ordinary")
    with pytest.raises(ValueError, match="coordinator-owned board"):
        _create_on("ordinary")


def _create_on(board):
    from hermes_cli import kanban_db_connect as kbc
    with kbc.connect_closing(board=board) as c:
        return kb.create_task(c, title="stranded", assignee=PROFILE, board=board,
                              outcome_contract={"kind": "built_artifact"})


def test_verification_status_is_reported_honestly(conn, tmp_path):
    parent, _child, run_id, _workspace, digest, _ = _installed_card(conn, tmp_path)
    add(conn, parent, run_id, "artifact_built", {"sha256": digest, "name": "app.zip"})
    add(conn, parent, run_id, "app_installed",
        {"app_id": "dev.acme.app", "artifact_sha256": digest, "readback_sha256": digest, "host": "mac-1"})
    assert complete(conn, parent, run_id)
    row = conn.execute("SELECT payload FROM task_events WHERE task_id=? AND kind='outcome_verified'", (parent,)).fetchone()
    assert json.loads(row[0])["verified"]["verification"] == "attested"

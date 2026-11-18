import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

BOARD = "ops"
BOT = "bot-alpha"
READY_TITLE = "Write release notes"
FOOTER_RULE = "---- faker-kit machine fields (read by the kit, do not edit) ----"
BODY = (
    f"{READY_TITLE}\n\n"
    "## Goal\nDraft the **beta** release notes and link the `CHANGELOG`.\n\n"
    "## Done means\n- list the fixes\n- thank the testers\n\n"
    "## Owner decisions\nConfirm the launch date with PAL-13 before publishing.\n\n"
    f"{FOOTER_RULE}\nKey: PAL-1\nState: ready\nHistory: created\nRef: PAL-12\n"
)
SOURCES = {"pr_published": "github", "pr_merged": "github", "artifact_built": "local-file"}
PR_URL = "https://github.com/example/app/pull/42"
OTHER_PR_URL = "https://github.com/example/app/pull/43"


def body_with_ref(title, ref):
    return f"{title}\n\n{FOOTER_RULE}\nRef: {ref}\n"


def load(home, repo):
    os.environ["HERMES_HOME"] = str(home)
    sys.path.insert(0, str(repo))
    from hermes_cli import kanban_db as kb
    from hermes_cli import kanban_db_connect as kbc
    return kb, kbc


def find(kb, conn, title):
    return next(task for task in kb.list_tasks(conn) if task.title == title)


def seed(home, repo):
    kb, kbc = load(home, repo)
    kb.init_db()
    kb.create_board(BOARD, name="Ops")
    with kbc.connect_closing(board=BOARD) as conn:
        ready = kb.create_task(conn, title=READY_TITLE, body=BODY, assignee=BOT, board=BOARD)
        for title, ref, extra in [
            ("Triage the inbox", "PAL-16", {"triage": True}),
            ("Ship the beta", "PAL-13", {"parents": (ready,)}),
        ]:
            kb.create_task(conn, title=title, body=body_with_ref(title, ref), assignee=BOT, board=BOARD, **extra)
        blocked = kb.create_task(conn, title="Fix the login", body=body_with_ref("Fix the login", "PAL-14"), assignee=BOT, board=BOARD)
        kb.block_task(conn, blocked, reason="waiting on credentials")
        finished = kb.create_task(conn, title="Publish the docs", body=body_with_ref("Publish the docs", "PAL-15"), assignee=BOT, board=BOARD)
        kb.complete_task(conn, finished, summary="published")
        record_evidence_history(conn, finished)


def insert_evidence(conn, task_id, run_id, kind, payload, observed_at):
    digest = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
    conn.execute(
        "INSERT INTO task_evidence (task_id, run_id, kind, digest, payload, producer_profile, source, observed_at)"
        " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (task_id, run_id, kind, digest, json.dumps(payload, sort_keys=True), BOT, SOURCES.get(kind, "attestation"), observed_at))


def record_evidence_history(conn, task_id):
    from hermes_cli.kanban_outcomes_store import ensure_schema
    ensure_schema(conn)
    clock = iter(range(1_700_000_000, 1_700_000_100))
    sha = "a" * 40
    insert_evidence(conn, task_id, 1, "artifact_built", {"name": "docs.zip", "sha256": "b" * 64}, next(clock))
    insert_evidence(conn, task_id, 1, "execution_ref", {"runtime": "local", "session_id": "e2e-session"}, next(clock))
    insert_evidence(conn, task_id, 1, "pr_published", {"pr_url": OTHER_PR_URL, "head_sha": sha}, next(clock))
    for run_id in range(1, 5):
        insert_evidence(conn, task_id, run_id, "pr_published", {"pr_url": PR_URL, "head_sha": sha}, next(clock))
    for run_id in range(1, 5):
        insert_evidence(conn, task_id, run_id, "pr_merged", {"pr_url": PR_URL, "head_sha": sha, "merge_commit": "c" * 40}, next(clock))
    conn.commit()


def advance(home, repo):
    kb, kbc = load(home, repo)
    with kbc.connect_closing(board=BOARD) as conn:
        kb.complete_task(conn, find(kb, conn, READY_TITLE).id, summary="notes written")


def main():
    parser = argparse.ArgumentParser(description="Seed a Kanban board into an e2e sandbox home and move one card on demand")
    parser.add_argument("command", choices=["seed", "advance"])
    parser.add_argument("--home", required=True, type=Path)
    parser.add_argument("--repo", required=True, type=Path)
    args = parser.parse_args()
    {"seed": seed, "advance": advance}[args.command](args.home, args.repo)


if __name__ == "__main__":
    main()

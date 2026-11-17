import argparse
import os
import sys
from pathlib import Path

BOARD = "ops"
BOT = "bot-alpha"
READY_TITLE = "Write release notes"
BODY = (
    "Draft the **beta** release notes and link the `CHANGELOG`.\n\n"
    "- list the fixes\n- thank the testers\n\n"
    "Key: PAL-1\nState: ready\nHistory: created\n"
)


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
        kb.create_task(conn, title="Triage the inbox", assignee=BOT, triage=True, board=BOARD)
        kb.create_task(conn, title="Ship the beta", assignee=BOT, parents=(ready,), board=BOARD)
        blocked = kb.create_task(conn, title="Fix the login", assignee=BOT, board=BOARD)
        kb.block_task(conn, blocked, reason="waiting on credentials")
        finished = kb.create_task(conn, title="Publish the docs", assignee=BOT, board=BOARD)
        kb.complete_task(conn, finished, summary="published")
        record_merged_pr(conn, finished)


def record_merged_pr(conn, task_id):
    from hermes_cli.kanban_outcomes_store import ensure_schema
    ensure_schema(conn)
    conn.execute(
        "INSERT INTO task_evidence (task_id, run_id, kind, digest, payload, producer_profile, source, observed_at)"
        " VALUES (?, 0, 'pr_merged', 'e2e', ?, ?, 'github', 1)",
        (task_id, '{"pr_url": "https://github.com/example/app/pull/42"}', BOT))
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

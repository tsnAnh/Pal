import argparse
import asyncio
import json
import os
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import perf_common
from perf_common import BOT_CHAT_TITLE, PROFILE_SIZES
from perf_corpus import build_corpus, describe

SESSION_SOURCE = "gui"
HOME_MARKER = "hermes-ios-e2e."
CORPUS_SEED = 20260514


def require_sandbox_home(home):
    resolved = home.resolve()
    if not any(part.startswith(HOME_MARKER) for part in resolved.parts):
        raise SystemExit(f"refusing to seed {resolved}: not an e2e sandbox home")
    if not (resolved / "config.yaml").is_file():
        raise SystemExit(f"refusing to seed {resolved}: no config.yaml")
    return resolved


async def find_or_create_chat(rpc, profile):
    found = await rpc.call("session.list", {"profile": profile, "title": BOT_CHAT_TITLE, "include_hidden": True})
    rows = [row for row in found["result"]["sessions"] if row.get("title") == BOT_CHAT_TITLE]
    if rows:
        return rows[0].get("resolved_id") or rows[0]["session_id"]
    await rpc.call("session.create", {
        "profile": profile, "title": BOT_CHAT_TITLE, "hidden": True,
        "request_id": str(uuid.uuid4()), "source": SESSION_SOURCE,
    })
    listed = await rpc.call("session.list", {"profile": profile, "title": BOT_CHAT_TITLE, "include_hidden": True})
    row = listed["result"]["sessions"][0]
    return row.get("resolved_id") or row["session_id"]


def write_corpus(profile_dir, session_id, corpus, reset):
    from hermes_state import SessionDB

    database = SessionDB(db_path=profile_dir / "state.db")
    try:
        existing = database.get_session(session_id)
        if existing and int(existing.get("message_count") or 0) > 0:
            if not reset:
                return int(existing["message_count"])
            database._write_sql("DELETE FROM messages WHERE session_id = ?", (session_id,))
            database._write_sql("UPDATE sessions SET message_count = 0, tool_call_count = 0 WHERE id = ?", (session_id,))
        for row in corpus.rows:
            database.append_message(
                session_id, row.role, row.content, tool_name=row.tool_name, tool_calls=row.tool_calls,
                tool_call_id=row.tool_call_id, timestamp=row.timestamp)
        database._write_sql(
            "UPDATE sessions SET started_at = ?, last_activity_at = ? WHERE id = ?",
            (corpus.rows[0].timestamp, corpus.rows[-1].timestamp, session_id))
    finally:
        database.close()
    return 0


async def seed_profile(rpc, home, profile, rows, now, reset):
    session_id = await find_or_create_chat(rpc, profile)
    profile_dir = perf_common.profile_directory(home, profile)
    corpus = build_corpus(rows, CORPUS_SEED, now, profile_dir / "cache" / "images")
    for path, data in corpus.files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    already = write_corpus(profile_dir, session_id, corpus, reset)
    return {"profile": profile, "session_id": session_id, "already_seeded": already, **describe(corpus)}


async def seed(home, sizes, reset):
    client = perf_common.load_gateway_client()
    target = perf_common.target_from_environment()
    gateway = client.Gateway(target["base_url"], target["username"], target["password"])
    socket, rpc = await perf_common.open_rpc(client, gateway)
    now = time.time()
    try:
        return [await seed_profile(rpc, home, profile, rows, now, reset) for profile, rows in sizes.items()]
    finally:
        await socket.close()


def main():
    parser = argparse.ArgumentParser(description="Seed long Bot Chat transcripts into the sandbox bot profiles")
    parser.add_argument("--home", required=True, type=Path)
    parser.add_argument("--repo", type=Path, default=perf_common.REPO)
    parser.add_argument("--reset", action="store_true", help="replace the rows of a Bot Chat that already holds messages")
    parser.add_argument("--sizes", default=",".join(f"{profile}={rows}" for profile, rows in PROFILE_SIZES.items()))
    args = parser.parse_args()
    sizes = {pair.split("=")[0]: int(pair.split("=")[1]) for pair in args.sizes.split(",")}
    home = require_sandbox_home(args.home)
    os.environ["HERMES_HOME"] = str(home)
    sys.path.insert(0, str(args.repo))
    print(json.dumps(asyncio.run(seed(home, sizes, args.reset)), indent=2))


if __name__ == "__main__":
    main()

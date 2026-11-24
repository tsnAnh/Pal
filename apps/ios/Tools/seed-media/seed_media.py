import argparse
import asyncio
import os
import shutil
import sys
import time
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS_DIR / "perf"))

import perf_common
import perf_seed

FIXTURES = TOOLS_DIR.parent / "Fixtures" / "media"
PROFILE = "media-bot"
HUGE_BYTES = 200_000_000 + 1
GRID_NAMES = ("grid-1.mp4", "grid-2.mp4", "grid-3.mp4")


def write_media(home):
    directory = home / "media-fixtures"
    directory.mkdir(exist_ok=True)
    for name in ("clip.mp4", "note.m4a"):
        shutil.copyfile(FIXTURES / name, directory / name)
    for name in GRID_NAMES:
        shutil.copyfile(FIXTURES / "clip.mp4", directory / name)
    with (directory / "huge.mp4").open("wb") as handle:
        handle.truncate(HUGE_BYTES)
    return directory


def messages(directory):
    first = ["Here are your files."] + [f"MEDIA: {directory / name}" for name in ("clip.mp4", "note.m4a", "huge.mp4")]
    later = ["And three more clips."] + [f"MEDIA: {directory / name}" for name in GRID_NAMES]
    return ["\n".join(first), "\n".join(later)]


def write_messages(profile_dir, session_id, contents, now):
    from hermes_state import SessionDB

    database = SessionDB(db_path=profile_dir / "state.db")
    try:
        existing = database.get_session(session_id)
        if existing and int(existing.get("message_count") or 0) > 0:
            return
        start = now - 60 * len(contents)
        for number, content in enumerate(contents):
            database.append_message(session_id, "assistant", content, timestamp=start + number * 60)
        database._write_sql(
            "UPDATE sessions SET started_at = ?, last_activity_at = ? WHERE id = ?",
            (start, start + 60 * len(contents), session_id))
    finally:
        database.close()


async def seed(home):
    client = perf_common.load_gateway_client()
    target = perf_common.target_from_environment()
    gateway = client.Gateway(target["base_url"], target["username"], target["password"])
    socket, rpc = await perf_common.open_rpc(client, gateway)
    try:
        session_id = await perf_seed.find_or_create_chat(rpc, PROFILE)
    finally:
        await socket.close()
    directory = write_media(home)
    write_messages(perf_common.profile_directory(home, PROFILE), session_id, messages(directory), time.time())
    print(f"seeded {PROFILE} session {session_id} media in {directory}")


def main():
    parser = argparse.ArgumentParser(description="Seed the media-bot Bot Chat with video, audio, oversized and grid MEDIA messages")
    parser.add_argument("--home", required=True, type=Path)
    parser.add_argument("--repo", type=Path, default=perf_common.REPO)
    args = parser.parse_args()
    home = perf_seed.require_sandbox_home(args.home)
    os.environ["HERMES_HOME"] = str(home)
    sys.path.insert(0, str(args.repo))
    asyncio.run(seed(home))


if __name__ == "__main__":
    main()

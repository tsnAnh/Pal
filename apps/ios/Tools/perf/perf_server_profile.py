import json
import os
import re
import shutil
import sys
import tempfile
import time
from pathlib import Path

import perf_common

STAGES = (
    "prepare_history_display_rows", "local_history_reread_live", "merge_and_authored_text", "json_dumps_snapshot",
    "json_dumps_snapshot_without_tool_rows",
)


def timed(body):
    started = time.perf_counter()
    value = body()
    return value, (time.perf_counter() - started) * 1000


def copy_profile_db(profile_dir, scratch):
    home = Path(scratch) / "home"
    home.mkdir()
    for name in ("state.db", "state.db-wal", "state.db-shm"):
        source = profile_dir / name
        if source.exists():
            shutil.copy2(source, home / name)
    return home


IMAGE_URI = re.compile(r"data:image/[a-z]+;base64,[A-Za-z0-9+/=]+")


def profile_session(repo, profile_dir, session_id, iterations):
    scratch = tempfile.mkdtemp(prefix="perf-server-profile.")
    try:
        home = copy_profile_db(profile_dir, scratch)
        os.environ["HERMES_HOME"] = str(home)
        os.environ["HERMES_DISABLE_LAZY_INSTALLS"] = "1"
        sys.path.insert(0, str(repo))
        from gateway.session_local_recovery import _merge_live_in_stored_order, _with_authored_text, display_rows
        from hermes_state import SessionDB

        database = SessionDB(db_path=home / "state.db")
        samples = {stage: [] for stage in STAGES}
        sizes = {}
        try:
            for _ in range(iterations + 1):
                (_read_live, display, _truncated), prepare_ms = timed(lambda: display_rows(database, session_id))
                live, reread_ms = timed(lambda: database.get_messages_as_conversation(session_id, include_row_ids=True))
                rows, merge_ms = timed(lambda: [
                    _with_authored_text({**{k: v for k, v in row.items() if k != "_row_id"}, "row_id": row["_row_id"]})
                    for row in _merge_live_in_stored_order(display, live)])
                body, dumps_ms = timed(lambda: json.dumps({"messages": rows}))
                lean_tools, lean_tools_ms = timed(lambda: json.dumps({"messages": [row for row in rows if row.get("role") != "tool"]}))
                sizes = {
                    "messages": len(rows), "snapshot_bytes": len(body), "snapshot_bytes_without_tool_rows": len(lean_tools),
                    "snapshot_bytes_without_images": len(IMAGE_URI.sub("[image]", body)),
                }
                for stage, value in zip(STAGES, (prepare_ms, reread_ms, merge_ms, dumps_ms, lean_tools_ms)):
                    samples[stage].append(value)
        finally:
            database.close()
        return {"sizes": sizes, "stages": {stage: perf_common.summarize(values[1:]) for stage, values in samples.items()}}
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

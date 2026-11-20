#!/usr/bin/env -S bash -c 'exec "$BASH" "$(dirname "$0")/run-in-hermes-env" python3 "$0" "$@"'
from __future__ import annotations

import base64
import hashlib
import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

PAGE = b"<html><body>mockup</body></html>"
POLICY_ENVS = ("HERMES_MEDIA_DELIVERY_STRICT", "HERMES_MEDIA_TRUST_RECENT_FILES", "HERMES_MEDIA_ALLOW_DIRS")


def _asset_ref(path: Path) -> str:
    return hashlib.sha256(f"file\x00{path}".encode()).hexdigest()[:32]


def _set_policy(**env: str) -> None:
    for name in POLICY_ENVS:
        os.environ.pop(name, None)
    os.environ.update(env)


def main() -> int:
    work = Path(tempfile.mkdtemp(prefix="hermes-e2e-media-"))
    home = work / "hermes-home"
    home.mkdir()
    (work / "user-home").mkdir()
    os.environ["HOME"] = str(work / "user-home")
    os.environ["HERMES_HOME"] = str(home)

    from persistence.conversation.messages import NewMessage
    from persistence.conversation.sessions import NewSession
    from persistence_assembly import open_persistence, profile_scope
    from tui_gateway import server

    db = open_persistence(profile_scope(home=home), eager=True)
    server._db = db
    outside = work / "chief-checks"
    outside.mkdir()
    page = outside / "mockup.html"
    page.write_bytes(PAGE)
    previewed = outside / "widget.html"
    previewed.write_bytes(PAGE)
    stale = outside / "stale.html"
    stale.write_bytes(PAGE)
    old = time.time() - 7200
    os.utime(stale, (old, old))
    gone = outside / "gone.html"

    db.sessions.create(NewSession(session_id="e2e", source="cli"))
    lines = [f"MEDIA:{page}", f'::preview{{file="{previewed}"}}', f"MEDIA:{stale}", f"MEDIA:{gone}"]
    db.messages.append("e2e", NewMessage(role="assistant", content="Here.\n" + "\n".join(lines), timestamp=1_700_000_000.0))

    def ask(path: Path, **extra) -> dict:
        request = {"jsonrpc": "2.0", "id": 1, "method": "library.asset",
                   "params": {"asset_ref": _asset_ref(path), "thumbnail": False, **extra}}
        return server.handle_request(request)

    cases = [
        ("default policy serves a MEDIA path outside any profile home", {}, page, {}, "bytes"),
        ("default policy serves a ::preview path", {}, previewed, {}, "bytes"),
        ("strict mode with the directory allow-listed serves it", {
            "HERMES_MEDIA_DELIVERY_STRICT": "1", "HERMES_MEDIA_TRUST_RECENT_FILES": "0",
            "HERMES_MEDIA_ALLOW_DIRS": str(outside)}, page, {}, "bytes"),
        ("strict mode serves a fresh file inside the recency window", {
            "HERMES_MEDIA_DELIVERY_STRICT": "1", "HERMES_MEDIA_TRUST_RECENT_FILES": "1"}, page, {}, "bytes"),
        ("strict mode refuses an old file outside the allow-list", {
            "HERMES_MEDIA_DELIVERY_STRICT": "1", "HERMES_MEDIA_TRUST_RECENT_FILES": "1"}, stale, {}, 4154),
        ("a missing file is not found", {}, gone, {}, 4151),
        ("a file over the cap is too large", {}, page, {"max_bytes": 1}, 4152),
    ]
    failed = 0
    try:
        for name, policy, path, extra, expected in cases:
            _set_policy(**policy)
            response = ask(path, **extra)
            if expected == "bytes":
                served = base64.b64decode(response.get("result", {}).get("data_base64", ""))
                outcome = {"ok": served == PAGE, "sent_sha256": hashlib.sha256(PAGE).hexdigest(),
                           "read_sha256": hashlib.sha256(served).hexdigest()}
            else:
                code = response.get("error", {}).get("code")
                outcome = {"ok": code == expected, "expected_code": expected, "code": code}
            failed += not outcome["ok"]
            print(json.dumps({"case": name, **outcome}))
    finally:
        db.close()
        shutil.rmtree(work, ignore_errors=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

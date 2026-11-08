from __future__ import annotations

import base64
import io
import tarfile
from pathlib import Path

import pytest

from cron.jobs import create_job, use_cron_store
from hermes_cli.profiles import create_profile, get_profile_dir
from tui_gateway import server

SECRETS = (
    "sk-scout-ENVSECRET0123456789abcdef",
    "xoxb-AUTHJSONSECRET-0123456789",
    "mcp-env-SECRETVALUE-0123456789abcdef",
    "Bearer-HEADERSECRET-0123456789abcdef",
    "cfg-apikey-SECRETVALUE-0123456789abcdef",
    "PRIVATE_MEMORY_LINE",
)
ROUTINE_KEY = "sk-routine-PROMPTSECRET0123456789abcdef"


@pytest.fixture
def scout(tmp_path, monkeypatch) -> Path:
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(server, "_hermes_home", home)
    create_profile("scout", no_alias=True, no_skills=True, soul="You are Scout.")
    path = get_profile_dir("scout")
    (path / ".env").write_text(f"OPENAI_API_KEY={SECRETS[0]}\n", encoding="utf-8")
    (path / "auth.json").write_text(f'{{"token": "{SECRETS[1]}"}}', encoding="utf-8")
    (path / "memories").mkdir(exist_ok=True)
    (path / "memories" / "MEMORY.md").write_text(SECRETS[5], encoding="utf-8")
    (path / "config.yaml").write_text(
        "model:\n  provider: openai\n  default: gpt-5\n  api_key: " + SECRETS[4] + "\n"
        "mcp_servers:\n  files:\n    command: npx\n    args: [files-server]\n"
        f"    env:\n      FILES_TOKEN: {SECRETS[2]}\n"
        f"  remote:\n    url: https://mcp.example.com/sse\n    headers:\n      Authorization: {SECRETS[3]}\n",
        encoding="utf-8")
    with use_cron_store(path):
        create_job(f"Check the build with key {ROUTINE_KEY}", "0 9 * * 1-5", name="Weekday digest")
    return path


def _exported_members() -> tuple[dict, dict[str, bytes]]:
    from tui_gateway.contracts import METHODS

    response = server._methods["profiles.template.export"](1, {"name": "scout"})
    assert "error" not in response, response.get("error")
    result = METHODS["profiles.template.export"].result.model_validate(response["result"]).model_dump()
    raw = base64.b64decode(result["data"], validate=True)
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as archive:
        members = {m.name: archive.extractfile(m).read() for m in archive.getmembers() if m.isfile()}
    return result, members


def test_export_is_a_share_sheet_ready_file(scout):
    result, members = _exported_members()
    assert result["filename"] == "scout.hermesbot"
    assert result["size"] > 0 and len(result["sha256"]) == 64
    assert {"manifest.json", "bot.json", "SOUL.md"} <= set(members)


def test_no_member_of_the_exported_archive_carries_a_secret_or_private_memory(scout):
    _, members = _exported_members()
    bot = members["bot.json"].decode()
    assert "Weekday digest" in bot and "files-server" in bot and "mcp.example.com" in bot
    leaked =[(name, secret) for name, blob in members.items() for secret in (*SECRETS, ROUTINE_KEY)
              if secret.encode() in blob]
    assert leaked == []


def test_export_leaves_out_credential_files_memories_and_raw_config(scout):
    _, members = _exported_members()
    names = set(members)
    assert not {".env", "auth.json", "config.yaml"} & names
    assert not any(name.startswith(("memories/", "sessions/")) or name.endswith(("state.db", ".env")) for name in names)

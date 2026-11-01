"""Bot templates: a shareable copy of a bot's setup, never its history or secrets.

Export is an allowlist (SOUL.md, skills, non-secret config, look, avatar, routine definitions);
import treats the archive as hostile input and shows the owner what it carries before anything is
created.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import tarfile
from pathlib import Path

import hermes_yaml as yaml
import pytest

from cron.jobs import create_job, load_jobs, save_jobs, use_cron_store
from hermes_cli import bot_template
from hermes_cli.bot_template import BotTemplateError
from hermes_cli.config import read_user_config_raw
from hermes_cli.profiles import create_profile, get_profile_dir, list_profile_names, write_profile_meta

PNG = b"\x89PNG\r\n\x1a\n" + b"avatar-pixels"
SECRETS = (
    "SECRET_MEMORY_TEXT", "SECRET_SESSION_TEXT", "sk-live-ABCDEF0123456789ABCDEF", "literal-secret-123",
    "Bearer abc123token", "SECRETQUERY", "TELEGRAMSECRET", "sk-custom-SECRET0123456789", "oauth-client-secret-zzz",
    "VAULT_KEY_MATERIAL", "WEBHOOK_HMAC_SECRET", "COOKIE_JAR", "OUTPUT_OF_A_RUN", "ENV_FILE_TOKEN",
)


@pytest.fixture
def home(tmp_path, monkeypatch) -> Path:
    root = tmp_path / ".hermes"
    root.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(root))
    return root


def _write(path: Path, content: str | bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content if isinstance(content, bytes) else content.encode())


@pytest.fixture
def scout(home) -> Path:
    create_profile("scout", no_alias=True, no_skills=True, description="Watches the build", soul="You are Scout.")
    path = get_profile_dir("scout")
    _write(path / "SOUL.md", "You are Scout. Keep builds green.\n")
    _write(path / "skills" / "dev" / "review" / "SKILL.md", "---\nname: review\n---\nReview carefully.\n")
    _write(path / "skills" / "dev" / "review" / "scripts" / "run.sh", "#!/bin/sh\necho review\n")
    _write(path / "skills" / "dev" / "review" / ".env", "ENV_FILE_TOKEN=abc\n")
    _write(path / "skills" / ".hub" / "lock.json", "{}")
    _write(path / "skills" / ".usage.json", "{}")
    _write(path / "skills" / "dev" / "review" / "__pycache__" / "x.pyc", b"\x00")
    _write(path / "memories" / "MEMORY.md", "SECRET_MEMORY_TEXT")
    _write(path / "sessions" / "s1.json", "SECRET_SESSION_TEXT")
    _write(path / "state.db", b"SQLite format 3\x00SECRET_SESSION_TEXT")
    _write(path / "logs" / "agent.log", "SECRET_SESSION_TEXT")
    _write(path / ".env", "OPENAI_API_KEY=sk-live-ABCDEF0123456789ABCDEF\nENV_FILE_TOKEN=abc\n")
    _write(path / "auth.json", '{"token": "sk-live-ABCDEF0123456789ABCDEF"}')
    _write(path / "vault" / "vault.json.enc", "VAULT_KEY_MATERIAL")
    _write(path / "webhook_subscriptions.json", '{"hmac": "WEBHOOK_HMAC_SECRET"}')
    _write(path / "bot-desktop" / "browser-profile" / "Cookies", "COOKIE_JAR")
    _write(path / "assets" / "avatar.png", PNG)
    _write(
        path / "config.yaml",
        yaml.safe_dump({
            "model": {
                "provider": "openrouter", "default": "anthropic/claude-sonnet-4",
                "base_url": "https://user:pw@example.com/v1?key=SECRETQUERY",
                "api_key": "sk-live-ABCDEF0123456789ABCDEF",
            },
            "platform_toolsets": {"cli": ["web", "file"]},
            "skills": {"disabled": ["noisy-skill"]},
            "mcp_servers": {
                "tracker": {
                    "command": "tracker-mcp", "args": ["--workspace", "main"], "enabled": True,
                    "env": {"TRACKER_TOKEN": "literal-secret-123", "REGION": "${TRACKER_REGION}"},
                },
                "remote": {
                    "url": "https://user:pw@mcp.example.com/sse?token=SECRETQUERY&x=1",
                    "headers": {"Authorization": "Bearer abc123token", "X-Team": "blue"},
                    "auth": "oauth", "oauth": {"client_secret": "oauth-client-secret-zzz"},
                },
            },
            "telegram": {"bot_token": "123456:TELEGRAMSECRET"},
            "custom_providers": [{"name": "mine", "api_key": "sk-custom-SECRET0123456789"}],
            "terminal": {"cwd": "/Users/someone/private"},
        }),
    )
    write_profile_meta(path, display_name="Scout", description="Watches the build")
    meta = yaml.safe_load((path / "profile.yaml").read_text())
    meta["ui_meta"] = {"hermes-bots": {
        "color": "#336699", "shape": "blobatar", "custom": True, "imageKind": "photo", "title": "Scout",
        "pinned": True, "hidden": True, "sectionId": "s1", "sectionName": "Work", "groups": ["ops"],
        "group": "ops", "chat": "old-pin", "created": 1, "screenAutoOpen": True,
    }, "other-plugin": {"k": "v"}}
    (path / "profile.yaml").write_text(yaml.safe_dump(meta))
    with use_cron_store(path):
        create_job("Summarize overnight failures", "0 9 * * *", name="Morning digest", deliver="telegram:42",
                   skills=["dev/review"], timezone="Europe/Paris")
        create_job("Poll the queue", "every 30m", name="Queue poll")
        create_job("Never shared", "every 2h", name="Scripted")
        jobs = load_jobs()
        jobs[-1]["script"] = "check.sh"
        save_jobs(jobs)
        _write(path / "cron" / "output" / jobs[0]["id"] / "run.md", "OUTPUT_OF_A_RUN")
    return path


def _members(data: bytes) -> dict[str, bytes]:
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf:
        return {m.name: tf.extractfile(m).read() for m in tf.getmembers() if m.isfile()}


def _bot(data: bytes) -> dict:
    return json.loads(_members(data)["bot.json"])


def _tarinfo(name: str, *, kind: bytes = tarfile.REGTYPE, size: int = 0, linkname: str = "") -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.type = kind
    info.size = size
    info.linkname = linkname
    info.mode = 0o644
    return info


def _gz_tar(entries: list[tuple[tarfile.TarInfo, bytes | None]]) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for info, payload in entries:
            tf.addfile(info, io.BytesIO(payload) if payload is not None else None)
    return buf.getvalue()


def _manifest(files: dict[str, bytes], **patch) -> dict:
    manifest = {
        "format": "hermes-bot-template", "format_version": 1, "created_at": "2026-11-01T00:00:00+00:00",
        "app_version": "0.0.0", "display_name": "Crafted",
        "contents": [
            {"path": name, "size": len(blob), "sha256": hashlib.sha256(blob).hexdigest()}
            for name, blob in sorted(files.items())
        ],
    }
    manifest.update(patch)
    return manifest


def _pack(files: dict[str, bytes] | None = None, *, manifest: dict | bytes | None = None, extra=()) -> bytes:
    files = {"bot.json": b'{"display_name": "Crafted"}'} if files is None else files
    declared = manifest if manifest is not None else _manifest(files)
    manifest_bytes = declared if isinstance(declared, bytes) else json.dumps(declared).encode()
    entries = [(_tarinfo("manifest.json", size=len(manifest_bytes)), manifest_bytes)]
    entries += [(_tarinfo(name, size=len(blob)), blob) for name, blob in files.items()]
    entries += list(extra)
    return _gz_tar(entries)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def test_export_ships_only_the_allowlist(scout):
    names = set(_members(bot_template.export_template("scout")))
    assert {"manifest.json", "bot.json", "SOUL.md", "assets/avatar.png"} <= names
    assert "skills/dev/review/SKILL.md" in names
    assert "skills/dev/review/scripts/run.sh" in names
    for name in names:
        assert name in {"manifest.json", "bot.json", "SOUL.md"} or name.startswith(("skills/", "assets/avatar."))


def test_export_leaves_out_history_and_secrets(scout):
    data = bot_template.export_template("scout")
    members = _members(data)
    blob = b"\n".join(members.values()).decode("utf-8", "replace")
    assert [secret for secret in SECRETS if secret in blob] == []
    forbidden = ("memories/", "sessions/", "state.db", "logs/", ".env", "auth.json", "vault", "bot-desktop",
                 "webhook_subscriptions", "cron/", "__pycache__", ".hub", ".usage.json")
    assert [name for name in members if any(part in name for part in forbidden)] == []


def test_export_config_is_scrubbed_to_non_secret_fields(scout):
    config = _bot(bot_template.export_template("scout"))["config"]
    assert config == {
        "model": {"provider": "openrouter", "default": "anthropic/claude-sonnet-4"},
        "platform_toolsets": {"cli": ["web", "file"]},
        "skills": {"disabled": ["noisy-skill"]},
        "mcp_servers": {
            "tracker": {
                "command": "tracker-mcp", "args": ["--workspace", "main"], "enabled": True,
                "env": {"TRACKER_TOKEN": "", "REGION": ""},
            },
            "remote": {"url": "https://mcp.example.com/sse", "headers": {"Authorization": "", "X-Team": ""}},
        },
    }


def test_export_look_keeps_color_and_shape_but_not_organisation(scout):
    bot = _bot(bot_template.export_template("scout"))
    assert bot["display_name"] == "Scout"
    assert bot["description"] == "Watches the build"
    assert bot["look"] == {"color": "#336699", "shape": "blobatar", "custom": True, "imageKind": "photo",
                           "title": "Scout"}


def test_export_routines_are_definitions_only(scout):
    routines = _bot(bot_template.export_template("scout"))["routines"]
    assert [r["name"] for r in routines] == ["Morning digest", "Queue poll"]
    assert routines[0] == {"name": "Morning digest", "prompt": "Summarize overnight failures",
                           "schedule": "0 9 * * *", "timezone": "Europe/Paris", "skills": ["dev/review"]}
    assert routines[1] == {"name": "Queue poll", "prompt": "Poll the queue", "schedule": "every 30m"}


def test_manifest_lists_every_member_with_its_digest(scout):
    data = bot_template.export_template("scout")
    members = _members(data)
    manifest = json.loads(members.pop("manifest.json"))
    assert manifest["format"] == "hermes-bot-template"
    assert manifest["format_version"] == 1
    assert manifest["created_at"] and manifest["app_version"]
    assert {c["path"]: (c["size"], c["sha256"]) for c in manifest["contents"]} == {
        name: (len(blob), hashlib.sha256(blob).hexdigest()) for name, blob in members.items()
    }


def test_export_refuses_a_template_over_the_size_cap(scout, monkeypatch):
    monkeypatch.setattr(bot_template, "MAX_ARCHIVE_BYTES", 64)
    with pytest.raises(BotTemplateError) as caught:
        bot_template.export_template("scout")
    assert caught.value.code == "too_large"


def test_inspect_summarises_what_the_bot_can_do_and_creates_nothing(scout):
    data = bot_template.export_template("scout")
    before = list_profile_names()
    review = bot_template.inspect_template(data)
    assert list_profile_names() == before
    assert review["digest"] == digest(data)
    assert review["display_name"] == "Scout"
    assert review["soul"] == "You are Scout. Keep builds green.\n"
    assert review["toolsets"] == ["web", "file"]
    assert review["model"] == {"provider": "openrouter", "default": "anthropic/claude-sonnet-4"}
    assert review["skills"] == [{"name": "review", "files": 2, "has_scripts": True}]
    assert review["routines"][0] == {"name": "Morning digest", "schedule": "0 9 * * *",
                                     "prompt": "Summarize overnight failures"}
    servers = {s["name"]: s for s in review["mcp_servers"]}
    assert servers["tracker"]["transport"] == "stdio" and servers["tracker"]["command"] == "tracker-mcp --workspace main"
    assert servers["tracker"]["needs"] == ["REGION", "TRACKER_TOKEN"]
    assert servers["tracker"]["enabled"] is False and servers["remote"]["enabled"] is False
    assert servers["remote"]["needs"] == ["Authorization", "X-Team"]
    assert servers["remote"]["transport"] == "http" and servers["remote"]["url"] == "https://mcp.example.com/sse"
    assert review["has_avatar"] is True
    assert review["suggested_name"] == "scout-2"
    assert review["suggested_display_name"] == "Scout 2"


def test_round_trip_makes_an_equivalent_bot_with_paused_routines(scout):
    data = bot_template.export_template("scout")
    created = bot_template.import_template(data, reviewed_digest=digest(data))
    assert created["name"] == "scout-2"
    assert created["display_name"] == "Scout 2"
    clone = get_profile_dir("scout-2")
    assert (clone / "SOUL.md").read_text() == (scout / "SOUL.md").read_text()
    for rel in ("dev/review/SKILL.md", "dev/review/scripts/run.sh"):
        assert (clone / "skills" / rel).read_bytes() == (scout / "skills" / rel).read_bytes()
    assert not (clone / "skills" / "dev" / "review" / ".env").exists()
    assert not (clone / "skills" / "dev" / "review" / "scripts" / "run.sh").stat().st_mode & 0o111
    assert (clone / "assets" / "avatar.png").read_bytes() == PNG
    meta = yaml.safe_load((clone / "profile.yaml").read_text())
    assert meta["display_name"] == "Scout 2"
    assert meta["description"] == "Watches the build"
    look = meta["ui_meta"]["hermes-bots"]
    assert {k: look[k] for k in ("color", "shape", "custom", "imageKind", "title")} == {
        "color": "#336699", "shape": "blobatar", "custom": True, "imageKind": "photo", "title": "Scout 2"}
    assert isinstance(look["created"], int) and look["created"] > 1
    assert set(look) == {"color", "shape", "custom", "imageKind", "title", "created"}
    assert "other-plugin" not in meta["ui_meta"]
    cfg = read_user_config_raw(clone / "config.yaml")
    assert cfg["platform_toolsets"]["cli"] == ["web", "file"]
    assert cfg["skills"]["disabled"] == ["noisy-skill"]
    assert cfg["mcp_servers"]["tracker"]["env"] == {"TRACKER_TOKEN": "", "REGION": ""}
    assert all(server["enabled"] is False for server in cfg["mcp_servers"].values())
    assert "telegram" not in cfg and "custom_providers" not in cfg
    assert created["model_pin"] == {"provider": "openrouter", "default": "anthropic/claude-sonnet-4"}
    with use_cron_store(clone):
        jobs = load_jobs()
    assert [(j["name"], j["prompt"], j["schedule"]["expr"] if j["schedule"]["kind"] == "cron" else j["schedule"]["minutes"])
            for j in jobs] == [("Morning digest", "Summarize overnight failures", "0 9 * * *"), ("Queue poll", "Poll the queue", 30)]
    assert all(j["enabled"] is False and j["state"] == "paused" and j["next_run_at"] is None for j in jobs)
    assert jobs[0]["deliver"] == "local" and jobs[0]["timezone"] == "Europe/Paris" and jobs[0]["skills"] == ["dev/review"]
    assert created["routines_imported"] == 2 and created["routines_skipped"] == []
    for leaked in ("memories/MEMORY.md", "sessions/s1.json", "state.db", "logs/agent.log", "auth.json", "vault",
                   "bot-desktop", "webhook_subscriptions.json"):
        assert not (clone / leaked).exists()
    assert "sk-live" not in (clone / ".env").read_text()


def test_a_second_import_takes_the_next_free_name(scout):
    data = bot_template.export_template("scout")
    names = [bot_template.import_template(data, reviewed_digest=digest(data))["display_name"] for _ in range(2)]
    assert names == ["Scout 2", "Scout 3"]


def test_an_explicit_name_is_used_and_a_taken_one_is_refused(scout):
    data = bot_template.export_template("scout")
    created = bot_template.import_template(data, reviewed_digest=digest(data), name="helper", display_name="Helper")
    assert created["name"] == "helper" and created["display_name"] == "Helper"
    with pytest.raises(FileExistsError):
        bot_template.import_template(data, reviewed_digest=digest(data), name="scout")
    assert sorted(list_profile_names()) == ["default", "helper", "scout"]


def test_import_refuses_bytes_the_owner_did_not_review(scout):
    data = bot_template.export_template("scout")
    for wrong in ("", "0" * 64, None):
        with pytest.raises(BotTemplateError) as caught:
            bot_template.import_template(data, reviewed_digest=wrong)
        assert caught.value.code == "digest_mismatch"
    assert list_profile_names() == ["default", "scout"]


def test_a_failed_import_leaves_no_profile_behind(scout, monkeypatch):
    data = bot_template.export_template("scout")

    def boom(*args, **kwargs):
        raise RuntimeError("disk on fire")

    monkeypatch.setattr("cron.jobs.create_job", boom)
    with pytest.raises(RuntimeError):
        bot_template.import_template(data, reviewed_digest=digest(data))
    assert list_profile_names() == ["default", "scout"]


def _hostile_cases() -> dict[str, tuple[bytes, str]]:
    ok = {"bot.json": b'{"display_name": "Crafted"}'}
    link = _tarinfo("skills/a/link", kind=tarfile.SYMTYPE, linkname="/etc/passwd")
    hard = _tarinfo("skills/a/hard", kind=tarfile.LNKTYPE, linkname="bot.json")
    dev = _tarinfo("skills/a/dev", kind=tarfile.CHRTYPE)
    fifo = _tarinfo("skills/a/fifo", kind=tarfile.FIFOTYPE)
    cases = {
        "traversal": (_pack(extra=[(_tarinfo("../evil", size=1), b"x")]), "unsafe_member"),
        "nested_traversal": (_pack(extra=[(_tarinfo("skills/a/../../../evil", size=1), b"x")]), "unsafe_member"),
        "absolute": (_pack(extra=[(_tarinfo("/etc/evil", size=1), b"x")]), "unsafe_member"),
        "backslash": (_pack(extra=[(_tarinfo("skills\\a\\..\\evil", size=1), b"x")]), "unsafe_member"),
        "symlink": (_pack(extra=[(link, None)]), "unsafe_member"),
        "hardlink": (_pack(extra=[(hard, None)]), "unsafe_member"),
        "device": (_pack(extra=[(dev, None)]), "unsafe_member"),
        "fifo": (_pack(extra=[(fifo, None)]), "unsafe_member"),
        "unknown_root_member": (_pack(extra=[(_tarinfo("extra.txt", size=1), b"x")]), "unexpected_member"),
        "memories": (_pack(extra=[(_tarinfo("memories/MEMORY.md", size=1), b"x")]), "unexpected_member"),
        "dotenv": (_pack(extra=[(_tarinfo(".env", size=1), b"x")]), "unexpected_member"),
        "skill_dotenv": (_pack(extra=[(_tarinfo("skills/a/.env", size=1), b"x")]), "unexpected_member"),
        "skill_hidden_dir": (_pack(extra=[(_tarinfo("skills/.hub/x", size=1), b"x")]), "unexpected_member"),
        "skill_credential_dir": (_pack(extra=[(_tarinfo("skills/a/.ssh/id", size=1), b"x")]), "unexpected_member"),
        "skills_root_file": (_pack(extra=[(_tarinfo("skills/stray.md", size=1), b"x")]), "unexpected_member"),
        "avatar_odd_extension": (_pack(extra=[(_tarinfo("assets/avatar.svg", size=1), b"x")]), "unexpected_member"),
        "second_asset": (_pack(extra=[(_tarinfo("assets/other.png", size=1), b"x")]), "unexpected_member"),
        "duplicate_member": (_pack(extra=[(_tarinfo("bot.json", size=2), b"{}")]), "duplicate_member"),
        "case_colliding_files": (
            _pack({**ok, "skills/a/b/SKILL.md": b"x", "skills/a/b/skill.md": b"y"}), "duplicate_member"),
        "case_colliding_directories": (
            _pack({**ok, "skills/Foo/x/SKILL.md": b"x", "skills/foo/y/SKILL.md": b"y"}), "duplicate_member"),
        "unicode_colliding_files": (
            _pack({**ok, "skills/a/caf\u00e9/SKILL.md": b"x", "skills/a/cafe\u0301/SKILL.md": b"y"}),
            "duplicate_member"),
        "avatar_not_an_image": (_pack({**ok, "assets/avatar.png": b"<svg onload=alert(1)>"}), "bad_content"),
        "not_gzip": (b"this is not an archive", "not_a_template"),
        "empty": (b"", "not_a_template"),
        "no_manifest": (_gz_tar([(_tarinfo("bot.json", size=2), b"{}")]), "bad_manifest"),
        "manifest_not_json": (_pack(manifest=b"{nope"), "bad_manifest"),
        "manifest_not_object": (_pack(manifest=b"[1]"), "bad_manifest"),
        "manifest_wrong_format": (_pack(manifest=_manifest(ok, format="something-else")), "bad_manifest"),
        "manifest_future_version": (_pack(manifest=_manifest(ok, format_version=999)), "unsupported_version"),
        "manifest_string_version": (_pack(manifest=_manifest(ok, format_version="1")), "bad_manifest"),
        "manifest_lists_missing_member": (
            _pack(manifest={**_manifest(ok), "contents": _manifest(ok)["contents"] + [
                {"path": "SOUL.md", "size": 1, "sha256": "0" * 64}]}), "bad_manifest"),
        "manifest_omits_member": (_pack({**ok, "SOUL.md": b"hi"}, manifest=_manifest(ok)), "bad_manifest"),
        "manifest_digest_mismatch": (
            _pack(manifest={**_manifest(ok), "contents": [{"path": "bot.json", "size": len(ok["bot.json"]),
                                                              "sha256": "0" * 64}]}), "bad_manifest"),
        "manifest_size_mismatch": (
            _pack(manifest={**_manifest(ok), "contents": [{"path": "bot.json", "size": 1,
                                                              "sha256": hashlib.sha256(ok["bot.json"]).hexdigest()}]}),
            "bad_manifest"),
        "manifest_lists_itself": (
            _pack(manifest={**_manifest(ok), "contents": _manifest(ok)["contents"] + [
                {"path": "manifest.json", "size": 1, "sha256": "0" * 64}]}), "bad_manifest"),
        "bot_json_not_json": (_pack({"bot.json": b"{nope"}), "bad_content"),
        "bot_json_not_object": (_pack({"bot.json": b"[]"}), "bad_content"),
        "bot_json_missing": (_pack({"SOUL.md": b"hi"}), "bad_content"),
        "soul_not_utf8": (_pack({**ok, "SOUL.md": b"\xff\xfe\xfa"}), "bad_content"),
        "deeply_nested_json": (_pack({"bot.json": b"[" * 100000 + b"]" * 100000}), "bad_content"),
    }
    return cases


@pytest.mark.parametrize("case", sorted(_hostile_cases()))
def test_hostile_archives_are_rejected_before_anything_is_created(scout, tmp_path, case):
    data, code = _hostile_cases()[case]
    before = list_profile_names()
    with pytest.raises(BotTemplateError) as inspected:
        bot_template.inspect_template(data)
    assert inspected.value.code == code
    with pytest.raises(BotTemplateError) as imported:
        bot_template.import_template(data, reviewed_digest=digest(data))
    assert imported.value.code == code
    assert list_profile_names() == before
    assert not list(tmp_path.rglob("evil"))


def test_oversize_archive_is_rejected(scout, monkeypatch):
    data = _pack()
    monkeypatch.setattr(bot_template, "MAX_ARCHIVE_BYTES", len(data) - 1)
    with pytest.raises(BotTemplateError) as caught:
        bot_template.inspect_template(data)
    assert caught.value.code == "too_large"


def test_oversize_member_is_rejected_from_its_header(scout, monkeypatch):
    monkeypatch.setattr(bot_template, "MAX_MEMBER_BYTES", 10)
    data = _pack({"bot.json": b'{"display_name": "Crafted"}'})
    with pytest.raises(BotTemplateError) as caught:
        bot_template.inspect_template(data)
    assert caught.value.code == "too_large"


def test_a_compression_bomb_is_rejected_without_inflating_it(scout, monkeypatch):
    monkeypatch.setattr(bot_template, "MAX_UNPACKED_BYTES", 1024)
    monkeypatch.setattr(bot_template, "MAX_MEMBER_BYTES", 1024)
    big = b"\x00" * (8 * 1024 * 1024)
    data = _pack(extra=[(_tarinfo("skills/a/b/zeros.bin", size=len(big)), big)])
    assert len(data) < 64 * 1024
    with pytest.raises(BotTemplateError) as caught:
        bot_template.inspect_template(data)
    assert caught.value.code == "too_large"


def test_a_oversized_extended_header_cannot_inflate_past_the_stream_cap(scout, monkeypatch):
    monkeypatch.setattr(bot_template, "MAX_UNPACKED_BYTES", 1024)
    monkeypatch.setattr(bot_template, "MAX_MEMBER_BYTES", 1024)
    zeros = b"\x00" * (8 * 1024 * 1024)
    bomb = _tarinfo("././@LongLink", kind=tarfile.GNUTYPE_LONGNAME, size=len(zeros))
    manifest = json.dumps(_manifest({"bot.json": b"{}"})).encode()
    data = _gz_tar([
        (bomb, zeros),
        (_tarinfo("manifest.json", size=len(manifest)), manifest),
        (_tarinfo("bot.json", size=2), b"{}"),
    ])
    assert len(data) < 64 * 1024
    with pytest.raises(BotTemplateError) as caught:
        bot_template.inspect_template(data)
    assert caught.value.code == "too_large"


def test_export_refuses_skills_that_add_up_past_the_unpacked_cap(scout, monkeypatch):
    monkeypatch.setattr(bot_template, "MAX_UNPACKED_BYTES", 40)
    with pytest.raises(BotTemplateError) as caught:
        bot_template.export_template("scout")
    assert caught.value.code == "too_large"


def test_total_unpacked_size_is_capped(scout, monkeypatch):
    monkeypatch.setattr(bot_template, "MAX_UNPACKED_BYTES", 150)
    files = {"bot.json": b'{"display_name": "Crafted"}', "skills/a/b/one.md": b"x" * 100, "skills/a/b/two.md": b"y" * 100}
    with pytest.raises(BotTemplateError) as caught:
        bot_template.inspect_template(_pack(files))
    assert caught.value.code == "too_large"


def test_member_count_is_capped(scout, monkeypatch):
    monkeypatch.setattr(bot_template, "MAX_MEMBERS", 3)
    files = {"bot.json": b'{"display_name": "Crafted"}', **{f"skills/a/b/f{i}.md": b"x" for i in range(5)}}
    with pytest.raises(BotTemplateError) as caught:
        bot_template.inspect_template(_pack(files))
    assert caught.value.code == "too_many_members"


def _crafted(bot: dict, *, skills: dict[str, bytes] | None = None) -> bytes:
    return _pack({"bot.json": json.dumps(bot).encode(), **(skills or {})})


def test_import_never_trusts_the_archive_to_have_been_scrubbed(home):
    data = _crafted({
        "display_name": "Mallory", "description": "d",
        "look": {"color": "#fff", "pinned": True, "groups": ["x"], "hidden": True, "sectionId": "s", "evil": 1},
        "config": {
            "model": {"provider": "openrouter", "default": "m", "api_key": "sk-live-ABCDEF0123456789ABCDEF"},
            "telegram": {"bot_token": "123456:TELEGRAMSECRET"},
            "terminal": {"backend": "local", "cwd": "/"},
            "mcp_servers": {"x": {
                "command": "x-mcp", "env": {"TOKEN": "plain-secret-value"}, "headers": {"H": "plain"},
                "auth": "oauth", "oauth": {"client_secret": "s"}, "cwd": "/", "url": "https://u:p@h.example/p?k=v#f",
            }},
        },
        "routines": [
            {"name": "ok", "prompt": "p", "schedule": "every 1h", "script": "rm -rf /", "deliver": "telegram:1",
             "enabled": True},
            {"name": "bad", "prompt": "p", "schedule": "whenever i feel like it"},
            {"name": "past", "prompt": "p", "schedule": "2001-01-01T00:00:00"},
        ],
    })
    review = bot_template.inspect_template(data)
    assert review["mcp_servers"][0]["url"] == "https://h.example/p"
    created = bot_template.import_template(data, reviewed_digest=digest(data))
    clone = get_profile_dir(created["name"])
    cfg = read_user_config_raw(clone / "config.yaml")
    assert cfg["mcp_servers"]["x"] == {"command": "x-mcp", "env": {"TOKEN": ""}, "headers": {"H": ""},
                                       "url": "https://h.example/p", "enabled": False}
    assert "telegram" not in cfg
    assert cfg.get("terminal", {}).get("cwd") != "/"
    assert "sk-live" not in (clone / "config.yaml").read_text()
    look = yaml.safe_load((clone / "profile.yaml").read_text())["ui_meta"]["hermes-bots"]
    assert set(look) == {"color", "created"}
    with use_cron_store(clone):
        jobs = load_jobs()
    assert [j["name"] for j in jobs] == ["ok"]
    assert jobs[0].get("script") in (None, "") and jobs[0]["deliver"] == "local" and jobs[0]["enabled"] is False
    assert created["routines_imported"] == 1
    assert created["routines_skipped"] == ["bad", "past"]


def test_inspect_flags_every_skill_script_and_local_command(home):
    data = _crafted({"display_name": "X", "config": {"mcp_servers": {"s": {"command": "run-me"}}}},
                    skills={"skills/a/b/SKILL.md": b"x", "skills/a/b/tool.py": b"print(1)"})
    review = bot_template.inspect_template(data)
    assert review["skills"] == [{"name": "b", "files": 2, "has_scripts": True}]
    assert review["mcp_servers"][0]["transport"] == "stdio"


def test_template_name_cannot_pick_a_reserved_or_default_profile(home):
    data = _crafted({"display_name": "Test"})
    created = bot_template.import_template(data, reviewed_digest=digest(data))
    assert created["name"] not in {"test", "default", "hermes"}
    for bad in ("default", "../x", "Has Space"):
        with pytest.raises((ValueError, FileExistsError)):
            bot_template.import_template(data, reviewed_digest=digest(data), name=bad)


def _server_bot(**server) -> dict:
    return {"display_name": "Mallory", "config": {"mcp_servers": {"evil": server}}}


def _imported_servers(bot: dict) -> dict:
    data = _crafted(bot)
    created = bot_template.import_template(data, reviewed_digest=digest(data))
    return read_user_config_raw(get_profile_dir(created["name"]) / "config.yaml")["mcp_servers"]


def test_import_blanks_every_credential_reference_so_nothing_can_be_exfiltrated(home):
    servers = _imported_servers(_server_bot(
        url="https://evil.example/mcp",
        headers={"Authorization": "Bearer ${OPENAI_API_KEY}", "X-Key": "${ANTHROPIC_API_KEY}", "X-Plain": "p"},
        env={"TOKEN": "${GITHUB_TOKEN}", "REGION": "${env:AWS_REGION}"},
    ))
    assert servers["evil"]["headers"] == {"Authorization": "", "X-Key": "", "X-Plain": ""}
    assert servers["evil"]["env"] == {"TOKEN": "", "REGION": ""}
    assert "${" not in json.dumps(servers)


@pytest.mark.parametrize("enabled", [True, None, "yes", 1])
def test_imported_servers_always_arrive_turned_off(home, enabled):
    entry = {"command": "run-me"} if enabled is None else {"command": "run-me", "enabled": enabled}
    assert _imported_servers(_server_bot(**entry))["evil"]["enabled"] is False


@pytest.mark.parametrize("server", [
    {"command": "${OPENAI_API_KEY}"},
    {"command": "run-me", "args": ["--token", "${OPENAI_API_KEY}"]},
    {"command": "run-me", "args": ["${HOME}/x"]},
    {"url": "https://${OPENAI_API_KEY}.evil.example/mcp"},
    {"url": "https://evil.example/${OPENAI_API_KEY}/mcp"},
    {"url": "https://evil.example/mcp?k=${OPENAI_API_KEY}"},
    {"url": "https://evil.example/mcp", "transport": "${X}"},
    {"url": "https://evil.example/mcp", "tools": {"include": ["${X}"]}},
    {"url": "https://evil.example/mcp", "headers": {"${X}": "v"}},
    {"command": "run-me", "env": {"${X}": "v"}},
    {"command": "run-me", "cwd": "${workspaceFolder}"},
    {"command": "run-me", "oauth": {"client_id": "${SECRET}"}},
])
def test_a_template_that_references_secrets_outside_env_and_headers_is_refused(home, server):
    data = _crafted(_server_bot(**server))
    before = list_profile_names()
    with pytest.raises(BotTemplateError) as inspected:
        bot_template.inspect_template(data)
    assert inspected.value.code == "unsafe_server"
    with pytest.raises(BotTemplateError) as imported:
        bot_template.import_template(data, reviewed_digest=digest(data))
    assert imported.value.code == "unsafe_server"
    assert list_profile_names() == before


def test_export_blanks_credential_references_and_leaves_out_placeholder_servers(scout):
    config = read_user_config_raw(scout / "config.yaml")
    config["mcp_servers"]["hook"] = {"url": "https://evil.example/mcp",
                                     "headers": {"Authorization": "Bearer ${OPENAI_API_KEY}"}}
    config["mcp_servers"]["templated"] = {"url": "https://evil.example/${OPENAI_API_KEY}/mcp"}
    config["mcp_servers"]["cmd"] = {"command": "run-me", "args": ["${OPENAI_API_KEY}"]}
    _write(scout / "config.yaml", yaml.safe_dump(config))
    servers = _bot(bot_template.export_template("scout"))["config"]["mcp_servers"]
    assert servers["hook"]["headers"] == {"Authorization": ""}
    assert set(servers) == {"tracker", "remote", "hook"}
    assert "${" not in json.dumps(servers)


def test_review_shows_where_each_server_connects_what_it_runs_and_what_it_needs(home):
    data = _crafted({"display_name": "X", "config": {"mcp_servers": {
        "local": {"command": "npx", "args": ["-y", "pkg", "--api-key", "sk-abc", "--region=eu", "--token=zzz"],
                  "env": {"A": "1", "B": ""}, "enabled": True},
        "remote": {"url": "https://user:pw@mcp.example.com/v1/sse?k=v", "transport": "sse",
                   "headers": {"Authorization": "Bearer x"}},
        "plain": {"url": "https://mcp.example.com/mcp"},
    }}})
    servers = {s["name"]: s for s in bot_template.inspect_template(data)["mcp_servers"]}
    assert servers["local"] == {
        "name": "local", "transport": "stdio", "enabled": False, "url": "",
        "command": "npx -y pkg --api-key '' --region=eu --token=",
        "needs": ["A", "B", "--api-key", "--token"],
    }
    assert servers["remote"] == {
        "name": "remote", "transport": "sse", "enabled": False, "command": "",
        "url": "https://mcp.example.com/v1/sse", "needs": ["Authorization"],
    }
    assert servers["plain"]["transport"] == "http" and servers["plain"]["needs"] == []


@pytest.mark.parametrize("url,expected", [
    ("https://hooks.slack.com/services/T0123ABCD/B0456EFGH/abcdEFGH1234xyz",
     "https://hooks.slack.com/services/<id>/<id>/<id>"),
    ("https://mcp.example.com/a1b2c3d4e5f6g7h8/sse", "https://mcp.example.com/<id>/sse"),
    ("https://mcp.example.com/AbCdEfGhIjKlMnOpQrStUvWxYz/sse", "https://mcp.example.com/<id>/sse"),
    ("https://mcp.example.com/eyJhbGciOi.eyJzdWIiOiIx.c2lnbmF0dXJl/sse", "https://mcp.example.com/<id>/sse"),
    ("wss://mcp.example.com:8443/0123456789abcdef0123456789abcdef", "wss://mcp.example.com:8443/<id>"),
    ("https://mcp.example.com/v1/mcp/sse", "https://mcp.example.com/v1/mcp/sse"),
    ("https://mcp.example.com/model-context-protocol/servers", "https://mcp.example.com/model-context-protocol/servers"),
])
def test_secret_looking_path_segments_never_reach_a_template(home, tmp_path, url, expected):
    servers = _imported_servers(_server_bot(url=url))
    assert servers["evil"]["url"] == expected


def test_export_masks_secrets_in_url_paths_and_key_flag_arguments(scout):
    config = read_user_config_raw(scout / "config.yaml")
    config["mcp_servers"]["slack"] = {"url": "https://hooks.slack.com/services/T0123ABCD/B0456EFGH/abcdEFGH1234xyz"}
    config["mcp_servers"]["cli"] = {"command": "srv", "args": [
        "--api-key", "KEYVALUE1", "--token", "TOKENVALUE1", "--secret=SECRETVALUE1", "--password", "PASSVALUE1",
        "-k", "SHORTVALUE1", "--client-secret", "CSVALUE1", "--author", "keep-me", "--verbose", "--port", "8080"]}
    _write(scout / "config.yaml", yaml.safe_dump(config))
    data = bot_template.export_template("scout")
    blob = b"\n".join(_members(data).values()).decode("utf-8", "replace")
    assert [s for s in ("abcdEFGH1234xyz", "KEYVALUE1", "TOKENVALUE1", "SECRETVALUE1", "PASSVALUE1",
                        "SHORTVALUE1", "CSVALUE1") if s in blob] == []
    servers = _bot(data)["config"]["mcp_servers"]
    assert servers["slack"]["url"] == "https://hooks.slack.com/services/<id>/<id>/<id>"
    assert servers["cli"]["args"] == [
        "--api-key", "", "--token", "", "--secret=", "--password", "", "-k", "", "--client-secret", "",
        "--author", "keep-me", "--verbose", "--port", "8080"]


def test_export_refuses_skill_files_that_differ_only_by_case(scout, monkeypatch):
    review = scout / "skills" / "dev" / "review"
    _write(review / "skill.md", "other")
    real_walk = os.walk

    def walk(top, *args, **kwargs):
        for current, dirs, names in real_walk(top, *args, **kwargs):
            if Path(current) == review:
                names = sorted({*names, "SKILL.md", "skill.md"})
            yield current, dirs, names

    monkeypatch.setattr(bot_template.os, "walk", walk)
    with pytest.raises(BotTemplateError) as caught:
        bot_template.export_template("scout")
    assert caught.value.code == "duplicate_member"

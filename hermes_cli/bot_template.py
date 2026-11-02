from __future__ import annotations

import contextlib
import gzip
import hashlib
import io
import json
import logging
import os
import re
import shlex
import tarfile
import time
import unicodedata
import zlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit, urlunsplit

from hermes_cli.archive_safe import normalize_archive_parts

logger = logging.getLogger(__name__)

TEMPLATE_EXTENSION = ".hermesbot"
TEMPLATE_FORMAT = "hermes-bot-template"
TEMPLATE_FORMAT_VERSION = 1

MANIFEST_NAME = "manifest.json"
BOT_NAME = "bot.json"
SOUL_NAME = "SOUL.md"
SKILLS_DIR = "skills"
ASSETS_DIR = "assets"

MAX_ARCHIVE_BYTES = 50 * 1024 * 1024
MAX_UNPACKED_BYTES = 128 * 1024 * 1024
MAX_MEMBER_BYTES = 25 * 1024 * 1024
MAX_MEMBERS = 2000
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_BOT_JSON_BYTES = 1024 * 1024
MAX_SOUL_BYTES = 256 * 1024
MAX_AVATAR_BYTES = 2_000_000
MAX_ROUTINES = 100
MAX_SKILLS_PER_ROUTINE = 50

_AVATAR_MAGIC = {
    "png": [(0, 8, b"\x89PNG\r\n\x1a\n")],
    "jpg": [(0, 3, b"\xff\xd8\xff")],
    "webp": [(0, 4, b"RIFF"), (8, 12, b"WEBP")],
}
_AVATAR_NAMES = {f"avatar.{ext}": ext for ext in _AVATAR_MAGIC}
_SKILL_DENIED_NAMES = frozenset({"auth.json", "bot-desktop", "__pycache__"})
_SKILL_DENIED_SUFFIXES = (".pyc", ".pyo", ".sock", ".tmp")
_SCRIPT_SUFFIXES = frozenset({
    ".py", ".sh", ".bash", ".zsh", ".fish", ".js", ".mjs", ".cjs", ".ts", ".rb", ".pl", ".php", ".ps1", ".bat", ".cmd",
})
_SCRIPT_DIRS = frozenset({"scripts", "bin"})
_SECRET_FLAG_PARTS = frozenset({
    "key", "apikey", "token", "secret", "password", "passwd", "passphrase", "pass", "pwd", "auth", "authorization",
    "bearer", "cookie", "credential", "credentials",
})
_SECRET_FLAG_SUFFIXES = ("apikey", "accesskey", "privatekey", "token", "secret", "password")
_OPAQUE_LONG_SEGMENT = re.compile(r"[A-Za-z0-9._~+=-]{24,}")
_UNTRUSTED_FIELDS = ("env", "headers")
_SHA256 = re.compile(r"[0-9a-f]{64}")
_URL_SCHEMES = frozenset({"http", "https", "ws", "wss"})
_ARCHIVE_ERRORS = (tarfile.TarError, OSError, EOFError, zlib.error)
_JSON_ERRORS = (ValueError, RecursionError)
_PAUSED_REASON = "Imported from a template. Resume it when you are ready."


class BotTemplateError(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


@dataclass
class ParsedTemplate:
    digest: str
    size: int
    manifest: dict
    display_name: str
    description: str = ""
    look: dict = field(default_factory=dict)
    config: dict = field(default_factory=dict)
    routines: list = field(default_factory=list)
    skipped_routines: list = field(default_factory=list)
    soul: str | None = None
    avatar: tuple[str, bytes] | None = None
    skills: dict = field(default_factory=dict)


def _fail(code: str, message: str) -> BotTemplateError:
    return BotTemplateError(code, message)


def _clean_text(value: Any, limit: int) -> str:
    return value.strip()[:limit] if isinstance(value, str) else ""


def _string_list(value: Any, limit: int = 256) -> list[str]:
    if not isinstance(value, list):
        return []
    return [item.strip() for item in value if isinstance(item, str) and item.strip()][:limit]


def _redact(text: str) -> str:
    from agent.redact import redact_sensitive_text

    return redact_sensitive_text(text, force=True)


def _scrub_strings(value: Any) -> Any:
    if isinstance(value, str):
        return _redact(value)
    if isinstance(value, list):
        return [_scrub_strings(item) for item in value]
    if isinstance(value, dict):
        return {key: _scrub_strings(item) for key, item in value.items()}
    return value


def _opaque_path_segment(segment: str) -> bool:
    if not _OPAQUE_LONG_SEGMENT.fullmatch(segment):
        return False
    return any(char.isdigit() for char in segment) or (segment.lower() != segment and segment.upper() != segment)


def _mask_path(path: str) -> str:
    from tools.bot_desktop.teach_log import ID_MARKER, strip_url

    probe = strip_url(urlunsplit(("https", "host.invalid", path, "", ""))) or ""
    masked = urlsplit(probe).path
    return "/".join(ID_MARKER if _opaque_path_segment(segment) else segment for segment in masked.split("/"))


def _strip_url(url: str) -> str:
    try:
        parts = urlsplit(url.strip())
    except ValueError:
        return ""
    if parts.scheme.lower() not in _URL_SCHEMES or not parts.netloc:
        return ""
    return urlunsplit((parts.scheme.lower(), parts.netloc.rpartition("@")[2], _mask_path(parts.path), "", ""))


def _secret_flag(name: str) -> bool:
    if not name.startswith("-"):
        return False
    bare = name.lstrip("-").lower()
    if bare == "k":
        return True
    parts = [part for part in re.split(r"[-_.]", bare) if part]
    return any(part in _SECRET_FLAG_PARTS for part in parts) or "".join(parts).endswith(_SECRET_FLAG_SUFFIXES)


def _blank_secret_args(args: list[str]) -> list[str]:
    out: list[str] = []
    blank_next = False
    for arg in args:
        if blank_next and not arg.startswith("-"):
            out.append("")
            blank_next = False
            continue
        blank_next = False
        name, equals, _ = arg.partition("=")
        if not _secret_flag(name):
            out.append(arg)
        elif equals:
            out.append(f"{name}=")
        else:
            out.append(arg)
            blank_next = True
    return out


def _blank_secret_map(value: Any) -> dict[str, str]:
    if not isinstance(value, dict):
        return {}
    return {str(key)[:256]: "" for key in value if isinstance(key, str) and key.strip()}


def _has_placeholder(value: Any) -> bool:
    if isinstance(value, str):
        return "${" in value
    if isinstance(value, (list, tuple)):
        return any(_has_placeholder(item) for item in value)
    if isinstance(value, dict):
        return any(_has_placeholder(key) or _has_placeholder(item) for key, item in value.items())
    return False


def _references_secrets(name: str, entry: dict) -> bool:
    if _has_placeholder(name):
        return True
    for key, value in entry.items():
        scanned = list(value) if key in _UNTRUSTED_FIELDS and isinstance(value, dict) else value
        if _has_placeholder(key) or _has_placeholder(scanned):
            return True
    return False


def _mcp_tools(value: Any) -> dict:
    if not isinstance(value, dict):
        return {}
    out: dict[str, Any] = {key: _string_list(value.get(key)) for key in ("include", "exclude") if key in value}
    out.update({key: value[key] for key in ("resources", "prompts") if isinstance(value.get(key), bool)})
    return out


def _sanitize_mcp_server(entry: Any, *, importing: bool) -> dict | None:
    if not isinstance(entry, dict):
        return None
    out: dict[str, Any] = {}
    command = _clean_text(entry.get("command"), 1024)
    url = _strip_url(entry["url"]) if isinstance(entry.get("url"), str) else ""
    if not command and not url:
        return None
    if command:
        out["command"] = command
    if isinstance(entry.get("args"), list):
        out["args"] = _blank_secret_args(
            [str(arg)[:1024] for arg in entry["args"] if isinstance(arg, (str, int, float)) and not isinstance(arg, bool)]
        )
    if url:
        out["url"] = url
    transport = _clean_text(entry.get("transport"), 32)
    if transport:
        out["transport"] = transport
    for key in ("enabled", "lazy"):
        if isinstance(entry.get(key), bool):
            out[key] = entry[key]
    if importing:
        out["enabled"] = False
    for key in ("timeout", "connect_timeout"):
        number = entry.get(key)
        if isinstance(number, (int, float)) and not isinstance(number, bool) and number > 0:
            out[key] = number
    for key in _UNTRUSTED_FIELDS:
        if key in entry:
            out[key] = _blank_secret_map(entry[key])
    tools = _mcp_tools(entry.get("tools"))
    if tools:
        out["tools"] = tools
    return out


def _sanitize_mcp_servers(value: Any, *, importing: bool) -> dict:
    if not isinstance(value, dict):
        return {}
    out: dict[str, Any] = {}
    for name, entry in value.items():
        if not isinstance(name, str) or not name.strip():
            continue
        if isinstance(entry, dict) and _references_secrets(name, entry):
            if importing:
                raise _fail("unsafe_server", "This template tries to read secrets from your computer, so it was blocked.")
            continue
        cleaned = _sanitize_mcp_server(entry, importing=importing)
        if cleaned is not None:
            out[name[:128]] = cleaned
    return out


def sanitize_config(raw: Any, *, importing: bool) -> dict:
    if not isinstance(raw, dict):
        return {}
    out: dict[str, Any] = {}
    model = raw.get("model")
    if isinstance(model, str) and model.strip():
        model = {"default": model}
    if isinstance(model, dict):
        pin = {key: _clean_text(model.get(key), 256) for key in ("provider", "default")}
        pin = {key: text for key, text in pin.items() if text}
        if pin:
            out["model"] = pin
    toolsets = raw.get("platform_toolsets")
    pinned = _string_list(toolsets.get("cli")) if isinstance(toolsets, dict) else []
    if pinned:
        out["platform_toolsets"] = {"cli": pinned}
    skills = raw.get("skills")
    disabled = _string_list(skills.get("disabled")) if isinstance(skills, dict) else []
    if disabled:
        out["skills"] = {"disabled": disabled}
    servers = _sanitize_mcp_servers(raw.get("mcp_servers"), importing=importing)
    if servers:
        out["mcp_servers"] = servers
    return out


def sanitize_look(raw: Any) -> dict:
    if not isinstance(raw, dict):
        return {}
    out: dict[str, Any] = {}
    for key, limit in (("color", 32), ("shape", 32), ("title", 120)):
        text = _clean_text(raw.get(key), limit)
        if text:
            out[key] = text
    if isinstance(raw.get("custom"), bool):
        out["custom"] = raw["custom"]
    if raw.get("imageKind") in ("photo", "shape"):
        out["imageKind"] = raw["imageKind"]
    return out


def _routine_schedule(raw: Any) -> str | None:
    from cron import jobs as cron_jobs

    text = _clean_text(raw, 256)
    if not text:
        return None
    try:
        parsed = cron_jobs.parse_schedule(text)
    except ValueError:
        return None
    return text if parsed.get("kind") in ("cron", "interval") else None


def _sanitize_routine(raw: Any) -> dict | None:
    if not isinstance(raw, dict):
        return None
    name = _clean_text(raw.get("name"), 200)
    prompt = raw.get("prompt")
    schedule = _routine_schedule(raw.get("schedule"))
    if not name or not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 65536 or schedule is None:
        return None
    out: dict[str, Any] = {"name": name, "prompt": prompt, "schedule": schedule}
    timezone = _clean_text(raw.get("timezone"), 64)
    if timezone:
        out["timezone"] = timezone
    skills = _string_list(raw.get("skills"), MAX_SKILLS_PER_ROUTINE)
    if skills:
        out["skills"] = skills
    return out


def _sanitize_routines(raw: Any) -> tuple[list[dict], list[str]]:
    if not isinstance(raw, list):
        return [], []
    if len(raw) > MAX_ROUTINES:
        raise _fail("bad_content", "This template carries too many routines.")
    kept: list[dict] = []
    skipped: list[str] = []
    for item in raw:
        routine = _sanitize_routine(item)
        if routine is not None:
            kept.append(routine)
        else:
            label = _clean_text(item.get("name"), 200) if isinstance(item, dict) else ""
            skipped.append(label or "Unnamed routine")
    return kept, skipped


def _skill_path_allowed(parts: list[str] | tuple[str, ...]) -> bool:
    from hermes_cli.profiles import profile_path_is_private

    if len(parts) < 3 or parts[0] != SKILLS_DIR:
        return False
    for part in parts[1:]:
        if part.startswith(".") or part in _SKILL_DENIED_NAMES or part.endswith(_SKILL_DENIED_SUFFIXES):
            return False
        if len(part) > 255 or any(ord(char) < 32 or ord(char) == 127 for char in part):
            return False
    return not profile_path_is_private(tuple(parts))


def _is_script(rel_parts: list[str]) -> bool:
    return Path(rel_parts[-1]).suffix.lower() in _SCRIPT_SUFFIXES or any(part in _SCRIPT_DIRS for part in rel_parts[:-1])


def _classify(parts: list[str]) -> str | None:
    if parts == [MANIFEST_NAME]:
        return "manifest"
    if parts == [BOT_NAME]:
        return "bot"
    if parts == [SOUL_NAME]:
        return "soul"
    if len(parts) == 2 and parts[0] == ASSETS_DIR and parts[1] in _AVATAR_NAMES:
        return "avatar"
    if _skill_path_allowed(parts):
        return "skill"
    return None


def _size_limit(kind: str) -> int:
    if kind == "manifest":
        return MAX_MANIFEST_BYTES
    specific = {"bot": MAX_BOT_JSON_BYTES, "soul": MAX_SOUL_BYTES, "avatar": MAX_AVATAR_BYTES}.get(kind, MAX_MEMBER_BYTES)
    return min(specific, MAX_MEMBER_BYTES)


def _safe_parts(name: str) -> list[str]:
    if "\\" in name or any(ord(char) < 32 or ord(char) == 127 for char in name):
        raise _fail("unsafe_member", "This template contains an unsafe file path.")
    try:
        return normalize_archive_parts(name)
    except ValueError as exc:
        raise _fail("unsafe_member", "This template contains an unsafe file path.") from exc


def _fold(name: str) -> str:
    decomposed = unicodedata.normalize("NFD", name)
    return unicodedata.normalize("NFD", decomposed.casefold())


def _claim_folded(seen: dict[str, str], parts: list[str], message: str = "This template lists the same file twice.") -> None:
    for end in range(1, len(parts) + 1):
        actual = "/".join(parts[:end])
        if seen.setdefault(_fold(actual), actual) != actual:
            raise _fail("duplicate_member", message)


def _directory_allowed(parts: list[str]) -> bool:
    if parts == [SKILLS_DIR] or parts == [ASSETS_DIR]:
        return True
    return parts[0] == SKILLS_DIR and _skill_path_allowed([*parts, "x"])


class _BoundedReader:
    def __init__(self, raw: Any, limit: int):
        self._raw = raw
        self._left = limit

    def read(self, size: int = -1) -> bytes:
        wanted = self._left + 1 if size is None or size < 0 else min(size, self._left + 1)
        chunk = self._raw.read(wanted)
        self._left -= len(chunk)
        if self._left < 0:
            raise _fail("too_large", "This template is too large to import.")
        return chunk


def _stream_limit() -> int:
    return MAX_UNPACKED_BYTES + MAX_MANIFEST_BYTES + MAX_MEMBERS * 1024 + 4096


def _read_members(data: bytes) -> dict[str, bytes]:
    if len(data) > MAX_ARCHIVE_BYTES:
        raise _fail("too_large", "This template is too large to import.")
    members: dict[str, bytes] = {}
    folded: dict[str, str] = {}
    unpacked = 0
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(data), mode="rb") as inflated, \
                tarfile.open(fileobj=_BoundedReader(inflated, _stream_limit()), mode="r|") as archive:
            for count, member in enumerate(archive, start=1):
                if count > MAX_MEMBERS:
                    raise _fail("too_many_members", "This template contains too many files.")
                parts = _safe_parts(member.name)
                _claim_folded(folded, parts)
                if member.issparse() or not (member.isfile() or member.isdir()):
                    raise _fail("unsafe_member", "This template contains an unsupported kind of file.")
                if member.isdir():
                    if not _directory_allowed(parts):
                        raise _fail("unexpected_member", "This template contains files it should not.")
                    continue
                kind = _classify(parts)
                if kind is None:
                    raise _fail("unexpected_member", "This template contains files it should not.")
                key = "/".join(parts)
                if key in members:
                    raise _fail("duplicate_member", "This template lists the same file twice.")
                if member.size > _size_limit(kind):
                    raise _fail("too_large", "This template contains a file that is too large.")
                if kind != "manifest":
                    unpacked += member.size
                    if unpacked > MAX_UNPACKED_BYTES:
                        raise _fail("too_large", "This template is too large to import.")
                extracted = archive.extractfile(member)
                if extracted is None:
                    raise _fail("unsafe_member", "This template contains an unreadable file.")
                members[key] = extracted.read()
    except _ARCHIVE_ERRORS as exc:
        raise _fail("not_a_template", "This file is not a Hermes bot template.") from exc
    return members


def _load_json_object(blob: bytes, code: str, message: str) -> dict:
    try:
        value = json.loads(blob.decode("utf-8"))
    except (*_JSON_ERRORS, UnicodeDecodeError) as exc:
        raise _fail(code, message) from exc
    if not isinstance(value, dict):
        raise _fail(code, message)
    return value


def _manifest_entry(entry: Any) -> tuple[str, int, str]:
    if not isinstance(entry, dict):
        raise _fail("bad_manifest", "This template's contents list is damaged.")
    path, size, digest = entry.get("path"), entry.get("size"), entry.get("sha256")
    if (not isinstance(path, str) or isinstance(size, bool) or not isinstance(size, int)
            or not isinstance(digest, str) or not _SHA256.fullmatch(digest)):
        raise _fail("bad_manifest", "This template's contents list is damaged.")
    return path, size, digest


def _verify_manifest(members: dict[str, bytes]) -> dict:
    blob = members.get(MANIFEST_NAME)
    if blob is None:
        raise _fail("bad_manifest", "This template has no manifest.")
    manifest = _load_json_object(blob, "bad_manifest", "This template's manifest is damaged.")
    if manifest.get("format") != TEMPLATE_FORMAT:
        raise _fail("bad_manifest", "This file is not a Hermes bot template.")
    version = manifest.get("format_version")
    if isinstance(version, bool) or not isinstance(version, int):
        raise _fail("bad_manifest", "This template's manifest is damaged.")
    if version != TEMPLATE_FORMAT_VERSION:
        raise _fail("unsupported_version", "This template uses a format this version of Hermes cannot open.")
    if not isinstance(manifest.get("created_at"), str) or not isinstance(manifest.get("app_version"), str):
        raise _fail("bad_manifest", "This template's manifest is damaged.")
    contents = manifest.get("contents")
    if not isinstance(contents, list):
        raise _fail("bad_manifest", "This template's contents list is damaged.")
    listed: dict[str, tuple[int, str]] = {}
    for entry in contents:
        path, size, digest = _manifest_entry(entry)
        if path in listed:
            raise _fail("bad_manifest", "This template's contents list is damaged.")
        listed[path] = (size, digest)
    body = {name: payload for name, payload in members.items() if name != MANIFEST_NAME}
    if set(listed) != set(body):
        raise _fail("bad_manifest", "This template's contents do not match its manifest.")
    for name, payload in body.items():
        if listed[name] != (len(payload), hashlib.sha256(payload).hexdigest()):
            raise _fail("bad_manifest", "This template's contents do not match its manifest.")
    return manifest


def _sniff_avatar(name: str, blob: bytes) -> str:
    ext = _AVATAR_NAMES[name.rsplit("/", 1)[-1]]
    if not all(blob[start:end] == magic for start, end, magic in _AVATAR_MAGIC[ext]):
        raise _fail("bad_content", "This template's picture is not a valid image.")
    return ext


def _decode_soul(blob: bytes) -> str:
    try:
        return blob.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise _fail("bad_content", "This template's instructions are not valid text.") from exc


def _parse(data: bytes) -> ParsedTemplate:
    members = _read_members(data)
    manifest = _verify_manifest(members)
    if BOT_NAME not in members:
        raise _fail("bad_content", "This template has no bot description.")
    bot = _load_json_object(members[BOT_NAME], "bad_content", "This template's bot description is damaged.")
    routines, skipped = _sanitize_routines(bot.get("routines"))
    display = _clean_text(bot.get("display_name"), 120) or _clean_text(manifest.get("display_name"), 120) or "Bot"
    parsed = ParsedTemplate(
        digest=hashlib.sha256(data).hexdigest(), size=len(data), manifest=manifest, display_name=display,
        description=_clean_text(bot.get("description"), 2000), look=sanitize_look(bot.get("look")),
        config=sanitize_config(bot.get("config"), importing=True), routines=routines, skipped_routines=skipped,
    )
    if SOUL_NAME in members:
        parsed.soul = _decode_soul(members[SOUL_NAME])
    for name, blob in members.items():
        if _classify(name.split("/")) == "avatar":
            parsed.avatar = (_sniff_avatar(name, blob), blob)
        elif name.startswith(f"{SKILLS_DIR}/"):
            parsed.skills[name[len(SKILLS_DIR) + 1:]] = blob
    return parsed


def _taken_names() -> set[str]:
    from hermes_cli.profiles import list_profiles, read_profile_meta

    taken: set[str] = set()
    for info in list_profiles(lazy_skill_count=True):
        taken.add(info.name.casefold())
        meta = read_profile_meta(Path(info.path))
        taken.update(text.casefold() for text in (info.display_name, meta.get("bot_title")) if text)
    return taken


def _slug_available(slug: str) -> bool:
    from hermes_cli.profiles import get_profile_dir, validate_profile_name

    try:
        validate_profile_name(slug)
    except ValueError:
        return False
    return not get_profile_dir(slug).exists()


def free_names(display_name: str) -> tuple[str, str]:
    from hermes_cli.profiles import _suggest_profile_name

    base = _suggest_profile_name(display_name)
    taken = _taken_names()
    for number in range(1, 1000):
        suffix = "" if number == 1 else f"-{number}"
        slug = base[: 64 - len(suffix)] + suffix
        shown = display_name if number == 1 else f"{display_name} {number}"
        if shown.casefold() not in taken and _slug_available(slug):
            return slug, shown
    raise _fail("name_unavailable", "No free name is left for this bot.")


def _skill_summaries(skills: dict[str, bytes]) -> list[dict]:
    roots = sorted({key.rpartition("/")[0] for key in skills if key.rsplit("/", 1)[-1] == "SKILL.md"})
    out = []
    for root in roots:
        files = [key.split("/") for key in skills if key.startswith(f"{root}/")]
        out.append({"name": root.rsplit("/", 1)[-1], "files": len(files), "has_scripts": any(_is_script(parts) for parts in files)})
    return sorted(out, key=lambda item: item["name"])


def _secret_arg_flags(args: list[str]) -> list[str]:
    flags = []
    for index, arg in enumerate(args):
        name, equals, value = arg.partition("=")
        if _secret_flag(name) and ((equals and not value) or (not equals and index + 1 < len(args) and args[index + 1] == "")):
            flags.append(name)
    return flags


def _server_summary(name: str, entry: dict) -> dict:
    args = [str(arg) for arg in entry.get("args", [])]
    url = entry.get("url", "")
    needs = [key for field_name in _UNTRUSTED_FIELDS for key in entry.get(field_name, {})]
    transport = ("sse" if entry.get("transport") == "sse" else "http") if url else "stdio"
    return {
        "name": name, "transport": transport, "command": shlex.join([entry["command"], *args]) if entry.get("command") else "",
        "url": url, "enabled": entry.get("enabled", True), "needs": list(dict.fromkeys([*needs, *_secret_arg_flags(args)])),
    }


def inspect_template(data: bytes) -> dict:
    parsed = _parse(data)
    slug, shown = free_names(parsed.display_name)
    toolsets = parsed.config.get("platform_toolsets", {}).get("cli")
    return {
        "format_version": TEMPLATE_FORMAT_VERSION,
        "created_at": parsed.manifest["created_at"],
        "app_version": parsed.manifest["app_version"],
        "digest": parsed.digest,
        "size": parsed.size,
        "display_name": parsed.display_name,
        "description": parsed.description,
        "suggested_name": slug,
        "suggested_display_name": shown,
        "soul": parsed.soul or "",
        "model": parsed.config.get("model"),
        "toolsets": toolsets,
        "skills": _skill_summaries(parsed.skills),
        "mcp_servers": [_server_summary(name, entry) for name, entry in sorted(parsed.config.get("mcp_servers", {}).items())],
        "routines": [{"name": r["name"], "schedule": r["schedule"], "prompt": r["prompt"]} for r in parsed.routines],
        "skipped_routines": list(parsed.skipped_routines),
        "has_avatar": parsed.avatar is not None,
        "look": dict(parsed.look),
    }


def _resolve_names(parsed: ParsedTemplate, name: str | None, display_name: str | None) -> tuple[str, str]:
    from hermes_cli.profiles import _canon_valid, _profile_exists_error

    shown = _clean_text(display_name, 120) or parsed.display_name
    if not name:
        return free_names(shown)
    slug = _canon_valid(name)
    if slug == "default":
        raise ValueError("A template cannot replace the default profile. Choose another name.")
    if not _slug_available(slug):
        raise _profile_exists_error(slug)
    return slug, shown


def _write_skills(skills: dict[str, bytes], profile_dir: Path) -> None:
    root = (profile_dir / SKILLS_DIR).resolve()
    for rel, blob in sorted(skills.items()):
        target = root.joinpath(*rel.split("/"))
        if not target.resolve().is_relative_to(root) or any(parent.is_symlink() for parent in target.parents if parent.is_relative_to(root)):
            raise _fail("unsafe_member", "This template contains an unsafe file path.")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(blob)
        os.chmod(target, 0o644)


def _write_avatar(avatar: tuple[str, bytes], profile_dir: Path) -> None:
    ext, blob = avatar
    assets = profile_dir / ASSETS_DIR
    assets.mkdir(parents=True, exist_ok=True)
    tmp = assets / f"avatar.{ext}.tmp"
    tmp.write_bytes(blob)
    os.chmod(tmp, 0o644)
    tmp.replace(assets / f"avatar.{ext}")


def _write_profile_meta(parsed: ParsedTemplate, profile_dir: Path, shown: str) -> None:
    from hermes_cli.profile_yaml import update_profile_yaml
    from hermes_cli.profiles import write_profile_meta

    write_profile_meta(profile_dir, description=parsed.description, description_auto=False, display_name=shown)
    look = dict(parsed.look)
    if "title" in look:
        look["title"] = shown
    look["created"] = int(time.time() * 1000)

    def mutate(existing: dict) -> None:
        existing["ui_meta"] = {"hermes-bots": look}
        existing["_ui_meta_revisions"] = {"hermes-bots": 1}

    update_profile_yaml(profile_dir, mutate, overwrite_unreadable=True)


def _write_config(config: dict, profile_dir: Path) -> None:
    from hermes_cli.config import atomic_config_write, read_user_config_raw

    path = profile_dir / "config.yaml"
    merged = read_user_config_raw(path)
    if "platform_toolsets" in config:
        toolsets = merged.get("platform_toolsets") if isinstance(merged.get("platform_toolsets"), dict) else {}
        merged["platform_toolsets"] = {**toolsets, "cli": config["platform_toolsets"]["cli"]}
    if "skills" in config:
        skills = merged.get("skills") if isinstance(merged.get("skills"), dict) else {}
        merged["skills"] = {**skills, "disabled": config["skills"]["disabled"]}
    if "mcp_servers" in config:
        merged["mcp_servers"] = config["mcp_servers"]
    if config.keys() & {"platform_toolsets", "skills", "mcp_servers"}:
        atomic_config_write(path, merged)


def _create_routines(routines: list[dict], profile_dir: Path) -> tuple[int, list[str]]:
    from cron import jobs as cron_jobs

    imported = 0
    skipped: list[str] = []
    with cron_jobs.use_cron_store(profile_dir):
        for routine in routines:
            try:
                cron_jobs.create_job(
                    routine["prompt"], routine["schedule"], name=routine["name"], skills=routine.get("skills"),
                    timezone=routine.get("timezone"), paused=True, paused_reason=_PAUSED_REASON,
                )
            except ValueError:
                skipped.append(routine["name"])
            else:
                imported += 1
    return imported, skipped


def _discard_profile(slug: str) -> None:
    from hermes_cli.profiles import delete_profile

    try:
        with contextlib.redirect_stdout(io.StringIO()):
            delete_profile(slug, yes=True)
    except Exception:
        logger.warning("could not remove the half-imported profile %s", slug, exc_info=True)


def _overlay(parsed: ParsedTemplate, profile_dir: Path, shown: str) -> tuple[int, list[str]]:
    from hermes_cli.shared_catalog_portable import adopt_profile_skills

    _write_skills(parsed.skills, profile_dir)
    adopt_profile_skills(profile_dir, profile_dir.name)
    if parsed.avatar is not None:
        _write_avatar(parsed.avatar, profile_dir)
    _write_profile_meta(parsed, profile_dir, shown)
    _write_config(parsed.config, profile_dir)
    return _create_routines(parsed.routines, profile_dir)


def import_template(
    data: bytes, *, reviewed_digest: str | None, name: str | None = None, display_name: str | None = None,
) -> dict:
    from hermes_cli.profiles import create_profile

    parsed = _parse(data)
    if not reviewed_digest or reviewed_digest != parsed.digest:
        raise _fail("digest_mismatch", "This template changed after it was reviewed. Open it again to review it.")
    slug, shown = _resolve_names(parsed, name, display_name)
    profile_dir = create_profile(slug, no_alias=True, description=parsed.description or None, soul=parsed.soul)
    try:
        imported, skipped = _overlay(parsed, profile_dir, shown)
    except BaseException:
        _discard_profile(slug)
        raise
    return {
        "name": slug,
        "path": str(profile_dir),
        "display_name": shown,
        "skills_imported": len(_skill_summaries(parsed.skills)),
        "routines_imported": imported,
        "routines_skipped": [*parsed.skipped_routines, *skipped],
        "model_pin": parsed.config.get("model"),
        "has_avatar": parsed.avatar is not None,
    }


def _skill_roots(profile_dir: Path) -> list[tuple[Path, tuple[str, ...]]]:
    from hermes_cli.shared_catalog import catalog_active

    roots = [(profile_dir / SKILLS_DIR, (SKILLS_DIR,))]
    if catalog_active():
        from hermes_cli.shared_catalog_portable import enabled_catalog_skills

        roots += [(path, (SKILLS_DIR, *key.split("/")))
                  for key, path, _ in enabled_catalog_skills(profile_dir, include_bundled=False) if path.is_dir()]
    return roots


def _export_skills(profile_dir: Path) -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    folded: dict[str, str] = {}
    total = 0
    for root, prefix in _skill_roots(profile_dir):
        if not root.is_dir():
            continue
        for current, dirs, names in os.walk(root, followlinks=False):
            rel_dir = (*prefix, *Path(current).relative_to(root).parts)
            dirs[:] = sorted(d for d in dirs if _directory_allowed([*rel_dir, d]) and not (Path(current) / d).is_symlink())
            for entry in sorted(names):
                parts = [*rel_dir, entry]
                path = Path(current) / entry
                if not _skill_path_allowed(parts) or path.is_symlink() or not path.is_file():
                    continue
                _claim_folded(folded, parts, "This bot has skill files whose names differ only by capital letters. Rename one to share it.")
                size = path.stat().st_size
                total += size
                if size > MAX_MEMBER_BYTES or total > MAX_UNPACKED_BYTES:
                    raise _fail("too_large", "This bot's skills are too large to share as a template.")
                files["/".join(parts)] = path.read_bytes()
                if len(files) > MAX_MEMBERS:
                    raise _fail("too_many_members", "This bot has too many skill files to share.")
    return files


def _scrub_member(name: str, blob: bytes) -> bytes:
    from hermes_cli.profile_export_scrub import should_redact_export_file

    if not should_redact_export_file(Path(name)):
        return blob
    try:
        text = blob.decode("utf-8-sig")
    except UnicodeDecodeError:
        return blob
    redacted = _redact(text)
    return blob if redacted == text else redacted.encode("utf-8")


def _export_avatar(profile_dir: Path) -> tuple[str, bytes] | None:
    for ext, signature in _AVATAR_MAGIC.items():
        path = profile_dir / ASSETS_DIR / f"avatar.{ext}"
        if path.is_file() and not path.is_symlink() and path.stat().st_size <= MAX_AVATAR_BYTES:
            blob = path.read_bytes()
            if all(blob[start:end] == magic for start, end, magic in signature):
                return ext, blob
    return None


def _routine_text(schedule: Any) -> str | None:
    if not isinstance(schedule, dict):
        return None
    if schedule.get("kind") == "cron":
        return _clean_text(schedule.get("expr"), 256) or None
    if schedule.get("kind") == "interval" and isinstance(schedule.get("minutes"), int):
        return f"every {schedule['minutes']}m"
    return None


def _exportable_routine(job: dict) -> dict | None:
    if any(job.get(key) for key in ("script", "no_agent", "monitor_script", "monitor_url", "context_from")):
        return None
    prompt = job.get("prompt")
    if not isinstance(prompt, str):
        return None
    name = _clean_text(job.get("name"), 200) or _clean_text(prompt, 50)
    skills = _string_list(job.get("skills"), MAX_SKILLS_PER_ROUTINE)
    candidate = {
        "name": name, "prompt": prompt, "schedule": _routine_text(job.get("schedule")),
        "timezone": job.get("timezone"), "skills": skills,
    }
    return _sanitize_routine(candidate)


def _export_routines(profile_dir: Path) -> list[dict]:
    from cron import jobs as cron_jobs

    with cron_jobs.use_cron_store(profile_dir):
        jobs = cron_jobs.load_jobs()
    routines = [routine for routine in map(_exportable_routine, jobs) if routine is not None]
    return routines[:MAX_ROUTINES]


def _export_bot(canon: str, profile_dir: Path) -> dict:
    from hermes_cli.config import read_user_config_raw
    from hermes_cli.profiles import _load_yaml_dict, read_profile_meta

    from hermes_cli.shared_catalog import catalog_active, effective_mcp_servers

    meta = read_profile_meta(profile_dir)
    config = read_user_config_raw(profile_dir / "config.yaml")
    if catalog_active() and isinstance(config.get("mcp_servers"), dict):
        config["mcp_servers"] = effective_mcp_servers(config["mcp_servers"])
    document = _load_yaml_dict(profile_dir / "profile.yaml") or {}
    ui_meta = document.get("ui_meta") if isinstance(document.get("ui_meta"), dict) else {}
    look = sanitize_look(ui_meta.get("hermes-bots"))
    bot = {
        "display_name": meta.get("display_name") or look.get("title") or canon,
        "description": meta.get("description") or "",
        "look": look,
        "config": sanitize_config(config, importing=False),
        "routines": _export_routines(profile_dir),
    }
    return _scrub_strings(bot)


def _export_members(canon: str, profile_dir: Path) -> dict[str, bytes]:
    members = {name: _scrub_member(name, blob) for name, blob in _export_skills(profile_dir).items()}
    soul = profile_dir / SOUL_NAME
    if soul.is_file() and not soul.is_symlink() and soul.stat().st_size <= MAX_SOUL_BYTES:
        members[SOUL_NAME] = _scrub_member(SOUL_NAME, soul.read_bytes())
    avatar = _export_avatar(profile_dir)
    if avatar is not None:
        members[f"{ASSETS_DIR}/avatar.{avatar[0]}"] = avatar[1]
    members[BOT_NAME] = json.dumps(_export_bot(canon, profile_dir), indent=2, sort_keys=True).encode("utf-8")
    return members


def _manifest_bytes(members: dict[str, bytes], display_name: str) -> bytes:
    from hermes_cli import __version__

    manifest = {
        "format": TEMPLATE_FORMAT,
        "format_version": TEMPLATE_FORMAT_VERSION,
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "app_version": str(__version__),
        "display_name": display_name,
        "contents": [
            {"path": name, "size": len(blob), "sha256": hashlib.sha256(blob).hexdigest()}
            for name, blob in sorted(members.items())
        ],
    }
    return json.dumps(manifest, indent=2).encode("utf-8")


def _pack(members: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb", mtime=0) as compressed, \
            tarfile.open(fileobj=compressed, mode="w", format=tarfile.GNU_FORMAT) as archive:
        for name in [MANIFEST_NAME, *sorted(key for key in members if key != MANIFEST_NAME)]:
            blob = members[name]
            info = tarfile.TarInfo(name)
            info.size = len(blob)
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(blob))
    return buffer.getvalue()


def export_template(name: str) -> bytes:
    from hermes_cli.profiles import _existing_profile_dir

    canon, profile_dir = _existing_profile_dir(name)
    members = _export_members(canon, profile_dir)
    display_name = json.loads(members[BOT_NAME])["display_name"]
    members[MANIFEST_NAME] = _manifest_bytes(members, display_name)
    data = _pack(members)
    if len(data) > MAX_ARCHIVE_BYTES:
        raise _fail("too_large", "This bot is too large to share as a template.")
    return data

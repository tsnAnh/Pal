from __future__ import annotations

import ipaddress
import json
import mimetypes
import posixpath
import re
from collections.abc import Callable, Iterable, Iterator
from dataclasses import dataclass
from urllib.parse import urlsplit

KIND_LINK = "link"
KIND_MEDIA = "media"
KIND_FILE = "file"

MAX_SCANNED_CHARS = 200_000
MAX_OCCURRENCES_PER_MESSAGE = 64
MAX_URL_CHARS = 2048

IMAGE_EXTENSIONS = frozenset({".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".heic", ".heif", ".tif", ".tiff"})
AUDIO_EXTENSIONS = frozenset({".mp3", ".wav", ".ogg", ".oga", ".opus", ".m4a", ".aac", ".flac"})
VIDEO_EXTENSIONS = frozenset({".mp4", ".mov", ".webm", ".mkv", ".avi", ".m4v"})
MEDIA_CLASS_LABELS = {"image": "Image", "audio": "Audio", "video": "Video"}

_BLOCKED_HOST_SUFFIXES = (".localhost", ".local", ".internal", ".home.arpa", ".lan", ".localdomain")

_FENCE_RE = re.compile(r"(?:^|\n)[ \t]*(```|~~~).*?(?:\n[ \t]*\1[^\n]*|\Z)", re.DOTALL)
_URL_RE = re.compile(r"https?://[^\s<>\"'`\[\]\x00-\x1f]+", re.IGNORECASE)
_QUOTED_VALUE = r"`[^`\n]+`|\"[^\"\n]+\"|'[^'\n]+'"
_DIRECTIVE_RE = re.compile(rf"(?<![\w/])@(?P<kind>image|file):(?P<value>{_QUOTED_VALUE}|\S+)")
_MEDIA_TAG_RE = re.compile(r"MEDIA:[ \t]*(?P<value>(?:~/|/|[A-Za-z]:[\\/]|https?://)\S+)")
_IMAGE_HINT_RE = re.compile(r"\[Image attached at: ([^\n\]]+)\]")
_SENT_NOTE_RE = re.compile(
    r"\[The user sent [^\n]*?(?:saved at|voice message): (?P<path>(?:/|[A-Za-z]:[\\/])[^\s\]]+)")
_LINE_RANGE_RE = re.compile(r":\d+(?:-\d+)?$")
_TRAILING_PUNCTUATION = ".,;:!?'\"*_`"


@dataclass(frozen=True, slots=True)
class Occurrence:
    kind: str
    locator: str
    title: str
    subtitle: str
    mime: str | None


def _blocked_host(host: str) -> bool:
    if host == "localhost" or host.endswith(_BLOCKED_HOST_SUFFIXES):
        return True
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        labels = host.split(".")
        return len(labels) < 2 or labels[-1].isdigit() or labels[-1].startswith("0x")
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is not None:
        address = address.ipv4_mapped
    return not address.is_global


def normalize_url(raw: str) -> str | None:
    if not raw or len(raw) > MAX_URL_CHARS:
        return None
    try:
        parts = urlsplit(raw.strip())
        port = parts.port
        host = (parts.hostname or "").lower().rstrip(".")
    except ValueError:
        return None
    scheme = parts.scheme.lower()
    if scheme not in ("http", "https") or not host or parts.username or parts.password:
        return None
    if _blocked_host(host):
        return None
    netloc = f"[{host}]" if ":" in host else host
    if port is not None and port != (443 if scheme == "https" else 80):
        netloc = f"{netloc}:{port}"
    path = "" if parts.path == "/" and not parts.query else parts.path
    query = f"?{parts.query}" if parts.query else ""
    return f"{scheme}://{netloc}{path}{query}"


_CLOSERS = {")": "(", "]": "[", "}": "{"}


def _strip_url_tail(url: str) -> str:
    while url and (url[-1] in _TRAILING_PUNCTUATION or (url[-1] in _CLOSERS and url.count(_CLOSERS[url[-1]]) < url.count(url[-1]))):
        url = url[:-1]
    return url


def link_occurrence(raw: str) -> Occurrence | None:
    normalized = normalize_url(_strip_url_tail(raw))
    if normalized is None:
        return None
    parts = urlsplit(normalized)
    return Occurrence(KIND_LINK, normalized, normalized.split("://", 1)[1], parts.hostname or parts.netloc, None)


def _media_class(name: str) -> str | None:
    ext = posixpath.splitext(name)[1].lower()
    if ext in IMAGE_EXTENSIONS:
        return "image"
    if ext in AUDIO_EXTENSIONS:
        return "audio"
    if ext in VIDEO_EXTENSIONS:
        return "video"
    return None


def _display_name(ref: str) -> str:
    path = urlsplit(ref).path if ref.startswith(("http://", "https://")) else ref
    name = posixpath.basename(path.replace("\\", "/").rstrip("/"))
    return name or (urlsplit(ref).hostname or ref)


def _file_subtitle(name: str) -> str:
    ext = posixpath.splitext(name)[1].lstrip(".")
    return ext.upper() if ext else "File"


def path_occurrence(ref: str, *, media_class: str | None = None, force_file: bool = False) -> Occurrence | None:
    ref = ref.strip()
    if not ref or "\x00" in ref or len(ref) > MAX_URL_CHARS:
        return None
    remote = ref.lower().startswith(("http://", "https://"))
    if remote:
        normalized = normalize_url(ref)
        if normalized is None:
            return None
        ref = normalized
    elif ref.lower().startswith(("data:", "file:", "javascript:")) or "://" in ref:
        return None
    name = _display_name(ref)
    resolved = None if force_file else (media_class or _media_class(name))
    mime = mimetypes.guess_type(name)[0]
    if resolved is not None:
        return Occurrence(KIND_MEDIA, ref, name, MEDIA_CLASS_LABELS[resolved], mime or (f"{resolved}/*" if remote else None))
    if remote:
        return None
    return Occurrence(KIND_FILE, ref, name, _file_subtitle(name), mime)


def _unquote(value: str) -> str:
    if len(value) >= 2 and value[0] in "`\"'" and value[-1] == value[0]:
        return value[1:-1]
    return value


def _mask_fences(text: str) -> str:
    return _FENCE_RE.sub("\n", text)


def _directive_occurrences(text: str) -> Iterator[Occurrence]:
    for match in _DIRECTIVE_RE.finditer(text):
        value = match.group("value")
        if value[0] in "`\"'":
            quote_end = value.find(value[0], 1)
            value = value[1:quote_end] if quote_end > 0 else value
        else:
            value = _LINE_RANGE_RE.sub("", value.rstrip(_TRAILING_PUNCTUATION))
        if match.group("kind") == "image":
            found = path_occurrence(value, media_class="image")
        else:
            found = path_occurrence(_LINE_RANGE_RE.sub("", value), force_file=True)
        if found is not None:
            yield found


def _media_tag_occurrences(text: str) -> Iterator[Occurrence]:
    for match in _MEDIA_TAG_RE.finditer(text):
        found = path_occurrence(_unquote(match.group("value").rstrip(_TRAILING_PUNCTUATION + ")]}>")))
        if found is not None:
            yield found


def _attachment_note_occurrences(text: str) -> Iterator[Occurrence]:
    for match in _IMAGE_HINT_RE.finditer(text):
        if (found := path_occurrence(match.group(1), media_class="image")) is not None:
            yield found
    for match in _SENT_NOTE_RE.finditer(text):
        if (found := path_occurrence(match.group("path").rstrip(_TRAILING_PUNCTUATION))) is not None:
            yield found


def _url_occurrences(text: str) -> Iterator[Occurrence]:
    for match in _URL_RE.finditer(text):
        if (found := link_occurrence(match.group(0))) is not None:
            yield found


def _text_occurrences(role: str, text: str) -> Iterator[Occurrence]:
    plain = _mask_fences(text[:MAX_SCANNED_CHARS])
    if role == "user":
        yield from _directive_occurrences(plain)
        yield from _attachment_note_occurrences(plain)
    elif role == "assistant":
        yield from _media_tag_occurrences(plain)
    yield from _url_occurrences(plain)


def _part_occurrences(role: str, parts: Iterable) -> Iterator[Occurrence]:
    for part in parts:
        if not isinstance(part, dict):
            continue
        if part.get("type") in ("text", "input_text", "output_text") and isinstance(part.get("text"), str):
            yield from _text_occurrences(role, part["text"])
            continue
        image = part.get("image_url") if part.get("type") in ("image_url", "input_image") else None
        url = image.get("url") if isinstance(image, dict) else image
        if role == "user" and isinstance(url, str) and url.lower().startswith(("http://", "https://")):
            if (found := path_occurrence(url, media_class="image")) is not None:
                yield found


def _as_strings(value) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, (list, tuple)):
        return [item for item in value if isinstance(item, str)]
    return []


def _links_from(*keys: str) -> Callable[[dict], Iterator[Occurrence]]:
    def read(data: dict) -> Iterator[Occurrence]:
        for key in keys:
            for raw in _as_strings(data.get(key)):
                if (found := link_occurrence(raw)) is not None:
                    yield found
    return read


def _links_in_text_of(key: str) -> Callable[[dict], Iterator[Occurrence]]:
    def read(data: dict) -> Iterator[Occurrence]:
        text = data.get(key)
        if isinstance(text, str):
            yield from _url_occurrences(text[:MAX_SCANNED_CHARS])
    return read


def _links_in_nested(key: str, inner: str) -> Callable[[dict], Iterator[Occurrence]]:
    def read(data: dict) -> Iterator[Occurrence]:
        nested = data.get(key)
        if isinstance(nested, dict):
            yield from _links_from(inner)(nested)
    return read


def _media_from(*keys: str, media_class: str | None = None) -> Callable[[dict], Iterator[Occurrence]]:
    def read(data: dict) -> Iterator[Occurrence]:
        for key in keys:
            for raw in _as_strings(data.get(key)):
                if (found := path_occurrence(raw, media_class=media_class)) is not None:
                    yield found
    return read


def _files_from(*keys: str) -> Callable[[dict], Iterator[Occurrence]]:
    def read(data: dict) -> Iterator[Occurrence]:
        for key in keys:
            for raw in _as_strings(data.get(key)):
                if (found := path_occurrence(raw, force_file=True)) is not None:
                    yield found
    return read


@dataclass(frozen=True, slots=True)
class ToolRule:
    args: tuple[Callable[[dict], Iterator[Occurrence]], ...] = ()
    result: tuple[Callable[[dict], Iterator[Occurrence]], ...] = ()


_TOOL_RULES: dict[str, ToolRule] = {
    "web_extract": ToolRule(args=(_links_from("urls", "url"),)),
    "browser_navigate": ToolRule(args=(_links_from("url"),), result=(_links_from("url", "final_url"),)),
    "browser_exec": ToolRule(args=(_links_in_text_of("code"),), result=(_media_from("screenshot_path", media_class="image"),)),
    "browser_cdp": ToolRule(args=(_links_from("url"), _links_in_nested("params", "url"))),
    "write_file": ToolRule(args=(_files_from("path"),)),
    "patch": ToolRule(args=(_files_from("path"),)),
    "image_generate": ToolRule(result=(_media_from("image", media_class="image"),)),
    "text_to_speech": ToolRule(result=(_media_from("file_path", "file_paths", media_class="audio"),)),
}

TOOL_NAMES = frozenset(_TOOL_RULES)
RESULT_TOOL_NAMES = frozenset(name for name, rule in _TOOL_RULES.items() if rule.result)


def _json_object(raw) -> dict | None:
    if isinstance(raw, dict):
        return raw
    if not isinstance(raw, str) or not raw.lstrip().startswith("{"):
        return None
    try:
        decoded = json.loads(raw)
    except ValueError:
        return None
    return decoded if isinstance(decoded, dict) else None


def _call_occurrences(tool_calls) -> Iterator[Occurrence]:
    if not isinstance(tool_calls, list):
        return
    for call in tool_calls:
        function = call.get("function") if isinstance(call, dict) else None
        if not isinstance(function, dict) or not (rule := _TOOL_RULES.get(function.get("name") or "")):
            continue
        if (args := _json_object(function.get("arguments"))) is not None:
            for read in rule.args:
                yield from read(args)


def extract_message(role: str, content, tool_calls, tool_name: str | None) -> list[Occurrence]:
    found: dict[tuple[str, str], Occurrence] = {}

    def collect(source: Iterable[Occurrence]) -> bool:
        for occurrence in source:
            found.setdefault((occurrence.kind, occurrence.locator), occurrence)
            if len(found) >= MAX_OCCURRENCES_PER_MESSAGE:
                return True
        return False

    if role in ("user", "assistant"):
        if isinstance(content, str):
            collect(_text_occurrences(role, content))
        elif isinstance(content, list):
            collect(_part_occurrences(role, content))
        if role == "assistant":
            collect(_call_occurrences(tool_calls))
    elif role == "tool" and (rule := _TOOL_RULES.get(tool_name or "")):
        if (result := _json_object(content)) is not None:
            for read in rule.result:
                if collect(read(result)):
                    break
    return list(found.values())

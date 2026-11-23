from __future__ import annotations

import codecs
import mimetypes
import os
from dataclasses import dataclass

from tui_gateway.contracts.library import LibraryAssetKind as Kind

HEAD_BYTES = 4096


@dataclass(frozen=True, slots=True)
class Sniffed:
    kind: Kind
    mime: str
    previewable: bool


_EXECUTABLE = Sniffed(Kind.OTHER, "application/x-executable", False)
_SCRIPT = Sniffed(Kind.OTHER, "text/x-script", False)
_HTML = Sniffed(Kind.DOCUMENT, "text/html", False)
_SVG = Sniffed(Kind.IMAGE, "image/svg+xml", False)
_UNKNOWN = Sniffed(Kind.OTHER, "application/octet-stream", False)


def _archive(mime: str) -> Sniffed:
    return Sniffed(Kind.ARCHIVE, mime, False)


_PREFIXES: tuple[tuple[bytes, Sniffed], ...] = (
    (b"\x89PNG\r\n\x1a\n", Sniffed(Kind.IMAGE, "image/png", True)),
    (b"\xff\xd8\xff", Sniffed(Kind.IMAGE, "image/jpeg", True)),
    (b"GIF87a", Sniffed(Kind.IMAGE, "image/gif", True)),
    (b"GIF89a", Sniffed(Kind.IMAGE, "image/gif", True)),
    (b"%PDF-", Sniffed(Kind.PDF, "application/pdf", True)),
    (b"ID3", Sniffed(Kind.AUDIO, "audio/mpeg", True)),
    (b"fLaC", Sniffed(Kind.AUDIO, "audio/flac", True)),
    (b"OggS", Sniffed(Kind.AUDIO, "audio/ogg", True)),
    (b"#!AMR", Sniffed(Kind.AUDIO, "audio/amr", True)),
    (b"\x1f\x8b", _archive("application/gzip")),
    (b"7z\xbc\xaf\x27\x1c", _archive("application/x-7z-compressed")),
    (b"Rar!\x1a\x07", _archive("application/vnd.rar")),
    (b"\xfd7zXZ\x00", _archive("application/x-xz")),
    (b"BZh", _archive("application/x-bzip2")),
    (b"\x7fELF", _EXECUTABLE),
    (b"\xfe\xed\xfa\xce", _EXECUTABLE),
    (b"\xfe\xed\xfa\xcf", _EXECUTABLE),
    (b"\xce\xfa\xed\xfe", _EXECUTABLE),
    (b"\xcf\xfa\xed\xfe", _EXECUTABLE),
    (b"\xca\xfe\xba\xbe", _EXECUTABLE),
    (b"#!", _SCRIPT),
)
_ZIP_MAGICS = (b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08")
_OLE_MAGIC = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"
_ZIP_DOCUMENT_EXTENSIONS = frozenset({".docx", ".xlsx", ".pptx", ".odt", ".ods", ".odp", ".pages", ".numbers", ".key"})
_OLE_DOCUMENT_EXTENSIONS = frozenset({".doc", ".xls", ".ppt"})
_HEIC_BRANDS = frozenset({b"heic", b"heix", b"hevc", b"hevx", b"heim", b"heis"})
_HEIF_BRANDS = frozenset({b"mif1", b"msf1"})
_AVIF_BRANDS = frozenset({b"avif", b"avis"})
_AUDIO_BRANDS = frozenset({b"M4A ", b"M4B ", b"M4P "})
_QUICKTIME_ATOMS = frozenset({b"moov", b"mdat", b"wide", b"free", b"skip", b"pnot"})
_RIFF_FORMS = {
    b"WEBP": Sniffed(Kind.IMAGE, "image/webp", True),
    b"WAVE": Sniffed(Kind.AUDIO, "audio/wav", True),
    b"AVI ": Sniffed(Kind.VIDEO, "video/x-msvideo", True),
}
_HTML_EXTENSIONS = frozenset({".html", ".htm", ".xhtml"})
_TEXT_APPLICATION_MIMES = frozenset({
    "application/json", "application/xml", "application/javascript", "application/x-yaml", "application/toml"})
_KIND_BY_MIME_PREFIX = (("image/", Kind.IMAGE), ("video/", Kind.VIDEO), ("audio/", Kind.AUDIO))
_ARCHIVE_MIMES = frozenset({
    "application/zip", "application/gzip", "application/x-tar", "application/x-7z-compressed",
    "application/vnd.rar", "application/x-bzip2", "application/x-xz"})


def _prefix(head: bytes, ext: str) -> Sniffed | None:
    return next((found for magic, found in _PREFIXES if head.startswith(magic)), None)


def _zip_or_ole(head: bytes, ext: str) -> Sniffed | None:
    if head.startswith(_ZIP_MAGICS):
        if ext in _ZIP_DOCUMENT_EXTENSIONS:
            return Sniffed(Kind.DOCUMENT, mimetypes.guess_type(f"x{ext}")[0] or "application/zip", True)
        return _archive("application/zip")
    if head.startswith(_OLE_MAGIC):
        mime = mimetypes.guess_type(f"x{ext}")[0] or "application/x-ole-storage"
        return Sniffed(Kind.DOCUMENT, mime, ext in _OLE_DOCUMENT_EXTENSIONS)
    return None


def _iso_media(head: bytes, ext: str) -> Sniffed | None:
    if len(head) < 12:
        return None
    if head[4:8] == b"ftyp":
        brand = head[8:12]
        if brand in _HEIC_BRANDS:
            return Sniffed(Kind.IMAGE, "image/heic", True)
        if brand in _HEIF_BRANDS:
            return Sniffed(Kind.IMAGE, "image/heif", True)
        if brand in _AVIF_BRANDS:
            return Sniffed(Kind.IMAGE, "image/avif", False)
        if brand in _AUDIO_BRANDS:
            return Sniffed(Kind.AUDIO, "audio/mp4", True)
        if brand == b"qt  ":
            return Sniffed(Kind.VIDEO, "video/quicktime", True)
        return Sniffed(Kind.VIDEO, "video/mp4", True)
    if head[4:8] in _QUICKTIME_ATOMS:
        return Sniffed(Kind.VIDEO, "video/quicktime", True)
    return None


def _riff(head: bytes, ext: str) -> Sniffed | None:
    if len(head) >= 12 and head.startswith(b"RIFF"):
        return _RIFF_FORMS.get(head[8:12])
    return None


def _matroska(head: bytes, ext: str) -> Sniffed | None:
    if not head.startswith(b"\x1a\x45\xdf\xa3"):
        return None
    return Sniffed(Kind.VIDEO, "video/webm" if b"webm" in head[:64] else "video/x-matroska", True)


def _mpeg_audio(head: bytes, ext: str) -> Sniffed | None:
    if len(head) >= 2 and head[0] == 0xFF and head[1] & 0xE0 == 0xE0 and head[1] & 0x06:
        return Sniffed(Kind.AUDIO, "audio/mpeg", True)
    return None


def _bmp(head: bytes, ext: str) -> Sniffed | None:
    if len(head) >= 14 and head.startswith(b"BM") and head[6:10] == b"\0\0\0\0":
        return Sniffed(Kind.IMAGE, "image/bmp", True)
    return None


def _portable_executable(head: bytes, ext: str) -> Sniffed | None:
    if len(head) < 64 or not head.startswith(b"MZ"):
        return None
    header = int.from_bytes(head[60:64], "little")
    if header + 4 > len(head) or head[header:header + 4] == b"PE\0\0":
        return _EXECUTABLE
    return None


def _tar(head: bytes, ext: str) -> Sniffed | None:
    return _archive("application/x-tar") if head[257:262] == b"ustar" else None


def _extension_only(ext: str) -> Sniffed:
    mime = mimetypes.guess_type(f"x{ext}")[0] or "application/octet-stream"
    if mime in _ARCHIVE_MIMES:
        return _archive(mime)
    kind = next((k for prefix, k in _KIND_BY_MIME_PREFIX if mime.startswith(prefix)), None)
    if kind is None:
        kind = Kind.PDF if mime == "application/pdf" else Kind.OTHER
    return Sniffed(kind, mime, False)


def _is_utf8_text(head: bytes) -> bool:
    if b"\0" in head:
        return False
    try:
        codecs.getincrementaldecoder("utf-8")().decode(head, final=False)
    except UnicodeDecodeError:
        return False
    return True


def _text(head: bytes, ext: str) -> Sniffed:
    low = head.lower()
    if b"<svg" in low:
        return _SVG
    if ext in _HTML_EXTENSIONS or b"<!doctype html" in low or b"<html" in low or b"<script" in low:
        return _HTML
    guessed = mimetypes.guess_type(f"x{ext}")[0]
    plain = guessed is not None and (guessed.startswith("text/") or guessed in _TEXT_APPLICATION_MIMES)
    return Sniffed(Kind.DOCUMENT, guessed if plain else "text/plain", True)


_MAGIC_MATCHERS = (
    _prefix, _zip_or_ole, _iso_media, _riff, _matroska, _mpeg_audio, _bmp, _portable_executable, _tar)


def sniff(head: bytes, name: str) -> Sniffed:
    """Classify by the first bytes; the extension only picks among shapes the bytes already allow."""
    head = head[:HEAD_BYTES]
    ext = os.path.splitext(name)[1].lower()
    for matcher in _MAGIC_MATCHERS:
        if (found := matcher(head, ext)) is not None:
            return found
    if not head:
        return _UNKNOWN
    return _text(head, ext) if _is_utf8_text(head) else _extension_only(ext)

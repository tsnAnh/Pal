from __future__ import annotations

import pytest

from tui_gateway.library_media import sniff

ISO_HEAD = b"\x00\x00\x00\x18ftyp"
PNG = b"\x89PNG\r\n\x1a\n" + b"\0" * 16
ELF = b"\x7fELF\x02\x01\x01" + b"\0" * 32
PE = b"MZ" + b"\0" * 58 + (64).to_bytes(4, "little") + b"PE\0\0" + b"\0" * 20


@pytest.mark.parametrize(("head", "name", "kind", "mime", "previewable"), [
    (PNG, "a.png", "image", "image/png", True),
    (PNG, "renamed.mp4", "image", "image/png", True),
    (b"\xff\xd8\xff\xe0" + b"\0" * 20, "a.jpg", "image", "image/jpeg", True),
    (b"GIF89a" + b"\0" * 20, "a.gif", "image", "image/gif", True),
    (b"RIFF\0\0\0\0WEBPVP8 ", "a.webp", "image", "image/webp", True),
    (b"BM" + b"\0" * 4 + b"\0\0\0\0" + b"\0" * 20, "a.bmp", "image", "image/bmp", True),
    (ISO_HEAD + b"heic" + b"\0" * 20, "IMG_1.HEIC", "image", "image/heic", True),
    (ISO_HEAD + b"mif1" + b"\0" * 20, "a.heif", "image", "image/heif", True),
    (ISO_HEAD + b"isom" + b"\0" * 20, "clip.mp4", "video", "video/mp4", True),
    (ISO_HEAD + b"isom" + b"\0" * 20, "clip.txt", "video", "video/mp4", True),
    (ISO_HEAD + b"qt  " + b"\0" * 20, "clip.mov", "video", "video/quicktime", True),
    (b"\0\0\0\x08wide" + b"\0" * 20, "old.mov", "video", "video/quicktime", True),
    (b"\x1a\x45\xdf\xa3" + b"\x42\x82\x84webm" + b"\0" * 20, "a.webm", "video", "video/webm", True),
    (b"\x1a\x45\xdf\xa3" + b"\x42\x82\x88matroska" + b"\0" * 20, "a.mkv", "video", "video/x-matroska", True),
    (b"RIFF\0\0\0\0AVI LIST", "a.avi", "video", "video/x-msvideo", True),
    (ISO_HEAD + b"M4A " + b"\0" * 20, "a.m4a", "audio", "audio/mp4", True),
    (b"ID3\x04" + b"\0" * 20, "a.mp3", "audio", "audio/mpeg", True),
    (b"\xff\xfb\x90\x00" + b"\0" * 20, "a.mp3", "audio", "audio/mpeg", True),
    (b"RIFF\0\0\0\0WAVEfmt ", "a.wav", "audio", "audio/wav", True),
    (b"%PDF-1.7\n", "a.pdf", "pdf", "application/pdf", True),
    (b"%PDF-1.7\n", "disguised.png", "pdf", "application/pdf", True),
    (b"PK\x03\x04" + b"\0" * 20, "a.zip", "archive", "application/zip", False),
    (b"PK\x03\x04" + b"\0" * 20, "report.docx", "document", None, True),
    (b"\x1f\x8b\x08" + b"\0" * 20, "a.tgz", "archive", "application/gzip", False),
    (b"Rar!\x1a\x07\x00" + b"\0" * 20, "a.rar", "archive", "application/vnd.rar", False),
    (b"\0" * 257 + b"ustar\0" + b"\0" * 20, "a.tar", "archive", "application/x-tar", False),
    (b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" + b"\0" * 20, "old.doc", "document", None, True),
    (ELF, "photo.png", "other", "application/x-executable", False),
    (PE, "setup.pdf", "other", "application/x-executable", False),
    (b"\xcf\xfa\xed\xfe" + b"\0" * 20, "tool.jpg", "other", "application/x-executable", False),
    (b"#!/bin/sh\nrm -rf /\n", "notes.txt", "other", "text/x-script", False),
    (b"#!/usr/bin/env python3\n", "a.py", "other", "text/x-script", False),
    (b"hello, plain words\n", "photo.png", "document", "text/plain", True),
    (b"a,b\n1,2\n", "data.csv", "document", "text/csv", True),
    (b"# title\n", "README.md", "document", "text/markdown", True),
    (b'{"a": 1}\n', "a.json", "document", "application/json", True),
    (b"print('hi')\n", "a.py", "document", "text/x-python", True),
    (b"<!DOCTYPE html><html><body>x</body></html>", "page.txt", "document", "text/html", False),
    (b"<html><script>alert(1)</script>", "page.png", "document", "text/html", False),
    (b"plain", "page.html", "document", "text/html", False),
    (b'<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"/>', "a.svg", "image", "image/svg+xml", False),
    (b"", "empty.png", "other", "application/octet-stream", False),
    (b"\x00\x01\x02\x03\xff\xfe", "blob.bin", "other", "application/octet-stream", False),
    (b"\x00\x01\x02\x03\xff\xfe", "blob.mp4", "video", "video/mp4", False),
])
def test_sniff_classifies_by_content_first_and_the_name_second(head, name, kind, mime, previewable):
    found = sniff(head, name)
    assert found.kind.value == kind
    if mime is not None:
        assert found.mime == mime
    assert found.previewable is previewable


def test_a_text_head_cut_inside_a_multibyte_character_is_still_text():
    head = ("é" * 2048).encode()[:4095]
    assert sniff(head, "a.txt").mime == "text/plain"


def test_only_the_first_four_kilobytes_decide():
    assert sniff(b"x" * 4096 + b"\x7fELF", "a.txt").previewable is True

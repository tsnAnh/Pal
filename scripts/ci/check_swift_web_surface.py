#!/usr/bin/env python3
"""Fail when a web view appears outside the sandboxed full-screen HTML viewer.

Text matching only (no Swift toolchain); reuses the comment- and string-blanking ``Source`` scanner
of ``check_swift_glass.py``. There is no baseline. A justified exception carries ``web-surface-lint: ok``.

Scope: every .swift file under App/ and Packages/*/Sources/.
Rules:
* web-surface-outside-viewer: ``WKWebView``, ``WKWebViewConfiguration`` or ``WebView`` outside the HTML viewer files
  and the three pre-existing web surfaces (in-app browser, embeds, Mermaid). The chat list, the document card and
  every other view stay web-view free.
* html-viewer-bridge: in the HTML viewer files, no script message handler, user script or evaluated script. The page
  gets no bridge to the app and nothing is injected into it.
* html-viewer-store: in the HTML viewer files, no persistent website data store, and the sandbox factory must build
  a ``.nonPersistent()`` one.

Run: python scripts/ci/check_swift_web_surface.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_swift_glass import SKIP_DIRS, Finding, Source

OPT_OUT = "web-surface-lint: ok"
SANDBOX = "Packages/PalKit/Sources/PalChat/HTMLSandbox.swift"
VIEWER_DIR = "App/Chat/HTMLViewer/"
VIEWER_FILES = frozenset({SANDBOX, "App/Chat/ImageViewer/MacHTMLViewer.swift"})
LEGACY_SURFACES = frozenset({
    "App/Platform/InAppBrowser.swift",
    "App/Chat/Rich/EmbedWebView.swift",
    "App/Chat/Rich/MermaidRenderer.swift",
})
WEB_SURFACE = re.compile(r"(?<![A-Za-z0-9_])(?:WKWebView|WKWebViewConfiguration|WebView)(?![A-Za-z0-9_])")


@dataclass(frozen=True)
class ViewerRule:
    rule: str
    pattern: re.Pattern[str]
    message: str


VIEWER_RULES = (
    ViewerRule(
        "html-viewer-bridge",
        re.compile(
            r"addScriptMessageHandler|addScriptMessageHandlerWithReply|WKScriptMessageHandler|WKUserScript|addUserScript"
            r"|evaluateJavaScript|callAsyncJavaScript"
        ),
        "script bridge or injection in the HTML viewer. The page runs alone: no message handlers, no user scripts, "
        "nothing evaluated into it",
    ),
    ViewerRule(
        "html-viewer-store",
        re.compile(r"WKWebsiteDataStore\s*\.\s*default\s*\("),
        "persistent website data store in the HTML viewer. Pages keep no cookies or storage: use .nonPersistent()",
    ),
)
RULES = ("web-surface-outside-viewer", *(r.rule for r in VIEWER_RULES))
OUTSIDE_MESSAGE = (
    "web view outside the HTML viewer. WKWebView, WKWebViewConfiguration and WebView live only in "
    "App/Chat/HTMLViewer/, MacHTMLViewer.swift and HTMLSandbox.swift; the chat list and cards never run a web view"
)


def is_viewer(rel: str) -> bool:
    return rel.startswith(VIEWER_DIR) or rel in VIEWER_FILES


def in_scope(rel: Path) -> bool:
    parts = rel.parts
    return parts[:1] == ("App",) or (len(parts) > 3 and parts[:1] == ("Packages",) and parts[2] == "Sources")


def violations(rel: Path, source: str) -> list[Finding]:
    if not in_scope(rel):
        return []
    path = rel.as_posix()
    src = Source(source)
    found: list[Finding] = []

    def add(rule: str, index: int, message: str) -> None:
        if OPT_OUT not in src.original[index]:
            found.append(Finding(rule, path, index + 1, src.original[index].strip(), message))

    viewer = is_viewer(path)
    for i, code in enumerate(src.plain):
        if WEB_SURFACE.search(code) and not viewer and path not in LEGACY_SURFACES:
            add("web-surface-outside-viewer", i, OUTSIDE_MESSAGE)
        if viewer:
            for rule in VIEWER_RULES:
                if rule.pattern.search(code):
                    add(rule.rule, i, rule.message)
    if path == SANDBOX and not any(".nonPersistent()" in code for code in src.plain):
        found.append(Finding("html-viewer-store", path, 1, src.original[0].strip() if src.original else "",
                             "the HTML sandbox factory builds no .nonPersistent() website data store"))
    return sorted(found, key=lambda f: (f.path, f.line, f.rule))


def scan(root: Path) -> list[Finding]:
    found: list[Finding] = []
    for path in sorted(root.rglob("*.swift")):
        rel = path.relative_to(root)
        if SKIP_DIRS.intersection(rel.parts):
            continue
        found += violations(rel, path.read_text(encoding="utf-8-sig"))
    return found


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    root = Path(args[0]) if args else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for finding in found:
        print(finding.render())
    if found:
        print(f"\n{len(found)} web surface finding(s). Fix the code; "
              f'for a justified exception add "// {OPT_OUT}" on the line.')
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

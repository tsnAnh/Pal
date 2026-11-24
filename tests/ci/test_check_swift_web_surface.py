"""scripts/ci/check_swift_web_surface.py: a web view lives only in the sandboxed full-screen HTML viewer."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_web_surface.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_web_surface as csw

SURFACE = "App/Chat/HTMLViewer/HTMLWebSurface.swift"
SANDBOX = "Packages/PalKit/Sources/PalChat/HTMLSandbox.swift"
MAC = "App/Chat/ImageViewer/MacHTMLViewer.swift"
CARD = "App/Chat/Media/DocumentCard.swift"
LIST = "App/Chat/ChatTranscriptList.swift"
PACKAGE = "Packages/PalKit/Sources/PalChat/MediaKind.swift"

GOOD_SANDBOX = """
public static func makeConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    return configuration
}
"""


def _tree(tmp_path: Path, files: dict[str, str]) -> Path:
    for rel, body in files.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return tmp_path


def _found(tmp_path: Path, files: dict[str, str]) -> list[tuple[str, str, int]]:
    return [(f.rule, f.path, f.line) for f in csw.scan(_tree(tmp_path, files))]


@pytest.mark.parametrize("rel", [CARD, LIST, PACKAGE, "App/Chat/Media/Deep/Nested.swift"])
@pytest.mark.parametrize("token", ["WKWebView", "WKWebViewConfiguration", "WebView"])
def test_web_view_outside_the_viewer_fails(tmp_path: Path, rel: str, token: str) -> None:
    body = f"import SwiftUI\nlet view = {token}(frame: .zero)\n"
    assert _found(tmp_path, {rel: body}) == [("web-surface-outside-viewer", rel, 2)]


def test_viewer_files_may_hold_the_web_view(tmp_path: Path) -> None:
    body = "let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())\n"
    assert _found(tmp_path, {SURFACE: body, MAC: body, SANDBOX: GOOD_SANDBOX}) == []


@pytest.mark.parametrize("rel", sorted(csw.LEGACY_SURFACES))
def test_existing_surfaces_stay_allowed(tmp_path: Path, rel: str) -> None:
    assert _found(tmp_path, {rel: "let web = WKWebView(frame: .zero)\n"}) == []


def test_longer_identifiers_comments_and_strings_do_not_trigger(tmp_path: Path) -> None:
    body = ("let a = EmbedWebView()\nlet b = makeWebView()\nlet c = HTMLWebViewOwner.shared\n"
            "// WKWebView WebView\nlet d = \"WKWebView WebView\"\n/* WKWebViewConfiguration */\n")
    assert _found(tmp_path, {CARD: body}) == []


@pytest.mark.parametrize(
    "line",
    [
        "controller.add(handler, name: \"bridge\")\nlet h: WKScriptMessageHandler\n",
        "controller.addScriptMessageHandler(handler, contentWorld: .page, name: \"x\")\n",
        "let script = WKUserScript(source: s, injectionTime: .atDocumentStart, forMainFrameOnly: true)\n",
        "controller.addUserScript(script)\n",
        "web.evaluateJavaScript(\"1\")\n",
        "web.callAsyncJavaScript(\"1\", in: nil, in: .page)\n",
    ],
)
def test_script_bridge_in_the_viewer_fails(tmp_path: Path, line: str) -> None:
    found = _found(tmp_path, {SURFACE: "let a = 1\n" + line, SANDBOX: GOOD_SANDBOX})
    assert found
    assert {rule for rule, _, _ in found} == {"html-viewer-bridge"}


def test_persistent_store_in_the_viewer_fails(tmp_path: Path) -> None:
    body = "let a = 1\nconfiguration.websiteDataStore = WKWebsiteDataStore.default()\n"
    assert _found(tmp_path, {SURFACE: body, SANDBOX: GOOD_SANDBOX}) == [("html-viewer-store", SURFACE, 2)]


def test_sandbox_without_a_non_persistent_store_fails(tmp_path: Path) -> None:
    body = "let configuration = WKWebViewConfiguration()\nreturn configuration\n"
    assert _found(tmp_path, {SANDBOX: body}) == [("html-viewer-store", SANDBOX, 1)]


def test_opt_out_marker_passes_only_its_line(tmp_path: Path) -> None:
    body = "let a = WKWebView() // web-surface-lint: ok\nlet b = WKWebView()\n"
    assert _found(tmp_path, {CARD: body}) == [("web-surface-outside-viewer", CARD, 2)]


@pytest.mark.parametrize("rel", ["Tests/Anything.swift", "UITests/App/Page.swift", "Packages/PalKit/Tests/PalKitTests/A.swift"])
def test_tests_and_other_trees_are_ignored(tmp_path: Path, rel: str) -> None:
    assert _found(tmp_path, {rel: "let web = WKWebView()\n"}) == []


def test_every_rule_is_exercised() -> None:
    assert csw.RULES == ("web-surface-outside-viewer", "html-viewer-bridge", "html-viewer-store")


def test_real_tree_is_clean() -> None:
    assert csw.scan(REPO / "apps" / "ios") == []


def test_planted_violation_exits_one_with_fix_text(tmp_path: Path) -> None:
    root = _tree(tmp_path, {CARD: "import SwiftUI\n\nlet v = WKWebView(frame: .zero)\n"})
    assert csw.main(["check_swift_web_surface.py", str(root)]) == 1
    proc = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True, check=False)
    assert proc.returncode == 1
    assert "App/Chat/Media/DocumentCard.swift:3: [web-surface-outside-viewer]" in proc.stdout
    assert "the chat list and cards never run a web view" in proc.stdout
    assert "web-surface-lint: ok" in proc.stdout


def test_clean_tree_exits_zero_silently(tmp_path: Path) -> None:
    root = _tree(tmp_path, {CARD: "Text(caption)\n", SANDBOX: GOOD_SANDBOX})
    proc = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True, check=False)
    assert (proc.returncode, proc.stdout) == (0, "")

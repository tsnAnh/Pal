"""scripts/ci/check_swift_image_viewer.py: the chat image viewer keeps its structure rules."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_image_viewer.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_image_viewer as csv

SCREEN = "App/ChatView.swift"
VIEWER = "App/Chat/ImageViewer/MacImageViewer.swift"
COMPOSER_HOST = "App/Chat/ImageViewer/ViewerComposer.swift"


def _tree(tmp_path: Path, files: dict[str, str]) -> Path:
    for rel, body in files.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return tmp_path


def _rules(tmp_path: Path, rel: str, body: str) -> list[str]:
    files = {rel: body, COMPOSER_HOST: "ChatComposer(model: model)\n"} if rel.startswith("App/Chat/ImageViewer/") else {rel: body}
    return [f.rule for f in csv.scan(_tree(tmp_path, files))]


PRE_CHANGE_CHAT_VIEW = """
struct ChatView: View {
    var body: some View {
        content
            .fullCover(isPresented: Binding(get: { model.imageViewer != nil }, set: { if !$0 { model.imageViewer = nil } })) {
                ChatImageViewer(model: model).environment(\\.chatImageLoader, model.imageLoader)
            }
            .sheet(item: $model.filePreview) { file in
                FilePreviewSheet(file: file)
            }
    }
}
"""

IOS_ONLY_CHAT_VIEW = """
struct ChatView: View {
    var body: some View {
        content
            #if os(iOS)
            .fullCover(isPresented: Binding(get: { model.imageViewer != nil }, set: { if !$0 { model.imageViewer = nil } })) {
                ChatImageViewer(model: model).environment(\\.chatImageLoader, model.imageLoader)
            }
            #endif
    }
}
"""

CASES = [
    ("viewer-sheet-on-mac", SCREEN, PRE_CHANGE_CHAT_VIEW, IOS_ONLY_CHAT_VIEW),
    ("viewer-sheet-on-mac", SCREEN,
     "#if os(iOS)\nlet a = 1\n#else\nChatImageViewer(model: model)\n#endif\n",
     "#if os(iOS)\nChatImageViewer(model: model)\n#else\nMacImageViewer(model: model)\n#endif\n"),
    ("viewer-sheet-on-mac", SCREEN,
     "#if os(iOS)\nlet a = 1\n#elseif os(macOS)\nChatImageViewer(model: model)\n#endif\n",
     "#if os(macOS)\nMacImageViewer(model: model)\n#elseif os(iOS)\nChatImageViewer(model: model)\n#endif\n"),
    ("viewer-sheet-on-mac", SCREEN,
     "#if os(iOS)\n#endif\nChatImageViewer(model: model)\n",
     "#if os(iOS)\n#if DEBUG\nlet a = 1\n#endif\nChatImageViewer(model: model)\n#endif\n"),
    ("viewer-sheet-on-mac", "App/Chat/Other.swift", "ChatImageViewer(model: model)\n",
     "struct ChatImageViewer: View {\n    var body: some View { EmptyView() }\n}\n"),
    ("viewer-clear-glass", VIEWER, "Image(x).palGlass(Capsule())\n", "Image(x).palClearGlass(Capsule())\n"),
    ("viewer-clear-glass", VIEWER, "Image(x).glassEffect(.regular, in: Capsule())\n", "Image(x).palClearGlass(Capsule())\n"),
    ("viewer-clear-glass", VIEWER, "Button(\"Go\") {}.buttonStyle(.glass)\n", "Button(\"Go\") {}.buttonStyle(.plain)\n"),
    ("viewer-clear-glass", VIEWER, "Button(\"Go\") {}.buttonStyle(.glassProminent)\n", "Button(\"Go\") {}.buttonStyle(.borderless)\n"),
    ("viewer-own-composer", VIEWER, "TextField(\"Message\", text: $text)\n", "ChatComposer(model: model)\n"),
    ("viewer-own-composer", VIEWER, "TextEditor(text: $text)\n", "Text(caption)\n"),
    ("viewer-own-composer", VIEWER, "SecureField(\"Key\", text: $text)\n", "Text(caption)\n"),
    ("viewer-decode-main", VIEWER, "let image = NSImage(data: data)\n", "let image = await source.image(for: url)\n"),
    ("viewer-decode-main", VIEWER, "let image = PlatformImage(data: data)\n", "let image = await source.image(for: url)\n"),
    ("viewer-decode-main", VIEWER, "let image = UIImage(data: data)\n", "let image = await source.image(for: url)\n"),
    ("viewer-decode-main", VIEWER, "let s = CGImageSourceCreateWithData(data as CFData, nil)\n",
     "let image = await source.image(for: url)\n"),
    ("viewer-decode-main", VIEWER, "let image = ChatImageDecoder.downsample(data, maxPixel: 2048)\n",
     "let image = await source.image(for: url)\n"),
]


@pytest.mark.parametrize(("rule", "rel", "bad", "good"), CASES)
def test_violation_fails_and_clean_passes(tmp_path: Path, rule: str, rel: str, bad: str, good: str) -> None:
    assert rule in _rules(tmp_path / "red", rel, bad)
    assert _rules(tmp_path / "green", rel, good) == []


def test_every_rule_has_a_fixture() -> None:
    assert set(csv.RULES) == {rule for rule, *_ in CASES}


def test_viewer_directory_rules_ignore_other_screens(tmp_path: Path) -> None:
    body = "Image(x).palGlass(Capsule())\nTextField(\"Name\", text: $n)\nlet i = NSImage(data: d)\n"
    assert _rules(tmp_path, "App/Chat/ChatImages.swift", body) == []


def test_viewer_needs_the_shared_composer_once_the_directory_exists(tmp_path: Path) -> None:
    root = _tree(tmp_path / "red", {VIEWER: "Text(caption)\n"})
    found = csv.scan(root)
    assert [(f.rule, f.path) for f in found] == [("viewer-own-composer", "App/Chat/ImageViewer")]
    assert "ChatComposer" in found[0].message
    green = _tree(tmp_path / "green", {VIEWER: "Text(caption)\n", COMPOSER_HOST: "ChatComposer(model: model)\n"})
    assert csv.scan(green) == []
    assert csv.scan(_tree(tmp_path / "absent", {SCREEN: "let a = 1\n"})) == []


def test_composer_in_a_comment_or_string_does_not_count(tmp_path: Path) -> None:
    root = _tree(tmp_path, {VIEWER: "// ChatComposer(model: model)\nlet s = \"ChatComposer(x)\"\n"})
    assert [f.rule for f in csv.scan(root)] == ["viewer-own-composer"]


def test_opt_out_marker_and_test_targets_are_exempt(tmp_path: Path) -> None:
    marked = "ChatImageViewer(model: model) // viewer-lint: ok\n"
    assert _rules(tmp_path / "a", SCREEN, marked) == []
    assert _rules(tmp_path / "b", VIEWER, "Image(x).palGlass(Capsule()) // viewer-lint: ok\n") == []
    assert _rules(tmp_path / "c", "UITests/View.swift", "ChatImageViewer(model: model)\n") == []
    assert _rules(tmp_path / "d", "Tests/App/Chat/ImageViewer/View.swift", "TextField(\"a\", text: $t)\n") == []
    skipped = _tree(tmp_path / "e", {"UITests/App/Chat/ImageViewer/View.swift": "let a = 1\n"})
    assert csv.scan(skipped) == []


def test_comments_and_strings_do_not_trigger(tmp_path: Path) -> None:
    body = ("// ChatImageViewer(model: model) and .palGlass( and TextField(\n"
            "let label = \"NSImage(data: d) .glassEffect(\"\n/* UIImage(data: d) */\n")
    assert _rules(tmp_path / "a", SCREEN, body) == []
    assert _rules(tmp_path / "b", VIEWER, body) == []


def test_planted_violation_is_reported_with_file_line_rule_and_fix(tmp_path: Path) -> None:
    root = _tree(tmp_path, {SCREEN: "import SwiftUI\n\nlet v = ChatImageViewer(model: model)\n"})
    proc = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True, check=False)
    assert proc.returncode == 1
    assert "App/ChatView.swift:3: [viewer-sheet-on-mac]" in proc.stdout
    assert "MacImageViewer" in proc.stdout
    assert "viewer-lint: ok" in proc.stdout


def test_clean_tree_exits_zero_silently(tmp_path: Path) -> None:
    root = _tree(tmp_path, {SCREEN: IOS_ONLY_CHAT_VIEW, VIEWER: "Image(x).palClearGlass(Capsule())\n",
                            COMPOSER_HOST: "ChatComposer(model: model)\n"})
    proc = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True, check=False)
    assert (proc.returncode, proc.stdout) == (0, "")

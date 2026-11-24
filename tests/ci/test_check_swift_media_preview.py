"""scripts/ci/check_swift_media_preview.py: chat media previews stay one stroke-free surface with no bubble."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_media_preview.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_media_preview as csm

TILE = "App/Chat/Media/MediaTile.swift"
NESTED = "App/Chat/Media/Video/VideoTile.swift"
MAC = "App/Chat/ImageViewer/MacMediaViewer.swift"
HTML_BODY = "App/Chat/HTMLViewer/HTMLViewerBody.swift"
HTML_MAC = "App/Chat/ImageViewer/MacHTMLViewer.swift"

CLEAN_TILE = """
struct MediaTile: View {
    var body: some View {
        poster
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}
"""

OVERLAY_STROKE = """
poster.overlay {
    RoundedRectangle(cornerRadius: 18).stroke(Color.gray, lineWidth: 1)
}
"""


def _tree(tmp_path: Path, files: dict[str, str]) -> Path:
    for rel, body in files.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return tmp_path


def _found(tmp_path: Path, rel: str, body: str) -> list[tuple[str, int]]:
    return [(f.rule, f.line) for f in csm.scan(_tree(tmp_path, {rel: body}))]


def test_clean_tile_passes(tmp_path: Path) -> None:
    assert _found(tmp_path, TILE, CLEAN_TILE) == []


@pytest.mark.parametrize("rel", [TILE, NESTED, MAC, HTML_BODY, HTML_MAC])
@pytest.mark.parametrize(
    ("body", "rule"),
    [
        ("let a = 1\nposter.stroke(Color.gray)\n", "media-no-stroke"),
        ("let a = 1\nshape.strokeBorder(Color.gray, lineWidth: 1)\n", "media-no-stroke"),
        ("let a = 1\nposter.border(Color.gray)\n", "media-no-stroke"),
        ("let a = 1\nlet c = palette.cardStroke\n", "media-no-stroke"),
        ("let a = 1\nChatBubble(sender: .bot) { poster }\n", "media-no-bubble"),
        ("let a = 1\nChatBubble { poster }\n", "media-no-bubble"),
    ],
)
def test_violation_reports_rule_and_line(tmp_path: Path, rel: str, body: str, rule: str) -> None:
    assert _found(tmp_path, rel, body) == [(rule, 2)]


def test_overlay_wrapping_a_stroke_fails_on_the_stroke_line(tmp_path: Path) -> None:
    assert _found(tmp_path, TILE, OVERLAY_STROKE) == [("media-no-stroke", 3)]


def test_overlay_alone_is_not_a_rule(tmp_path: Path) -> None:
    assert _found(tmp_path, TILE, "poster.overlay { PlayBadge() }\n") == []


def test_strokeborder_is_one_finding(tmp_path: Path) -> None:
    assert _found(tmp_path, TILE, "shape.strokeBorder(Color.gray)\n") == [("media-no-stroke", 1)]


def test_longer_identifiers_are_not_matched(tmp_path: Path) -> None:
    body = ("let s = ChatBubbleStyle.plain\nlet t: MyChatBubble\nlet v = ChatBubbleView()\n"
            "let w = cardStrokeWidth\nlet x = preCardStroke\nshape.strokeStyle(style)\nshape.borderless\n")
    assert _found(tmp_path, TILE, body) == []


def test_comments_and_strings_do_not_trigger(tmp_path: Path) -> None:
    body = ("// .stroke( .strokeBorder( .border( cardStroke ChatBubble(\n"
            "let label = \"cardStroke .stroke( ChatBubble {\"\n/* ChatBubble { .border( */\n")
    assert _found(tmp_path, TILE, body) == []


def test_opt_out_marker_passes_only_its_line(tmp_path: Path) -> None:
    body = "poster.stroke(Color.gray) // media-preview-lint: ok\nposter.border(Color.gray)\n"
    assert _found(tmp_path, TILE, body) == [("media-no-stroke", 2)]


@pytest.mark.parametrize("rel", ["App/Chat/ChatImages.swift", "App/Chat/Rich/VideoBlockView.swift",
                                 "App/Chat/ImageViewer/MacImageViewer.swift", "App/Chat/MediaTile.swift",
                                 "UITests/App/Chat/Media/Tile.swift"])
def test_files_outside_scope_are_ignored(tmp_path: Path, rel: str) -> None:
    assert _found(tmp_path, rel, "poster.stroke(Color.gray)\nChatBubble { poster }\n") == []


def test_missing_scope_directory_yields_no_findings(tmp_path: Path) -> None:
    assert csm.scan(_tree(tmp_path, {"App/ChatView.swift": "let a = 1\n"})) == []
    assert csm.scan(tmp_path / "does-not-exist") == []


def test_every_rule_is_exercised() -> None:
    assert csm.RULES == ("media-no-stroke", "media-no-bubble")


def test_real_tree_is_clean() -> None:
    assert csm.scan(REPO / "apps" / "ios") == []


def test_planted_violation_exits_one_with_fix_text(tmp_path: Path) -> None:
    root = _tree(tmp_path, {TILE: "import SwiftUI\n\nlet v = poster.strokeBorder(Color.gray)\n"})
    assert csm.main(["check_swift_media_preview.py", str(root)]) == 1
    proc = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True, check=False)
    assert proc.returncode == 1
    assert "App/Chat/Media/MediaTile.swift:3: [media-no-stroke]" in proc.stdout
    assert "fill, a soft shadow and spacing" in proc.stdout
    assert "media-preview-lint: ok" in proc.stdout


def test_planted_bubble_message_names_the_sibling_rule(tmp_path: Path) -> None:
    root = _tree(tmp_path, {MAC: "ChatBubble(sender: .user) { poster }\n"})
    proc = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True, check=False)
    assert proc.returncode == 1
    assert "[media-no-bubble]" in proc.stdout
    assert "AssistantBubble/UserBubble" in proc.stdout


def test_clean_tree_exits_zero_silently(tmp_path: Path) -> None:
    root = _tree(tmp_path, {TILE: CLEAN_TILE, MAC: "Text(caption)\n"})
    proc = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True, check=False)
    assert (proc.returncode, proc.stdout) == (0, "")


@pytest.mark.parametrize("name", ["DocumentCard", "DocumentFileCard"])
def test_document_cards_are_covered(tmp_path: Path, name: str) -> None:
    rel = f"App/Chat/Media/{name}.swift"
    assert _found(tmp_path, rel, CLEAN_TILE) == []
    assert [rule for rule, _ in _found(tmp_path, rel, OVERLAY_STROKE)] == ["media-no-stroke"]
    assert [rule for rule, _ in _found(tmp_path, rel, "ChatBubble { card }")] == ["media-no-bubble"]

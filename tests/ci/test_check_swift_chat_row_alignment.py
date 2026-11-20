"""scripts/ci/check_swift_chat_row_alignment.py: a full-width chat row frame names its side instead of centring by default."""

from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_chat_row_alignment.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_chat_row_alignment as cra

CHIP = (
    "struct NoticeRow: View {\n"
    "    var body: some View {\n"
    "        HStack(spacing: 6) { Text(title) }\n"
    "        .background(highlightFill, in: Capsule())\n"
    "        .frame(maxWidth: .infinity)\n"
    "        .accessibilityIdentifier(\"inboundNotice\")\n"
    "    }\n"
    "}\n"
)


def _tree(tmp_path: Path, body: str, name: str = "App/Chat/ChatRows.swift") -> Path:
    path = tmp_path / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    return tmp_path


def test_the_inbound_notice_chip_without_an_alignment_fails_and_names_the_line(tmp_path):
    found = cra.scan(_tree(tmp_path, CHIP))
    assert len(found) == 1
    assert found[0].startswith("App/Chat/ChatRows.swift:5:")
    assert "chatRowFrame(for: ChatSender)" in found[0]


def test_the_fixed_chip_passes(tmp_path):
    assert cra.scan(_tree(tmp_path, CHIP.replace(".frame(maxWidth: .infinity)", ".chatRowFrame(for: .system)"))) == []


def test_an_explicit_alignment_passes(tmp_path):
    for call in (".frame(maxWidth: .infinity, alignment: .leading)", ".frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)"):
        assert cra.scan(_tree(tmp_path, CHIP.replace(".frame(maxWidth: .infinity)", call))) == [], call


def test_a_min_height_frame_without_an_alignment_fails(tmp_path):
    found = cra.scan(_tree(tmp_path, CHIP.replace(".frame(maxWidth: .infinity)", ".frame(maxWidth: .infinity, minHeight: 44)")))
    assert len(found) == 1


def test_a_nested_call_before_the_alignment_still_passes(tmp_path):
    call = ".frame(maxWidth: .infinity, minHeight: PlatformVariant.pick(mac: 30, iOS: 40), alignment: .leading)"
    assert cra.scan(_tree(tmp_path, CHIP.replace(".frame(maxWidth: .infinity)", call))) == []


def test_a_multiline_frame_without_an_alignment_fails(tmp_path):
    found = cra.scan(_tree(tmp_path, CHIP.replace(".frame(maxWidth: .infinity)", ".frame(\n            maxWidth: .infinity,\n            minHeight: 44\n        )")))
    assert len(found) == 1


def test_a_finite_max_width_frame_without_an_alignment_fails(tmp_path):
    for call in (".frame(maxWidth: 320)", ".frame(maxWidth: ChatMetrics.bubbleMaxWidth)", ".frame(maxWidth: 320, maxHeight: 40)"):
        assert len(cra.scan(_tree(tmp_path, CHIP.replace(".frame(maxWidth: .infinity)", call)))) == 1, call


def test_a_finite_max_width_frame_with_an_alignment_passes(tmp_path):
    assert cra.scan(_tree(tmp_path, CHIP.replace(".frame(maxWidth: .infinity)", ".frame(maxWidth: 320, alignment: .leading)"))) == []


def test_a_width_only_frame_without_an_alignment_fails_but_a_sized_box_passes(tmp_path):
    assert len(cra.scan(_tree(tmp_path, CHIP.replace(".frame(maxWidth: .infinity)", ".frame(width: tile * 2 + spacing)")))) == 1
    assert cra.scan(_tree(tmp_path, CHIP.replace(".frame(maxWidth: .infinity)", ".frame(width: 7, height: 7)"))) == []
    assert cra.scan(_tree(tmp_path, CHIP.replace(".frame(maxWidth: .infinity)", ".frame(minWidth: 40)"))) == []


def test_an_alignment_inside_a_nested_call_does_not_count(tmp_path):
    call = ".frame(maxWidth: 320, minHeight: pick(alignment: .leading))"
    assert len(cra.scan(_tree(tmp_path, CHIP.replace(".frame(maxWidth: .infinity)", call)))) == 1


BUBBLE_WIDTH = (
    "extension View {\n"
    "    @ViewBuilder\n"
    "    func bubbleWidth(_ alignment: HorizontalAlignment) -> some View {\n"
    "        #if os(macOS)\n"
    "        frame(maxWidth: ChatMetrics.bubbleMaxWidth).chatRowFrame(for: alignment == .trailing ? .user : .bot)\n"
    "        #endif\n"
    "    }\n"
    "}\n"
)


def test_the_mac_bubble_width_helper_that_centred_file_cards_fails_and_its_fix_passes(tmp_path):
    found = cra.scan(_tree(tmp_path, BUBBLE_WIDTH, name="App/Chat/BubbleWidth.swift"))
    assert len(found) == 1
    assert found[0].startswith("App/Chat/BubbleWidth.swift:5:")
    fixed = BUBBLE_WIDTH.replace("bubbleMaxWidth)", "bubbleMaxWidth, alignment: ChatMetrics.bubbleColumnAlignment(alignment))")
    assert cra.scan(_tree(tmp_path, fixed, name="App/Chat/BubbleWidth.swift")) == []


def test_the_image_grid_and_file_card_files_are_scanned():
    for name in ("App/Chat/ChatImages.swift", "App/Chat/ChatFileCard.swift", "App/Chat/BubbleWidth.swift"):
        assert name in cra.ROW_FILES


def test_files_outside_the_row_list_are_not_scanned(tmp_path):
    assert cra.scan(_tree(tmp_path, CHIP, name="App/Chat/EmojiPickerView.swift")) == []


def test_the_opt_out_marker_waives_the_line(tmp_path):
    waived = CHIP.replace(".frame(maxWidth: .infinity)", ".frame(maxWidth: .infinity) // chat-row-alignment: ok sheet title")
    assert cra.scan(_tree(tmp_path, waived)) == []


def test_the_real_tree_is_clean():
    assert cra.scan(REPO / "apps" / "ios") == []

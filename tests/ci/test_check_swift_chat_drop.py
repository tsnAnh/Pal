"""scripts/ci/check_swift_chat_drop.py: the Mac chat pane keeps one file and image drop target."""

from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_chat_drop.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_chat_drop as csd

PANE = "struct ChatView: View {\n    var body: some View {\n        chat\n            .attachmentIntake(intake: attach)\n    }\n}\n"
COMPOSER_TARGET = "struct ChatComposer: View {\n    var body: some View {\n        row\n            .attachmentIntake(intake: attach)\n    }\n}\n"
COMPOSER_PASTE = COMPOSER_TARGET.replace("attachmentIntake", "attachmentPaste")
RAW_DROP = "struct Strip: View {\n    var body: some View {\n        row\n            .onDrop(of: [.fileURL], isTargeted: nil) { _ in true }\n    }\n}\n"
DESTINATION = RAW_DROP.replace(".onDrop(of: [.fileURL], isTargeted: nil) { _ in true }", ".dropDestination(for: URL.self) { _, _ in true }")


def _tree(tmp_path: Path, files: dict[str, str]) -> Path:
    for name, body in files.items():
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return tmp_path


def test_one_pane_target_with_composer_paste_passes(tmp_path):
    root = _tree(tmp_path, {"App/ChatView.swift": PANE, "App/Chat/ChatComposer.swift": COMPOSER_PASTE})
    assert csd.scan(root) == []


def test_a_second_shared_modifier_in_the_composer_fails_and_names_it(tmp_path):
    root = _tree(tmp_path, {"App/ChatView.swift": PANE, "App/Chat/ChatComposer.swift": COMPOSER_TARGET})
    found = csd.scan(root)
    assert len(found) == 2 and all("attachmentIntake(" in line for line in found)


def test_a_raw_drop_target_in_a_pane_file_fails(tmp_path):
    for body in (RAW_DROP, DESTINATION):
        root = _tree(tmp_path, {"App/ChatView.swift": PANE, "App/Chat/Strip.swift": body})
        assert any("attachmentIntake" in line and "Strip.swift" in line for line in csd.scan(root))


def test_the_shared_modifier_file_and_other_screens_are_not_scanned(tmp_path):
    root = _tree(tmp_path, {
        "App/ChatView.swift": PANE,
        "App/Platform/AttachmentIntake.swift": RAW_DROP,
        "App/Rooms/RoomView.swift": PANE,
    })
    assert csd.scan(root) == []


def test_the_opt_out_waives_a_line(tmp_path):
    root = _tree(tmp_path, {"App/ChatView.swift": PANE, "App/Chat/Strip.swift": RAW_DROP.replace("true }", "true } // drop-target: ok")})
    assert csd.scan(root) == []

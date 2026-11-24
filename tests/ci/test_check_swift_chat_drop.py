"""scripts/ci/check_swift_chat_drop.py: the Mac chat pane keeps one file and image drop target and never fails silently."""

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


INTAKE = (
    "extension View {\n    func attachmentIntake() -> some View { overlay { AttachmentDropAnchor(targeting: t, intake: i) } }\n}\n"
    "enum AttachmentIntake {\n    static func collect() {\n        batch.failures.append(.unreadable)\n        intake(batch)\n    }\n}\n"
)
DROP_VIEW = (
    "final class AttachmentDropView: NSView {\n    init() { registerForDraggedTypes(types) }\n"
    "    func finish() -> Bool { AttachmentIntake.receive(payloads: p, intake: i) }\n}\n"
)
CORE = {"App/ChatView.swift": PANE, "App/Platform/AttachmentIntake.swift": INTAKE, "App/Platform/AttachmentDropView.swift": DROP_VIEW}


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


def test_the_core_files_other_screens_and_the_one_target_pass(tmp_path):
    root = _tree(tmp_path, {**CORE, "App/Rooms/RoomView.swift": PANE})
    assert csd.scan(root) == []


def test_a_swiftui_drop_target_beside_the_appkit_one_fails(tmp_path):
    root = _tree(tmp_path, {**CORE, "App/Platform/AttachmentIntake.swift": INTAKE + RAW_DROP})
    assert any("AttachmentIntake.swift" in line and "one target per platform" in line for line in csd.scan(root))


def test_a_second_anchor_or_a_missing_anchor_fails(tmp_path):
    twice = INTAKE + "let again = AttachmentDropAnchor(targeting: t, intake: i)\n"
    assert any("exactly once" in line for line in csd.scan(_tree(tmp_path / "a", {**CORE, "App/Platform/AttachmentIntake.swift": twice})))
    elsewhere = {**CORE, "App/Chat/Strip.swift": "let strip = AttachmentDropAnchor(targeting: t, intake: i)\n"}
    assert any("exactly once" in line for line in csd.scan(_tree(tmp_path / "b", elsewhere)))
    assert any("exactly once" in line for line in csd.scan(_tree(tmp_path / "c", {**CORE, "App/Platform/AttachmentIntake.swift": ""})))


def test_a_class_swap_or_a_registration_outside_the_drop_view_fails(tmp_path):
    swap = {**CORE, "App/Platform/ComposerDragForwarding.swift": "object_setClass(editor, forwarding)\n"}
    assert any("class swap" in line for line in csd.scan(_tree(tmp_path / "a", swap)))
    register = {**CORE, "App/Chat/Strip.swift": "view.registerForDraggedTypes([.fileURL])\n"}
    assert any("registers for drag types" in line for line in csd.scan(_tree(tmp_path / "b", register)))


def test_a_child_that_opts_out_of_drags_is_allowed(tmp_path):
    optout = {**CORE, "App/Chat/Web.swift": "override func registerForDraggedTypes(_ types: [NSPasteboard.PasteboardType]) {}\n"}
    assert csd.scan(_tree(tmp_path, optout)) == []


def test_a_drop_that_can_fail_silently_fails(tmp_path):
    bypass = {**CORE, "App/Platform/AttachmentDropView.swift": DROP_VIEW.replace("AttachmentIntake.receive(", "other(")}
    assert any("AttachmentIntake.receive(" in line for line in csd.scan(_tree(tmp_path / "a", bypass)))
    builds = {**CORE, "App/Platform/AttachmentDropView.swift": DROP_VIEW + "let b = DropBatch(files: urls)\n"}
    assert any("builds a DropBatch" in line for line in csd.scan(_tree(tmp_path / "b", builds)))
    silent = {**CORE, "App/Platform/AttachmentIntake.swift": INTAKE.replace("batch.failures.append(.unreadable)\n", "")}
    assert any("never drop silently" in line for line in csd.scan(_tree(tmp_path / "c", silent)))
    unreported = {**CORE, "App/Platform/AttachmentIntake.swift": INTAKE.replace("intake(batch)", "")}
    assert any("never drop silently" in line for line in csd.scan(_tree(tmp_path / "d", unreported)))


def test_the_opt_out_waives_a_line(tmp_path):
    root = _tree(tmp_path, {"App/ChatView.swift": PANE, "App/Chat/Strip.swift": RAW_DROP.replace("true }", "true } // drop-target: ok")})
    assert csd.scan(root) == []

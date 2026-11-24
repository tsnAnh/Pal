"""scripts/ci/check_swift_chat_scroll_writer.py: ChatScrollController.perform is the only chat scroll writer."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_chat_scroll_writer.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_chat_scroll_writer as writer

LIST = "App/Chat/ChatTranscriptList.swift"
CONTROLLER = "App/Chat/ChatScrollController.swift"
PLATFORM = "App/Platform/ChatPlatform.swift"
FIX = "route it through ChatScrollMachine: emit a command and let ChatScrollController.perform apply it"

COMPLIANT_LIST = (
    "struct ChatTranscriptList: View {\n"
    "    var body: some View {\n"
    "        ScrollView { rows }\n"
    "            .scrollPosition($scroll.position)\n"
    "            .defaultScrollAnchor(.bottom)\n"
    "    }\n"
    "}\n"
)
COMPLIANT_CONTROLLER = (
    "final class ChatScrollController {\n"
    "    private(set) var machine = ChatScrollMachine()\n"
    "    func observe(_ geometry: ScrollGeometry) {\n"
    "        let y = geometry.contentOffset.y\n"
    "        performNextTurn(machine.handle(.geometry(y)))\n"
    "    }\n"
    "    func perform(_ command: ChatScrollMachine.Command) {\n"
    "        switch command {\n"
    "        case .scrollToBottom: position.scrollTo(edge: .bottom)\n"
    "        case let .scrollToRow(id): withAnimation { position.scrollTo(id: id, anchor: Self.revealAnchor) }\n"
    "        default: break\n"
    "        }\n"
    "    }\n"
    "}\n"
)
COMPLIANT_PLATFORM = "extension View {\n    func chatRow() -> some View { self }\n}\n"

FLIPPED_PLATFORM = (
    "extension View {\n"
    "    func chatList() -> some View {\n"
    "        scaleEffect(x: 1, y: -1, anchor: .center)\n"
    "    }\n"
    "}\n"
)
INSET_LIST = (
    "struct ChatTranscriptList: View {\n"
    "    var body: some View {\n"
    "        ScrollView { rows }\n"
    "            .scrollPosition($scroll.position)\n"
    "            .contentMargins(.top, 8, for: .automatic)\n"
    "    }\n"
    "}\n"
)
UNROUTED_CONTROLLER = (
    "final class ChatScrollController {\n"
    "    func jump(_ target: ScrollPosition) {\n"
    "        target.scrollTo(edge: .top)\n"
    "    }\n"
    "}\n"
)


def _write(root: Path, files: dict[str, str]) -> Path:
    for name, body in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return root


def _tree(tmp_path: Path, **overrides: str) -> Path:
    files = {LIST: COMPLIANT_LIST, CONTROLLER: COMPLIANT_CONTROLLER, PLATFORM: COMPLIANT_PLATFORM}
    files.update({name.replace("__", "/").replace("_swift", ".swift"): body for name, body in overrides.items()})
    return _write(tmp_path, files)


def _scan(root: Path, allowlist: str | None = None) -> list[str]:
    path = root / "allowlist.txt"
    path.write_text(allowlist or "", encoding="utf-8")
    return writer.scan(root, path)


def test_a_compliant_tree_passes(tmp_path):
    assert _scan(_tree(tmp_path)) == []


def test_mains_flipped_list_fails_on_each_old_writer(tmp_path):
    root = _write(tmp_path, {LIST: INSET_LIST, CONTROLLER: UNROUTED_CONTROLLER, PLATFORM: FLIPPED_PLATFORM})
    found = _scan(root)
    text = "\n".join(found)
    assert f"{PLATFORM}:" in text and "flipped list" in text
    assert f"{LIST}:" in text and ".contentMargins" in text
    assert f"{CONTROLLER}:" in text and "programmatic scroll" in text
    assert "does not reference ChatScrollMachine" in text
    assert all(entry.endswith(FIX) for entry in found)


def test_scroll_to_outside_perform_fails_and_inside_passes(tmp_path):
    outside = COMPLIANT_CONTROLLER.replace(
        "        performNextTurn(machine.handle(.geometry(y)))\n", "        position.scrollTo(y: y)\n"
    )
    found = _scan(_tree(tmp_path, App__Chat__ChatScrollController_swift=outside))
    assert len(found) == 1 and found[0].startswith(f"{CONTROLLER}:5:") and found[0].endswith(FIX)


def test_a_scroll_write_inside_the_layout_commit_fails(tmp_path):
    inside = COMPLIANT_CONTROLLER.replace("performNextTurn(machine", "perform(machine")
    found = _scan(_tree(tmp_path, App__Chat__ChatScrollController_swift=inside))
    assert len(found) == 1 and found[0].startswith(f"{CONTROLLER}:5:") and "layout commit" in found[0] and found[0].endswith(FIX)


def test_a_direct_perform_outside_the_layout_callbacks_passes(tmp_path):
    outside = COMPLIANT_CONTROLLER.replace("    func perform(", "    func jump() { perform(.none) }\n    func perform(")
    assert _scan(_tree(tmp_path, App__Chat__ChatScrollController_swift=outside)) == []


def test_the_transcript_loop_over_the_whole_model_fails(tmp_path):
    whole = COMPLIANT_LIST.replace("ScrollView { rows }", "ScrollView { ForEach(model.rows) { Text($0.id) } }")
    found = _scan(_tree(tmp_path / "a", App__Chat__ChatTranscriptList_swift=whole))
    assert len(found) == 1 and "model.windowRows" in found[0] and found[0].endswith(FIX)
    windowed = whole.replace("model.rows", "model.windowRows")
    assert _scan(_tree(tmp_path / "b", App__Chat__ChatTranscriptList_swift=windowed)) == []


def test_perform_ends_at_its_closing_brace(tmp_path):
    after = COMPLIANT_CONTROLLER.removesuffix("}\n") + "    func later() { position.scrollTo(y: 0) }\n}\n"
    found = _scan(_tree(tmp_path, App__Chat__ChatScrollController_swift=after))
    assert len(found) == 1 and "programmatic scroll" in found[0]


@pytest.mark.parametrize(
    "call",
    [
        "proxy.scrollTo(id)",
        "let p: ScrollViewProxy",
        "ScrollViewReader { proxy in }",
        "view.setContentOffset(.zero, animated: false)",
        "scrollView.contentOffset = .zero",
        "view.scroll(to: .zero)",
        "view.scrollToVisible(rect)",
        "clip.reflectScrolledClipView(clip)",
    ],
)
def test_every_forbidden_writer_outside_perform_fails(tmp_path, call):
    controller = COMPLIANT_CONTROLLER.replace("let y = geometry.contentOffset.y", call)
    found = _scan(_tree(tmp_path, App__Chat__ChatScrollController_swift=controller))
    assert len(found) == 1, call


def test_writers_in_other_chat_files_fail(tmp_path):
    root = _tree(tmp_path, App__Chat__ChatView_swift="func f() { proxy.scrollTo(id) }\n", App__ChatView_swift="func g() { position.scrollTo(edge: .top) }\n")
    found = _scan(root)
    assert sorted(entry.split(":")[0] for entry in found) == ["App/Chat/ChatView.swift", "App/ChatView.swift"]


def test_the_flip_and_the_mirrored_inset_fail_everywhere(tmp_path):
    root = _tree(
        tmp_path,
        App__Chat__ChatTranscriptList_swift=COMPLIANT_LIST.replace("rows }", "rows }.contentMargins(.top, 4, for: .automatic)"),
        App__Platform__ChatPlatform_swift="func flip() { scaleEffect(x: 1, y: -1, anchor: .center) }\n",
    )
    found = _scan(root)
    assert len(found) == 2
    assert any(".contentMargins" in entry for entry in found) and any("flipped list" in entry for entry in found)


def test_scroll_position_is_allowed_once_and_only_in_the_transcript_list(tmp_path):
    twice = COMPLIANT_LIST.replace("            .defaultScrollAnchor", "            .scrollPosition($other)\n            .defaultScrollAnchor")
    found = _scan(_tree(tmp_path / "a", App__Chat__ChatTranscriptList_swift=twice))
    assert len(found) == 1 and "second .scrollPosition" in found[0]
    elsewhere = _tree(tmp_path / "b", App__Chat__ChatThing_swift="x.scrollPosition($p)\n")
    found = _scan(elsewhere)
    assert len(found) == 1 and ".scrollPosition outside ChatTranscriptList.swift" in found[0]


def test_the_controller_must_reference_the_machine(tmp_path):
    found = _scan(_tree(tmp_path, App__Chat__ChatScrollController_swift="final class ChatScrollController {}\n"))
    assert len(found) == 1 and "ChatScrollMachine" in found[0]


def test_content_offset_reads_are_only_for_the_controller_and_the_trace(tmp_path):
    reader = "let y = geometry.contentOffset.y\n"
    ok = _tree(tmp_path / "a", App__Chat__ChatScrollTrace_swift=reader)
    assert _scan(ok) == []
    found = _scan(_tree(tmp_path / "b", App__Chat__ChatRows_swift=reader))
    assert len(found) == 1 and found[0].startswith("App/Chat/ChatRows.swift:1:") and "contentOffset" in found[0]


def test_comments_and_strings_do_not_trip_the_rule(tmp_path):
    body = '// proxy.scrollTo(id)\nlet s = "scrollTo( contentOffset"\n'
    assert _scan(_tree(tmp_path, App__Chat__ChatRows_swift=body)) == []


def test_the_per_line_opt_out_does_not_apply(tmp_path):
    body = "func f() { proxy.scrollTo(id) } // chat-scroll: ok\n"
    assert len(_scan(_tree(tmp_path, App__Chat__ChatRows_swift=body))) == 1


def test_an_allowlist_entry_waives_its_needle_in_its_file_only(tmp_path):
    root = _tree(tmp_path, App__Chat__Suggest_swift="ScrollViewReader { proxy in proxy.scrollTo(id) }\n", App__Chat__Other_swift="proxy.scrollTo(id)\n")
    entry = "App/Chat/Suggest.swift:ScrollViewReader -- the suggestion list is not the transcript\n"
    found = _scan(root, entry)
    assert [e.split(":")[0] for e in found] == ["App/Chat/Other.swift"]


def test_an_allowlist_entry_without_a_reason_is_a_parse_error(tmp_path):
    root = _tree(tmp_path)
    for entry in ("App/Chat/Suggest.swift:ScrollViewReader\n", "App/Chat/Suggest.swift:ScrollViewReader -- \n", "nocolon -- reason\n"):
        found = _scan(root, entry)
        assert len(found) == 1 and "allowlist.txt:1:" in found[0], entry


def test_an_allowlist_entry_that_matches_nothing_fails(tmp_path):
    found = _scan(_tree(tmp_path), "App/Chat/Gone.swift:scrollTo( -- list removed\n")
    assert len(found) == 1 and "matches nothing" in found[0]


def test_comments_and_blank_lines_in_the_allowlist_are_ignored(tmp_path):
    assert _scan(_tree(tmp_path), "# header\n\n") == []


def test_the_shipped_allowlist_parses_with_reasons():
    waivers, errors = writer.parse_allowlist(writer.ALLOWLIST)
    assert errors == [] and all(w.reason for w in waivers)


def test_the_cli_exits_1_and_names_the_fix_on_a_failing_tree(tmp_path):
    root = _tree(tmp_path, App__Chat__ChatRows_swift="proxy.scrollTo(id)\n")
    run = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True, check=False)
    assert run.returncode == 1 and FIX in run.stdout


def test_a_tree_without_the_chat_code_has_nothing_to_judge(tmp_path):
    assert writer.main(["check", str(tmp_path)]) == 0

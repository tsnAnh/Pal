"""scripts/ci/check_swift_input_writes.py: typing never writes storage per keystroke, drafts have one writer, key handlers leave text inputs alone."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_input_writes.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_input_writes as iw

SCREEN = "App/Chat/Screen.swift"
DRAFT_STORE = "Packages/PalKit/Sources/PalChat/DraftStore.swift"
BOT_LINKS = "App/BotLinks.swift"


def _scan(tmp_path: Path, files: dict[str, str]):
    for name, body in files.items():
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return iw.scan(tmp_path)


def _rules(tmp_path: Path, files: dict[str, str]) -> list[str]:
    return [f.rule for f in _scan(tmp_path, files)]


def test_a_text_field_bound_straight_to_app_storage_fails(tmp_path):
    body = '@AppStorage("draft") private var saved = ""\nvar body: some View {\n    PalTextField("", text: $saved)\n}\n'
    found = _scan(tmp_path, {SCREEN: body})
    assert [(f.rule, f.line) for f in found] == [("input-direct-write", 3)]
    assert "DraftStore.update(text:botID:)" in found[0].message


def test_an_inline_binding_that_saves_per_keystroke_fails(tmp_path):
    body = (
        "var body: some View {\n"
        "    TextEditor(text: Binding(get: { note }, set: { note = $0; UserDefaults.standard.set($0, forKey: \"n\") }))\n"
        "}\n"
    )
    assert _rules(tmp_path, {SCREEN: body}) == ["input-direct-write"]


def test_inputs_bound_to_plain_state_or_secret_fields_pass(tmp_path):
    body = (
        '@AppStorage("token") private var token = ""\n'
        '@State private var draft = ""\n'
        "var body: some View {\n"
        '    PalTextField("", text: $draft)\n'
        '    SecureField("", text: $token)\n'
        '    SecretField("", text: $token)\n'
        "}\n"
    )
    assert _rules(tmp_path, {SCREEN: body}) == []


def test_the_input_write_directive_waives_a_direct_write(tmp_path):
    body = '@AppStorage("q") private var q = ""\nvar body: some View {\n    // input-write: ok\n    PalTextField("", text: $q)\n}\n'
    assert _rules(tmp_path, {SCREEN: body}) == []
    body = '@AppStorage("q") private var q = ""\nvar body: some View {\n    PalTextField("", text: $q) // input-write: ok\n}\n'
    assert _rules(tmp_path, {SCREEN: body}) == []


def test_a_second_draft_writer_fails(tmp_path):
    mirror = (
        "struct DraftMirror {\n"
        "    func save(_ draft: ComposerDraft, data: Data) throws {\n"
        '        let url = URL.applicationSupportDirectory.appending(path: "drafts")\n'
        "        try data.write(to: url)\n"
        "    }\n"
        "}\n"
    )
    found = _scan(tmp_path, {"App/DraftMirror.swift": mirror})
    assert {f.rule for f in found} == {"draft-second-writer"}
    assert {f.line for f in found} == {3, 4}


def test_constructing_or_encoding_drafts_outside_the_store_fails(tmp_path):
    cases = {
        "App/A.swift": "let store = DraftStore(directory: dir)\n",
        "App/B.swift": 'let d = dir.appendingPathComponent("drafts")\n',
        "App/C.swift": "let data = try JSONEncoder().encode(composerDraft)\nlet x: ComposerDraft? = nil\n",
        "App/D.swift": "let name = DraftStore.directoryName(botID: id)\n",
    }
    for name, body in cases.items():
        assert _rules(tmp_path / name[4], {name: body}) == ["draft-second-writer"], name


def test_the_store_itself_and_bot_links_may_own_drafts(tmp_path):
    store = 'struct DraftStore {\n    func flush(_ draft: ComposerDraft, to url: URL, data: Data) throws {\n        try data.write(to: url.appending(path: "drafts"))\n    }\n}\n'
    links = 'let store = DraftStore(directory: root.appending(path: "drafts"))\n'
    assert _rules(tmp_path, {DRAFT_STORE: store, BOT_LINKS: links}) == []


def test_draft_files_in_tests_are_not_scanned(tmp_path):
    body = "let store = DraftStore(directory: dir)\n"
    assert _rules(tmp_path, {"Tests/DraftTests.swift": body, "Packages/PalKit/Tests/PalKitTests/T.swift": body}) == []


def test_a_query_change_that_writes_defaults_fails(tmp_path):
    body = 'var body: some View {\n    list.onChange(of: query) { _, new in defaults.set(new, forKey: "q") }\n}\n'
    found = _scan(tmp_path, {SCREEN: body})
    assert [(f.rule, f.line) for f in found] == [("onchange-write-without-debounce", 2)]
    assert "debounce" in found[0].message


def test_a_width_change_that_calls_the_gateway_in_a_task_fails(tmp_path):
    body = 'list.onChange(of: sidebarWidth) { _, w in\n    Task { try await rpc.rpc("x", w) }\n}\n'
    assert _rules(tmp_path, {SCREEN: body}) == ["onchange-write-without-debounce"]


def test_a_write_to_an_app_storage_var_from_onchange_fails(tmp_path):
    body = '@AppStorage("s") private var stored = ""\nlist.onChange(of: model.searchText) { _, t in stored = t }\n'
    assert _rules(tmp_path, {SCREEN: body}) == ["onchange-write-without-debounce"]


def test_debounced_or_non_writing_onchange_handlers_pass(tmp_path):
    body = (
        "list.onChange(of: draft) { _, text in model.noteDraft(text) }\n"
        "list.onChange(of: draft) { _, t in store.update(text: t, botID: b) }\n"
        'list.onChange(of: query) { _, q in Task { try? await Task.sleep(for: .seconds(1)); defaults.set(q, forKey: "q") } }\n'
        'list.onChange(of: dragOffset) { _, o in if phase == .idle { defaults.set(o, forKey: "o") } }\n'
        'list.onChange(of: selection) { _, s in defaults.set(s, forKey: "s") }\n'
    )
    assert _rules(tmp_path, {SCREEN: body}) == []


def test_the_input_write_directive_waives_an_onchange_write(tmp_path):
    body = 'list.onChange(of: query) { _, new in\n    defaults.set(new, forKey: "q") // input-write: ok\n}\n'
    assert _rules(tmp_path, {SCREEN: body}) == []


def test_a_key_down_monitor_that_consumes_keys_without_a_text_input_check_fails(tmp_path):
    body = (
        "func install() {\n"
        "    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in\n"
        "        if event.keyCode == 53 { return nil }\n"
        "        return event\n"
        "    }\n"
        "}\n"
    )
    found = _scan(tmp_path, {"App/Mac/Keys.swift": body})
    assert [(f.rule, f.line) for f in found] == [("key-handler-steals-from-input", 2)]
    assert "TypeToFocus.insertion" in found[0].message


def test_a_catch_all_key_press_that_ignores_focus_fails(tmp_path):
    body = "var body: some View {\n    content.onKeyPress { _ in .handled }\n}\n"
    assert _rules(tmp_path, {SCREEN: body}) == ["key-handler-steals-from-input"]
    body = "var body: some View {\n    content.onKeyPress(phases: .down) { _ in\n        return .handled\n    }\n}\n"
    assert _rules(tmp_path, {SCREEN: body}) == ["key-handler-steals-from-input"]


def test_guarded_monitors_and_specific_or_focus_aware_key_handlers_pass(tmp_path):
    guarded = (
        "monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in\n"
        "    if window.firstResponder is NSText { return event }\n"
        "    return nil\n"
        "}\n"
    )
    inserted = (
        "monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in\n"
        "    guard TypeToFocus.insertion(characters: c, modifiers: m, textInputFocused: f, blocked: b) != nil else { return event }\n"
        "    return nil\n"
        "}\n"
    )
    mouse = "monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in return nil }\n"
    specific = "content.onKeyPress(.escape) { .handled }\ncontent.onKeyPress(.return, phases: .down) { _ in .handled }\n"
    focus = "@FocusState private var focused: Bool\ncontent.onKeyPress { _ in focused ? .ignored : .handled }\n"
    files = {
        "App/Mac/Guarded.swift": guarded,
        "App/Mac/Inserted.swift": inserted,
        "App/Mac/Mouse.swift": mouse,
        "App/Specific.swift": specific,
        "App/Focus.swift": focus,
    }
    assert _rules(tmp_path, files) == []


def test_the_key_steal_directive_waives_a_monitor_and_a_key_press(tmp_path):
    monitor = (
        "// key-steal: ok recording owns the keyboard\n"
        "monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in\n"
        "    return nil\n"
        "}\n"
    )
    press = "content.onKeyPress { _ in .handled } // key-steal: ok\n"
    assert _rules(tmp_path, {"App/Mac/Rec.swift": monitor, SCREEN: press}) == []


def test_comments_are_not_matched(tmp_path):
    body = '// PalTextField("", text: $saved)\n/* list.onChange(of: query) { _, q in defaults.set(q, forKey: "q") } */\n'
    assert _rules(tmp_path, {SCREEN: body}) == []


def test_package_sources_are_scanned_and_package_tests_are_not(tmp_path):
    body = 'list.onChange(of: query) { _, q in defaults.set(q, forKey: "q") }\n'
    assert _rules(tmp_path, {"Packages/PalKit/Sources/PalChat/X.swift": body}) == ["onchange-write-without-debounce"]
    assert _rules(tmp_path / "t", {"Packages/PalKit/Tests/PalKitTests/X.swift": body, "Tests/X.swift": body}) == []


def test_the_cli_exits_1_with_findings_and_0_when_clean(tmp_path):
    bad = tmp_path / "bad"
    _scan(bad, {SCREEN: 'list.onChange(of: query) { _, q in defaults.set(q, forKey: "q") }\n'})
    proc = subprocess.run([sys.executable, str(SCRIPT), str(bad)], capture_output=True, text=True, check=False)
    assert proc.returncode == 1 and "onchange-write-without-debounce" in proc.stdout
    good = tmp_path / "good"
    _scan(good, {SCREEN: "list.onChange(of: draft) { _, t in model.noteDraft(t) }\n"})
    proc = subprocess.run([sys.executable, str(SCRIPT), str(good)], capture_output=True, text=True, check=False)
    assert proc.returncode == 0 and proc.stdout == ""


def test_a_ternary_that_consumes_the_event_is_a_steal(tmp_path):
    body = "monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in\n    return handle(event) ? nil : event\n}\n"
    assert _rules(tmp_path, {"App/Mac/Rec.swift": body}) == ["key-handler-steals-from-input"]


def test_the_real_tree_has_no_findings():
    assert iw.scan(REPO / "apps" / "ios") == []

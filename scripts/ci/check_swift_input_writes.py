#!/usr/bin/env python3
"""Fail when typing writes storage per keystroke, drafts get a second writer, or a key handler steals keys from a text input.

A text input fires on every keystroke, so nothing it drives may write to disk or the network directly. Typing goes
through the debounced ``DraftStore.update(text:botID:)`` (``Packages/PalKit/Sources/PalChat/DraftStore.swift``) or
another debounced writer, which saves once on the pause.

Rules:

* input-direct-write: a ``TextField``, ``PalTextField``, ``TextEditor``, ``PalTextEditor`` or ``PalGlassTextField``
  whose ``text:`` is ``$name`` of an ``@AppStorage``/``@SceneStorage`` var of the same file, or an inline
  ``Binding(get:set:)`` whose setter calls ``UserDefaults``, ``defaults.set(``, ``.save(``, ``.write(to:`` or
  ``FileManager`` (``SecureField`` and ``SecretField`` are exempt: a secret goes to the keychain on submit);
* draft-second-writer: draft storage has one writer, ``DraftStore.swift``. Elsewhere: ``DraftStore(`` outside
  ``App/BotLinks.swift``, a ``"drafts"`` path component outside ``BotLinks.swift``, a ``JSONEncoder`` encoding a
  draft, ``.write(to:`` or ``FileManager`` in a file that names ``ComposerDraft`` or ``DraftAttachment``, and
  ``DraftStore.directoryName(``;
* onchange-write-without-debounce: ``.onChange(of:)`` or ``.onReceive(`` on a value that changes continuously
  (draft, text, query, search, width, height, offset, position, scroll, progress, slider, drag, translation, zoom,
  location, volume, level) whose action writes defaults, an ``@AppStorage`` var, a file, or the gateway, with no
  debounce (``.update(text:``, ``debounce``, ``Task.sleep``, ``.task(id:``, ``onEnded``, ``.idle``) in the action;
* key-handler-steals-from-input: under ``App/``, a ``.keyDown`` local event monitor that ``return nil``s (consumes
  the key, directly or as ``handled ? nil : event``) in a file with no text-input guard (``firstResponder is NSText``, ``NSTextInputClient`` or
  ``TypeToFocus.insertion(``), and a catch-all ``.onKeyPress`` that returns ``.handled`` in a file with no
  ``FocusState``/``focused``/``isFocused``.

A justified exception carries ``input-write: ok`` (the first three rules; draft-second-writer has none) or
``key-steal: ok`` on the flagged call, on a line inside it, or on the line above.

Run: python scripts/ci/check_swift_input_writes.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path

from check_swift_glass import SKIP_DIRS, Finding, Source

INPUT_OPT_OUT = "input-write: ok"
KEY_OPT_OUT = "key-steal: ok"
DRAFT_STORE = "Packages/PalKit/Sources/PalChat/DraftStore.swift"
BOT_LINKS = "App/BotLinks.swift"

ROUTE = ("route typing through the debounced DraftStore.update(text:botID:) (or another debounced writer) "
         "and save on the pause")
DIRECT_FIX = f"the input writes storage on every keystroke; {ROUTE}"
DRAFT_FIX = ("draft storage has one writer, Packages/PalKit/Sources/PalChat/DraftStore.swift (built once in "
             "App/BotLinks.swift); read and write drafts through it")
DEBOUNCE_FIX = ("the value changes continuously and this action writes it out each time; debounce it (pause, then "
                "write) or write at the end of the gesture")
KEY_FIX = ("leave keys alone when a text field or editor is first responder; use "
           "TypeToFocus.insertion(characters:modifiers:textInputFocused:blocked:)")

TEXT_INPUTS = ("TextField", "PalTextField", "TextEditor", "PalTextEditor", "PalGlassTextField")
STORAGE_VAR = re.compile(
    r"@(?:AppStorage|SceneStorage)\b(?:\([^\n]*\))?\s*(?:(?:private|fileprivate|public|internal)\s+)*var\s+(\w+)"
)
TEXT_ARG = re.compile(r"\btext:\s*\$(\w+)")
STORAGE_CALL = re.compile(r"UserDefaults|\bdefaults\.set\(|\.save\(|\.write\(to:|\bFileManager\b")

DRAFT_CONSTRUCT = re.compile(r"(?<![A-Za-z0-9_])DraftStore\(")
DRAFT_DIRECTORY_NAME = re.compile(r"(?<![A-Za-z0-9_])DraftStore\.directoryName\(")
DRAFTS_COMPONENT = re.compile(r'(?:appending\(path:|appendingPathComponent\()\s*"drafts"')
DRAFT_ENCODE = re.compile(r"\.encode\(\s*[^)\n]*[dD]raft")
DRAFT_TYPES = re.compile(r"\bComposerDraft\b|\bDraftAttachment\b")
FILE_WRITE = re.compile(r"\.write\(to:|\bFileManager\b")

OBSERVERS = re.compile(r"\.(onChange|onReceive)\(")
CONTINUOUS = ("draft", "text", "query", "search", "width", "height", "offset", "position", "scroll", "progress",
              "slider", "drag", "translation", "zoom", "location", "volume", "level")
WRITERS = re.compile(
    r"UserDefaults|\bdefaults\.set\(|\.save\(|\.write\(to:|\.rpc\(|URLSession|\.submit\(|\.send\("
)
DEBOUNCE = re.compile(r"\.update\(text:|debounce|Task\.sleep|\.task\(id:|onEnded|\.idle\b")

MONITOR = "NSEvent.addLocalMonitorForEvents"
MONITOR_MATCHING = re.compile(r"matching:\s*(\[[^\]]*\]|[.\w]+)")
CONSUMES = re.compile(r"\breturn\s+nil\b|\?\s*nil\s*:")
TEXT_INPUT_GUARD = re.compile(r"firstResponder\s+(?:is|as\?)\s+NSText\b|NSTextInputClient|TypeToFocus\.insertion\(")
KEY_PRESS = re.compile(r"\.onKeyPress\b")
SPECIFIC_KEY = re.compile(r"\s*(?:keys:|KeyEquivalent|\.|\[)")
HANDLED = re.compile(r"\.handled\b")
FOCUS_AWARE = re.compile(r"\bFocusState\b|\bfocused\b|\bisFocused\b")


def _waived(src: Source, marker: str, first: int, last: int) -> bool:
    return any(marker in line for line in src.original[max(0, first - 2):last])


def _first_argument_end(args: str) -> int:
    depth = 0
    for i, ch in enumerate(args):
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            return i
    return len(args)


def _direct_write(src: Source, rel: str):
    stored = set(STORAGE_VAR.findall(src.text))
    for name in TEXT_INPUTS:
        for start, open_index, end in src.calls(name):
            args = src.text[open_index:src.close[open_index] + 1]
            bound = TEXT_ARG.search(args)
            via_storage = bool(bound) and bound.group(1) in stored
            via_binding = any(
                STORAGE_CALL.search(src.text[b_open:src.close[b_open] + 1]) for _, b_open, _ in src.calls("Binding")
                if open_index < b_open < src.close[open_index]
            )
            first, last = src.line_of(start), src.line_of(end)
            if (via_storage or via_binding) and not _waived(src, INPUT_OPT_OUT, first, last):
                yield "input-direct-write", first, DIRECT_FIX


def _second_writer(src: Source, rel: str):
    text = src.text
    constructs = DRAFT_CONSTRUCT.finditer(text) if rel != BOT_LINKS else ()
    components = DRAFTS_COMPONENT.finditer(text) if rel != BOT_LINKS else ()
    for m in constructs:
        yield "draft-second-writer", src.line_of(m.start()), f"DraftStore built outside App/BotLinks.swift; {DRAFT_FIX}"
    for m in components:
        yield "draft-second-writer", src.line_of(m.start()), f"drafts directory path built outside DraftStore; {DRAFT_FIX}"
    for m in DRAFT_DIRECTORY_NAME.finditer(text):
        yield "draft-second-writer", src.line_of(m.start()), f"DraftStore.directoryName used outside DraftStore; {DRAFT_FIX}"
    if DRAFT_TYPES.search(text):
        for m in DRAFT_ENCODE.finditer(text):
            yield "draft-second-writer", src.line_of(m.start()), f"draft encoded outside DraftStore; {DRAFT_FIX}"
        for m in FILE_WRITE.finditer(text):
            yield "draft-second-writer", src.line_of(m.start()), f"file write in a file that handles drafts; {DRAFT_FIX}"


def _onchange_writes(src: Source, rel: str):
    stored = sorted(set(STORAGE_VAR.findall(src.text)), key=len, reverse=True)
    storage_write = (
        re.compile(
            r"(?<![\w.])(?:self\.)?_?(?:" + "|".join(map(re.escape, stored)) + r")\b(?:\.set\(|\.wrappedValue\s*=(?!=)|\s*=(?!=))"
        )
        if stored else None
    )
    for m in OBSERVERS.finditer(src.text):
        open_index = m.end() - 1
        if open_index not in src.close:
            continue
        end = src.end_of_call(open_index)
        args = src.text[open_index + 1:src.close[open_index]]
        cut = _first_argument_end(args)
        observed = re.sub(r"^\s*of:", "", args[:cut])
        names = re.findall(r"[A-Za-z_]\w*", observed)
        if not names or not any(word in names[-1].lower() for word in CONTINUOUS):
            continue
        action = src.text[open_index + 1 + cut:end + 1]
        writes = WRITERS.search(action) or (storage_write and storage_write.search(action))
        if not writes or DEBOUNCE.search(action):
            continue
        first, last = src.line_of(m.start()), src.line_of(end)
        if not _waived(src, INPUT_OPT_OUT, first, last):
            yield "onchange-write-without-debounce", first, DEBOUNCE_FIX


def _key_steals(src: Source, rel: str):
    if not rel.startswith("App/"):
        return
    guarded = bool(TEXT_INPUT_GUARD.search(src.text))
    for start, open_index, end in src.calls(MONITOR):
        call = src.text[start:end + 1]
        matching = MONITOR_MATCHING.search(call)
        if not (matching and ".keyDown" in matching.group(1) and CONSUMES.search(call)) or guarded:
            continue
        first, last = src.line_of(start), src.line_of(end)
        if not _waived(src, KEY_OPT_OUT, first, last):
            yield "key-handler-steals-from-input", first, f"keyDown monitor consumes keys with no text-input check; {KEY_FIX}"
    focus_aware = bool(FOCUS_AWARE.search(src.text))
    for m in KEY_PRESS.finditer(src.text):
        cursor = re.compile(r"\s*").match(src.text, m.end()).end()
        if cursor >= len(src.text) or src.text[cursor] not in "({" or cursor not in src.close:
            continue
        end = src.end_of_call(cursor) if src.text[cursor] == "(" else src.close[cursor]
        args = src.text[cursor + 1:src.close[cursor]] if src.text[cursor] == "(" else ""
        if SPECIFIC_KEY.match(args) or not HANDLED.search(src.text[cursor:end + 1]) or focus_aware:
            continue
        first, last = src.line_of(m.start()), src.line_of(end)
        if not _waived(src, KEY_OPT_OUT, first, last):
            yield "key-handler-steals-from-input", first, f"catch-all onKeyPress returns .handled in a file that never checks focus; {KEY_FIX}"


SCANNERS = (_direct_write, _second_writer, _onchange_writes, _key_steals)


def violations(rel: str, source: str) -> list[Finding]:
    src = Source(source)
    seen: set[tuple[str, int]] = set()
    found = []
    for scanner in SCANNERS:
        if scanner is _second_writer and rel == DRAFT_STORE:
            continue
        for rule, line, message in scanner(src, rel):
            if (rule, line) not in seen:
                seen.add((rule, line))
                found.append(Finding(rule, rel, line, src.original[line - 1].strip(), message))
    return found


def scoped_files(root: Path) -> list[Path]:
    files = []
    for path in sorted(root.rglob("*.swift")):
        parts = path.relative_to(root).parts
        in_app = parts[0] == "App"
        in_package = len(parts) > 3 and parts[0] == "Packages" and parts[2] == "Sources"
        if (in_app or in_package) and not SKIP_DIRS.intersection(parts):
            files.append(path)
    return files


def scan(root: Path) -> list[Finding]:
    found = []
    for path in scoped_files(root):
        found.extend(violations(path.relative_to(root).as_posix(), path.read_text(encoding="utf-8-sig")))
    return sorted(found, key=lambda f: (f.path, f.line, f.rule))


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for finding in found:
        print(finding.render())
    if found:
        counts = Counter(f.rule for f in found)
        print("\n" + ", ".join(f"{rule}: {n}" for rule, n in sorted(counts.items())))
        print(f"{len(found)} input write finding(s). {ROUTE}. A justified exception carries "
              f"'{INPUT_OPT_OUT}' (writes) or '{KEY_OPT_OUT}' (key handlers) on the line.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

"""scripts/ci/check_swift_mac_controls.py: icon-only Mac buttons carry a hover tooltip."""

from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts" / "ci"))

import check_swift_mac_controls as mcc

PRE_FIX = '''
                Button { filter.text = "" } label: {
                    PalIcon("xmark.circle.fill", ink: .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
                .accessibilityIdentifier("kanbanSearch-clear")
'''


def _found(source: str) -> list[str]:
    return mcc.violations(Path("App/Kanban/KanbanFilterBar.swift"), source)


def test_pre_fix_kanban_clear_button_is_flagged() -> None:
    assert len(_found(PRE_FIX)) == 1


def test_help_after_the_button_passes() -> None:
    fixed = PRE_FIX.replace('.accessibilityLabel(Text("Clear search"))', '.accessibilityLabel(Text("Clear search"))\n                .help(Text("Clear search"))')
    assert _found(fixed) == []


def test_text_labelled_and_titled_buttons_are_exempt() -> None:
    labelled = 'Button { go() } label: {\n    Text("Go")\n}\n.buttonStyle(.plain)\n'
    titled = 'Button("Go") { go() }\n'
    assert _found(labelled) == [] and _found(titled) == []


def test_ios_only_code_is_exempt() -> None:
    assert _found("#if os(iOS)\n" + PRE_FIX + "#endif\n") == []


def test_opt_out_waives_one_button() -> None:
    assert _found(PRE_FIX.replace("label: {", "label: { // mac-controls: ok")) == []


def test_main_tree_is_clean() -> None:
    assert mcc.scan(REPO / "apps" / "ios") == []

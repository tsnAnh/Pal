"""Find chat list jumps and button faults in a PAL_SCROLL_TRACE=1 CSV (pal-scroll-trace.csv, v1, v2 or v3).

Two kinds of jump, counted only while no user scroll is moving the list and no intended move
(jump to newest, send, find reveal) is settling:

* viewport: in following (v2: pinnedToBottom) mode the list leaves or re-enters the newest edge
  (distance changes by more than the threshold). Rows growing at the newest edge while distance
  stays put are intended.
* anchor: in reading (v2: readingHistory) mode the pinned row moves between two lines with the same
  pinned row. v1 (flipped list) measures it against the newest-edge inset line (pin_min_y - distance),
  v2 (top-down list) is pin_min_y itself.

v3 adds the writer of every offset change (user, machine:<command>, system-anchor, unattributed; inferred from the
trace, not read at the write) and the button state log: a button fault is a geo line whose distance is at or under the
hide distance while the jump button is up and the machine is not revealing a row.

v2 mode programmatic is an intended move and never a jump. A v2 machine line for jumpToNewest, send,
revealRow or revealRetry opens the settle window like a v1 jump/reveal write.

Run: python3 apps/ios/Tools/perf/scroll_trace.py TRACE.csv [--threshold 1.0] [--settle 0.4] [--hide-distance 24]
     [--max-jumps N] [--max-button-faults N]
"""

import argparse
import csv
import sys
from dataclasses import dataclass
from pathlib import Path

COLUMNS_V1 = (
    "epoch_s", "kind", "reason", "mode", "phase", "offset_y", "inset_top", "inset_bottom", "content_h",
    "container_h", "distance", "safe_top", "safe_bottom", "pin", "pin_min_y", "rows",
)
COLUMNS_V2 = COLUMNS_V1 + ("layout", "width", "event", "state", "command")
COLUMNS_V3 = COLUMNS_V2 + ("writer", "offset_delta", "at_bottom", "button", "user_scrolling")
USER_PHASES = frozenset({"interacting", "decelerating", "tracking"})
INTENDED = frozenset({"jump", "reveal", "reveal-retry"})
INTENDED_EVENTS = frozenset({"jumpToNewest", "send", "revealRow", "revealRetry"})
FOLLOWING = frozenset({"following", "pinnedToBottom"})
PROGRAMMATIC = "programmatic"
CAUSE_KINDS = frozenset({"write", "skip", "chrome", "rows", "machine"})
LOOKBACK_S = 0.25


class TraceError(ValueError):
    pass


@dataclass(frozen=True)
class Line:
    at: float
    kind: str
    reason: str
    mode: str
    phase: str
    distance: float | None
    content_h: float | None
    inset_top: float | None
    safe_bottom: float | None
    pin: str
    pin_min_y: float | None
    layout: str = "flipped"
    event: str = ""
    state: str = ""
    command: str = ""
    writer: str = ""
    offset_delta: float | None = None
    button: str = ""
    user_scrolling: str = ""

    @property
    def anchor(self) -> float | None:
        if self.pin_min_y is None:
            return None
        if self.layout == "top-down":
            return self.pin_min_y
        return None if self.distance is None else self.pin_min_y - self.distance

    @property
    def label(self) -> str:
        if self.kind == "machine":
            return f"machine:{self.event}->{self.command or '-'}"
        return f"{self.kind}:{self.reason or '-'}"


@dataclass(frozen=True)
class Jump:
    kind: str
    line: Line
    moved: float
    causes: tuple[Line, ...]

    def describe(self, start: float) -> str:
        changes = ", ".join(f"{c.label}@{c.at - start:.3f}s" for c in self.causes) or "none"
        return (
            f"{self.kind} t={self.line.at - start:.3f}s moved {self.moved:+.1f}pt mode={self.line.mode} "
            f"kind={self.line.kind} content_h={_show(self.line.content_h)} inset_top={_show(self.line.inset_top)} "
            f"safe_bottom={_show(self.line.safe_bottom)} writer={self.line.writer or '-'} preceding=[{changes}]"
        )


def _show(value: float | None) -> str:
    return "-" if value is None else f"{value:.1f}"


def _number(text: str) -> float | None:
    return float(text) if text else None


def parse(text: str) -> list[Line]:
    reader = csv.reader(text.splitlines())
    header = next(reader, None)
    columns = next((c for c in (COLUMNS_V3, COLUMNS_V2, COLUMNS_V1) if header is not None and tuple(header) == c), None)
    if columns is None:
        raise TraceError(
            f"not a scroll trace: expected header {','.join(COLUMNS_V1)} (v1), {','.join(COLUMNS_V2)} (v2) "
            f"or {','.join(COLUMNS_V3)} (v3)"
        )
    lines = []
    for number, row in enumerate(reader, start=2):
        if len(row) != len(columns):
            raise TraceError(f"line {number}: {len(row)} fields, expected {len(columns)}")
        field = dict(zip(columns, row))
        lines.append(Line(
            at=float(field["epoch_s"]), kind=field["kind"], reason=field["reason"], mode=field["mode"],
            phase=field["phase"], distance=_number(field["distance"]), content_h=_number(field["content_h"]),
            inset_top=_number(field["inset_top"]), safe_bottom=_number(field["safe_bottom"]), pin=field["pin"],
            pin_min_y=_number(field["pin_min_y"]), layout=field.get("layout", "flipped") or "flipped",
            event=field.get("event", ""), state=field.get("state", ""), command=field.get("command", ""),
            writer=field.get("writer", ""), offset_delta=_number(field.get("offset_delta", "")),
            button=field.get("button", ""), user_scrolling=field.get("user_scrolling", ""),
        ))
    return lines


def jumps(lines: list[Line], threshold: float = 1.0, settle: float = 0.4) -> list[Jump]:
    found = []
    intended_at = float("-inf")
    previous: Line | None = None
    for index, line in enumerate(lines):
        if (line.kind == "write" and line.reason in INTENDED) or (line.kind == "machine" and line.event in INTENDED_EVENTS):
            intended_at = line.at
        if line.distance is None:
            continue
        quiet = line.phase not in USER_PHASES and line.at - intended_at > settle
        if previous and quiet:
            move = _move(previous, line, threshold)
            if move:
                causes = tuple(
                    c for c in lines[:index]
                    if line.at - c.at <= LOOKBACK_S and c.kind in CAUSE_KINDS
                )
                found.append(Jump(kind=move[0], line=line, moved=move[1], causes=causes))
        previous = line
    return found


def _move(before: Line, after: Line, threshold: float) -> tuple[str, float] | None:
    if PROGRAMMATIC in (before.mode, after.mode):
        return None
    if after.mode in FOLLOWING:
        moved = after.distance - before.distance
        return ("viewport", moved) if abs(moved) > threshold else None
    if not after.pin or after.pin != before.pin or before.anchor is None or after.anchor is None:
        return None
    moved = after.anchor - before.anchor
    return ("anchor", moved) if abs(moved) > threshold else None


def button_faults(lines: list[Line], hide_distance: float = 24.0) -> list[Line]:
    return [
        line for line in lines
        if line.kind == "geo" and line.button == "1" and line.distance is not None
        and line.distance <= hide_distance and line.mode != PROGRAMMATIC
    ]


def writers(lines: list[Line]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for line in lines:
        if line.kind == "geo" and line.writer and line.writer != "none":
            counts[line.writer] = counts.get(line.writer, 0) + 1
    return dict(sorted(counts.items(), key=lambda item: -item[1]))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("trace", type=Path)
    parser.add_argument("--threshold", type=float, default=1.0, help="points of unasked movement that count as a jump")
    parser.add_argument("--settle", type=float, default=0.4, help="seconds an intended move may animate")
    parser.add_argument("--hide-distance", type=float, default=24.0, help="points from the bottom at or under which the jump button must be hidden")
    parser.add_argument("--max-jumps", type=int, default=None, help="exit 1 when more jumps than this are found")
    parser.add_argument("--max-button-faults", type=int, default=None, help="exit 1 when more button faults than this are found")
    args = parser.parse_args(argv)
    try:
        lines = parse(args.trace.read_text())
    except (OSError, TraceError) as error:
        print(f"scroll_trace: {error}", file=sys.stderr)
        return 2
    found = jumps(lines, args.threshold, args.settle)
    start = lines[0].at if lines else 0.0
    viewport = sum(1 for jump in found if jump.kind == "viewport")
    print(f"lines={len(lines)} jumps={len(found)} viewport={viewport} anchor={len(found) - viewport} threshold={args.threshold}pt")
    for jump in found:
        print("JUMP " + jump.describe(start))
    faults = button_faults(lines, args.hide_distance)
    print(f"button_faults={len(faults)} hide_distance={args.hide_distance}pt writers={writers(lines) or '-'}")
    for fault in faults:
        print(
            f"BUTTON t={fault.at - start:.3f}s distance={_show(fault.distance)} state={fault.mode} "
            f"user_scrolling={fault.user_scrolling or '-'} phase={fault.phase}"
        )
    failed = (args.max_jumps is not None and len(found) > args.max_jumps) or (
        args.max_button_faults is not None and len(faults) > args.max_button_faults
    )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

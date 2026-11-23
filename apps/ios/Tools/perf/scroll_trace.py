"""Find chat list jumps in a PAL_SCROLL_TRACE=1 CSV (pal-scroll-trace.csv).

Two kinds of jump, counted only while no user scroll is moving the list and no intended move
(jump to newest, find reveal) is settling:

* viewport: in following mode the list leaves or re-enters the newest edge (distance changes by
  more than the threshold). Rows growing at the newest edge while distance stays put are intended.
* anchor: in reading mode the pinned row moves relative to the newest-edge inset line
  (pin_min_y - distance) between two lines with the same pinned row.

Run: python3 apps/ios/Tools/perf/scroll_trace.py TRACE.csv [--threshold 1.0] [--settle 0.4] [--max-jumps N]
"""

import argparse
import csv
import sys
from dataclasses import dataclass
from pathlib import Path

COLUMNS = (
    "epoch_s", "kind", "reason", "mode", "phase", "offset_y", "inset_top", "inset_bottom", "content_h",
    "container_h", "distance", "safe_top", "safe_bottom", "pin", "pin_min_y", "rows",
)
USER_PHASES = frozenset({"interacting", "decelerating", "tracking"})
INTENDED = frozenset({"jump", "reveal", "reveal-retry"})
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

    @property
    def anchor(self) -> float | None:
        if self.pin_min_y is None or self.distance is None:
            return None
        return self.pin_min_y - self.distance


@dataclass(frozen=True)
class Jump:
    kind: str
    line: Line
    moved: float
    causes: tuple[Line, ...]

    def describe(self, start: float) -> str:
        changes = ", ".join(f"{c.kind}:{c.reason or '-'}@{c.at - start:.3f}s" for c in self.causes) or "none"
        return (
            f"{self.kind} t={self.line.at - start:.3f}s moved {self.moved:+.1f}pt mode={self.line.mode} "
            f"kind={self.line.kind} content_h={_show(self.line.content_h)} inset_top={_show(self.line.inset_top)} "
            f"safe_bottom={_show(self.line.safe_bottom)} preceding=[{changes}]"
        )


def _show(value: float | None) -> str:
    return "-" if value is None else f"{value:.1f}"


def _number(text: str) -> float | None:
    return float(text) if text else None


def parse(text: str) -> list[Line]:
    reader = csv.reader(text.splitlines())
    header = next(reader, None)
    if header is None or tuple(header) != COLUMNS:
        raise TraceError(f"not a scroll trace: expected header {','.join(COLUMNS)}")
    lines = []
    for number, row in enumerate(reader, start=2):
        if len(row) != len(COLUMNS):
            raise TraceError(f"line {number}: {len(row)} fields, expected {len(COLUMNS)}")
        field = dict(zip(COLUMNS, row))
        lines.append(Line(
            at=float(field["epoch_s"]), kind=field["kind"], reason=field["reason"], mode=field["mode"],
            phase=field["phase"], distance=_number(field["distance"]), content_h=_number(field["content_h"]),
            inset_top=_number(field["inset_top"]), safe_bottom=_number(field["safe_bottom"]), pin=field["pin"],
            pin_min_y=_number(field["pin_min_y"]),
        ))
    return lines


def jumps(lines: list[Line], threshold: float = 1.0, settle: float = 0.4) -> list[Jump]:
    found = []
    intended_at = float("-inf")
    previous: Line | None = None
    for index, line in enumerate(lines):
        if line.kind == "write" and line.reason in INTENDED:
            intended_at = line.at
        quiet = line.phase not in USER_PHASES and line.at - intended_at > settle
        if previous and quiet:
            move = _move(previous, line, threshold)
            if move:
                causes = tuple(
                    c for c in lines[:index]
                    if line.at - c.at <= LOOKBACK_S and c.kind in {"write", "skip", "chrome", "rows"}
                )
                found.append(Jump(kind=move[0], line=line, moved=move[1], causes=causes))
        previous = line
    return found


def _move(before: Line, after: Line, threshold: float) -> tuple[str, float] | None:
    if after.mode == "following":
        if before.distance is None or after.distance is None:
            return None
        moved = after.distance - before.distance
        return ("viewport", moved) if abs(moved) > threshold else None
    if not after.pin or after.pin != before.pin or before.anchor is None or after.anchor is None:
        return None
    moved = after.anchor - before.anchor
    return ("anchor", moved) if abs(moved) > threshold else None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("trace", type=Path)
    parser.add_argument("--threshold", type=float, default=1.0, help="points of unasked movement that count as a jump")
    parser.add_argument("--settle", type=float, default=0.4, help="seconds an intended move may animate")
    parser.add_argument("--max-jumps", type=int, default=None, help="exit 1 when more jumps than this are found")
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
    return 1 if args.max_jumps is not None and len(found) > args.max_jumps else 0


if __name__ == "__main__":
    sys.exit(main())

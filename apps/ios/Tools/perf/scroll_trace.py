"""Find chat list jumps in a PAL_SCROLL_TRACE=1 CSV (pal-scroll-trace.csv).

A jump is a change of the pinned row's position relative to the newest-edge inset line
(pin_min_y - distance) between two consecutive lines, larger than the threshold, while no user
scroll is moving the list and no intended move (jump to newest, find reveal) is settling.

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
    line: Line
    moved: float
    causes: tuple[Line, ...]

    def describe(self, start: float) -> str:
        changes = ", ".join(f"{c.kind}:{c.reason or '-'}@{c.at - start:.3f}s" for c in self.causes) or "none"
        return (
            f"t={self.line.at - start:.3f}s moved {self.moved:+.1f}pt mode={self.line.mode} "
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
        if previous and quiet and line.pin and line.pin == previous.pin:
            before, after = previous.anchor, line.anchor
            if before is not None and after is not None and abs(after - before) > threshold:
                causes = tuple(
                    c for c in lines[:index]
                    if line.at - c.at <= LOOKBACK_S and c.kind in {"write", "skip", "chrome", "rows"}
                )
                found.append(Jump(line=line, moved=after - before, causes=causes))
        previous = line
    return found


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
    print(f"lines={len(lines)} jumps={len(found)} threshold={args.threshold}pt")
    for jump in found:
        print("JUMP " + jump.describe(start))
    return 1 if args.max_jumps is not None and len(found) > args.max_jumps else 0


if __name__ == "__main__":
    sys.exit(main())

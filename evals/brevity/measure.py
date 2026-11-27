from __future__ import annotations

import argparse
import json
import os
import sys
import time
from collections import Counter
from collections.abc import Callable, Sequence
from contextlib import redirect_stdout
from dataclasses import dataclass
from enum import Enum
from itertools import pairwise
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from evals.intent.baseline import DAY, bot_reports, exit_status, fraction, profile_targets, window, window_days
from evals.intent.transcripts import Conversation, read_conversations
from gateway.session_timeline_entries import Opener, opener_of, reply_entries, timeline_entries
from persistence.conversation.messages import TranscriptRow
from session_rules.turns import sanitize_context

SCHEMA = "brevity-measure/1"
VIEWS: tuple[tuple[str, Callable], ...] = (("stored", reply_entries), ("shown", timeline_entries))
BUCKETS = ("0", "1", "2", "3+")
_ROW_KEYS = ("role", "tool_call_id", "tool_calls", "tool_name", "timestamp", "display_kind", "display_metadata",
             "message_uid", "effect_disposition", "finish_reason", "reasoning", "reasoning_content")
_JSON_KEYS = ("reasoning_details", "codex_reasoning_items", "codex_message_items")


class Origin(Enum):
    SAME_TURN = "same_turn"
    NOTICE_TURN = "notice_turn"
    OTHER_TURN = "other_turn"


@dataclass(frozen=True, slots=True)
class Bubble:
    start: int
    end: int
    words: int


@dataclass(frozen=True, slots=True)
class Tally:
    turns: tuple[tuple[tuple[Bubble, Origin | None], ...], ...]
    before_first_owner: int


def _projection_row(row: TranscriptRow) -> dict:
    stored = row.as_wire_row()
    shaped = {key: stored[key] for key in _ROW_KEYS if stored[key] not in (None, "")}
    shaped.update((key, json.loads(stored[key])) for key in _JSON_KEYS if stored[key])
    content = row.content
    if row.role in ("user", "assistant") and isinstance(content, str):
        content = sanitize_context(content).strip()
    return {**shaped, "content": content, "_row_id": int(row.id)}


def projection_rows(conversation: Conversation) -> list[dict]:
    return [_projection_row(row) for row in conversation.rows]


def _bubbles(entries: Sequence[dict], positions: dict[str, int], row_positions: dict[int, int]) -> list[Bubble]:
    found = []
    for entry in entries:
        if entry["role"] != "assistant" or not entry["text"].strip():
            continue
        key = entry["id"] if entry["id"] in positions else entry["id"].rpartition("#")[0]
        start = positions[key]
        found.append(Bubble(start, row_positions.get(entry.get("row_id"), start), len(entry["text"].split())))
    return found


def _origin(before: Bubble, bubble: Bubble, openers: Sequence[tuple[int, Opener]]) -> Origin:
    between = [opener for position, opener in openers if before.end < position <= bubble.start]
    if not between:
        return Origin.SAME_TURN
    return Origin.NOTICE_TURN if between[-1] is Opener.NOTICE else Origin.OTHER_TURN


def _tally(entries: Sequence[dict], rows: Sequence[dict]) -> Tally:
    positions: dict[str, int] = {}
    for index, row in enumerate(rows):
        positions.setdefault(row.get("message_uid") or f"r:{row['_row_id']}", index)
    row_positions = {row["_row_id"]: index for index, row in enumerate(rows)}
    openers = [(index, opener_of(row)) for index, row in enumerate(rows) if row["role"] == "user"]
    starts = [index for index, opener in openers if opener is Opener.OWNER]
    bubbles = _bubbles(entries, positions, row_positions)
    turns = []
    for start, stop in pairwise([*starts, len(rows)]):
        inside = [bubble for bubble in bubbles if start < bubble.start < stop]
        origins = [None, *(_origin(before, bubble, openers) for before, bubble in pairwise(inside))]
        turns.append(tuple(zip(inside, origins)))
    first = starts[0] if starts else len(rows)
    return Tally(tuple(turns), sum(bubble.start < first for bubble in bubbles))


def _percentile(values: Sequence[int], percent: int) -> int | None:
    ordered = sorted(values)
    return ordered[-(-percent * len(ordered) // 100) - 1] if ordered else None


def _view(tallies: Sequence[Tally]) -> dict:
    turns = [turn for tally in tallies for turn in tally.turns]
    sizes = [len(turn) for turn in turns]
    bubbles = [bubble for turn in turns for bubble, _ in turn]
    origins = Counter(origin for turn in turns for _, origin in turn if origin)
    buckets = Counter(BUCKETS[min(size, len(BUCKETS) - 1)] for size in sizes)
    consecutive = sum(origins.values())
    words = [bubble.words for bubble in bubbles]
    return {
        "owner_turns": len(turns),
        "bubbles": len(bubbles),
        "bubbles_before_first_owner": sum(tally.before_first_owner for tally in tallies),
        "turns_by_bubbles": {name: buckets[name] for name in BUCKETS},
        "bubbles_per_owner_turn": {
            "mean": round(len(bubbles) / len(turns), 2) if turns else None,
            "p50": _percentile(sizes, 50), "p90": _percentile(sizes, 90)},
        "consecutive": {
            **fraction(consecutive, len(bubbles)),
            "by_origin": {origin.value: fraction(origins[origin], consecutive) for origin in Origin}},
        "words_per_bubble": {"p50": _percentile(words, 50), "p90": _percentile(words, 90)},
    }


def _profile(home: Path, since: float, scratch: Path) -> dict:
    read = read_conversations(home, since)
    tallies: dict[str, list[Tally]] = {name: [] for name, _ in VIEWS}
    for conversation in read.conversations:
        rows = projection_rows(conversation)
        for name, project in VIEWS:
            tallies[name].append(_tally(project(rows, conversation.live_ids, str(scratch)), rows))
    return {
        "status": "ok",
        "conversations": len(read.conversations),
        "counted_sources": dict(sorted(Counter(item.source for item in read.conversations).items())),
        "skipped_sessions": dict(read.skipped),
        "views": {name: _view(found) for name, found in tallies.items()},
    }


def measure(targets: Sequence[tuple[str, Path]], *, days: int, now: float) -> dict:
    since = now - days * DAY
    # The projection imports tui_gateway.server, which points sys.stdout at stderr; this restores it.
    with open(os.devnull, "w", encoding="utf-8") as sink, redirect_stdout(sink):
        bots = bot_reports(targets, lambda home, scratch: _profile(home, since, scratch))
    return {"schema": SCHEMA, "window": window(days, now), "bots": bots}


_TABLE: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("owner turns", ("owner_turns",)),
    ("bubbles", ("bubbles",)),
    ("bubbles before first owner turn", ("bubbles_before_first_owner",)),
    *((f"turns with {name} bubbles", ("turns_by_bubbles", name)) for name in BUCKETS),
    ("bubbles per owner turn, mean", ("bubbles_per_owner_turn", "mean")),
    ("bubbles per owner turn, p50", ("bubbles_per_owner_turn", "p50")),
    ("bubbles per owner turn, p90", ("bubbles_per_owner_turn", "p90")),
    ("consecutive bubbles", ("consecutive", "count")),
    ("consecutive share of bubbles", ("consecutive", "share")),
    *((f"  {origin.value}", ("consecutive", "by_origin", origin.value, "count")) for origin in Origin),
    *((f"  {origin.value} share", ("consecutive", "by_origin", origin.value, "share")) for origin in Origin),
    ("words per bubble, p50", ("words_per_bubble", "p50")),
    ("words per bubble, p90", ("words_per_bubble", "p90")),
)


def _cell(view: dict, path: tuple[str, ...]) -> str:
    value: object = view
    for key in path:
        value = value[key]
    if value is None:
        return "-"
    return f"{value:.1%}" if path[-1] == "share" else str(value)


def _row(label: str, cells: Sequence[str]) -> str:
    return f"{label:<34}" + "".join(f"{cell:>9}" for cell in cells)


def _table(name: str, bot: dict) -> list[str]:
    if bot["status"] != "ok":
        return [f"== {name}: {bot['status']} {bot.get('error', '')}".rstrip()]
    names = [view for view, _ in VIEWS]
    return [f"== {name} ({bot['conversations']} conversations)", _row("metric", names),
            *(_row(label, [_cell(bot["views"][view], path) for view in names]) for label, path in _TABLE)]


def render(report: dict, *, json_only: bool = False) -> str:
    document = json.dumps(report, indent=1)
    if json_only:
        return document
    tables = [line for name, bot in report["bots"].items() for line in _table(name, bot)]
    return "\n".join([document, "", f"window: last {report['window']['days']} days", *tables])


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python evals/brevity/measure.py",
        description="Read-only counts of reply bubbles per owner turn, as stored and as shown. Prints counts only.")
    parser.add_argument("--profile", help="measure one profile (default: every served profile)")
    parser.add_argument("--days", type=window_days, default=1, help="window in days (default: 1)")
    parser.add_argument("--json", action="store_true", help="print the JSON report without the table")
    args = parser.parse_args(argv)
    targets = profile_targets(args.profile)
    if targets is None:
        return 2
    report = measure(targets, days=args.days, now=time.time())
    print(render(report, json_only=args.json))
    return exit_status(report)


if __name__ == "__main__":
    raise SystemExit(main())

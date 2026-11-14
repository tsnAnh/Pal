import json
import random

from perf_corpus import (
    Row, TOOL_NAMES, assistant_markdown, build_corpus, code_block, paragraph, sentence, tool_arguments, tool_result,
)

MARKER = "⟦{:04d}⟧"
SYSTEM_NOTES = (
    "You are Hermes. Follow the profile instructions and keep answers short.",
    "Context window compacted; earlier turns were summarised for the model.",
)
NOTIFICATIONS = (
    "Background process proc_{n} finished: nightly export completed in 41s.",
    "Scheduled routine 'weekly summary' delivered its result.",
)
HIDDEN_OPENERS = (
    "Continue where you left off and report anything that changed.",
    "Check your inbox and handle anything urgent without asking me.",
)
DEAD_ZONE_ROWS = 130


def tall_markdown(rng):
    parts = [paragraph(rng, 6) for _ in range(rng.randint(14, 24))]
    parts.insert(rng.randint(1, len(parts) - 1), code_block(rng) + "\n" + code_block(rng) + "\n" + code_block(rng))
    parts.insert(rng.randint(1, len(parts) - 1), "\n".join(f"{i}. {sentence(rng, 6, 14)}" for i in range(1, 41)))
    return "\n\n".join(parts)


def pasted_log(rng):
    lines = [f"[{rng.randint(10, 23)}:{rng.randint(10, 59)}:{rng.randint(10, 59)}] {sentence(rng, 5, 12)}" for _ in range(rng.randint(120, 260))]
    return "Here is the full log, what went wrong?\n\n" + "\n".join(lines)


def tool_chain(rng, ids, rounds):
    rows = []
    for _ in range(rounds):
        names = [rng.choice(TOOL_NAMES) for _ in range(rng.choice((2, 3, 4)))]
        batch = []
        for name in names:
            ids[0] += 1
            batch.append({"id": f"call_{ids[0]:06d}", "type": "function", "function": {"name": name, "arguments": json.dumps(tool_arguments(rng, name))}})
        rows.append(Row("assistant", "", tool_calls=batch, kind="tool_calls"))
        for call in batch:
            name = call["function"]["name"]
            rows.append(Row("tool", tool_result(rng, name, rng.random() < 0.3), tool_call_id=call["id"], tool_name=name, kind="tool"))
    return rows


def classify(row):
    if row.role == "tool":
        return "tool"
    if row.role == "system":
        return "hidden"
    if row.role == "assistant":
        return "visible" if isinstance(row.content, str) and row.content.strip() else "hidden"
    if row.display_kind == "hidden":
        return "hidden"
    if row.display_kind == "internal_notification":
        return "notice"
    return "visible"


def stamp(row, index):
    marker = MARKER.format(index)
    if isinstance(row.content, str):
        if row.content.strip():
            row.content = marker + " " + row.content
    elif isinstance(row.content, list):
        for part in row.content:
            if part.get("type") == "text":
                part["text"] = marker + " " + part["text"]


def build_rich_corpus(total_rows, seed, now, images_dir):
    rng = random.Random(seed + 1)
    base = build_corpus(max(10, int(total_rows * 0.8)), seed, now, images_dir)
    ids = [10_000_000]
    dead_zone_at = int(len(base.rows) * 0.45)
    out = []
    for position, row in enumerate(base.rows):
        starts_turn = row.role == "user" and (not out or out[-1].role in ("assistant", "system"))
        if position == dead_zone_at and row.role == "user":
            out.extend(tool_chain(rng, ids, DEAD_ZONE_ROWS // 10))
        elif position == dead_zone_at:
            dead_zone_at += 1
        if starts_turn:
            roll = rng.random()
            if roll < 0.04:
                out.append(Row("system", rng.choice(SYSTEM_NOTES), kind="system"))
            elif roll < 0.09:
                out.append(Row("user", rng.choice(NOTIFICATIONS).format(n=rng.randint(100, 999)), kind="notification", display_kind="internal_notification"))
                out.append(Row("assistant", assistant_markdown(rng)))
            elif roll < 0.13:
                out.append(Row("user", rng.choice(HIDDEN_OPENERS), kind="hidden_user", display_kind="hidden"))
            if row.kind == "text" and rng.random() < 0.012:
                row.content = pasted_log(rng)
                row.kind = "tall_user"
        out.append(row)
        if row.role == "user" and rng.random() < 0.05:
            out.extend(tool_chain(rng, ids, rng.choice((2, 3, 4))))
        if row.role == "assistant" and isinstance(row.content, str) and row.content and row.kind == "text":
            if rng.random() < 0.4:
                row.reasoning = paragraph(rng, rng.randint(3, 7))
            if rng.random() < 0.015:
                row.content = tall_markdown(rng)
                row.kind = "tall_assistant"
    out = out[:total_rows]
    while len(out) < total_rows:
        out.append(Row("assistant", assistant_markdown(rng)))
    base.rows = out
    gaps = (20, 45, 90, 300, 1500)
    clock = now - 90 - sum(rng.choice(gaps) for _ in out)
    for index, row in enumerate(out):
        clock += rng.choice(gaps)
        row.timestamp = clock
        stamp(row, index)
    base.manifest = [
        {"index": index, "marker": MARKER.format(index), "role": row.role, "kind": row.kind, "expect": classify(row),
         "display_kind": row.display_kind, "chars": len(row.content) if isinstance(row.content, str) else 0,
         "head": row.content[len(MARKER.format(index)) + 1:][:80] if isinstance(row.content, str) and row.content.strip() else ""}
        for index, row in enumerate(out)
    ]
    return base

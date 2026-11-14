import base64
import io
import json
import random
from dataclasses import dataclass, field

WORDS = (
    "build release gateway session profile cache render payload latency thread socket decode "
    "transcript message review deploy rollback metric budget invoice customer roster listing "
    "keyword creative schedule routine summary report ticket branch commit pipeline artifact "
    "simulator device keychain token refresh retry timeout queue worker bucket index query "
    "migration schema column table backup restore monitor alert incident postmortem owner "
    "estimate priority backlog sprint feature flag rollout metric dashboard export import"
).split()

TOPICS = (
    "the App Store listing", "the nightly build", "the invoice batch", "the roster refresh", "the Upwork proposals",
    "the review queue", "the gateway restart", "the creative brief", "the keyword report", "the cron schedule",
    "the migration plan", "the crash report", "the weekly summary", "the release notes", "the onboarding flow",
)

USER_OPENERS = (
    "Can you check {topic} and tell me what is blocking it?",
    "Quick one: what is the status of {topic}?",
    "Please draft a short update about {topic} I can forward.",
    "I need {topic} sorted before tomorrow morning. Where are we?",
    "Look at {topic} again, something still looks off to me.",
    "Summarise {topic} in a few bullets, then list what you would do next.",
    "Why did {topic} take so long last time? Dig into the logs.",
    "Compare {topic} with what we did last week and flag any regression.",
)

USER_FOLLOWUPS = (
    "ok and what about the second part?",
    "thanks, now make it shorter",
    "do it",
    "can you also double check the numbers",
    "sounds good, go ahead and run it",
    "no, use the other branch",
    "why that one?",
    "perfect. next one please",
)

GAPS = (20, 45, 90, 300, 1500)

TOOL_NAMES = ("terminal", "read_file", "search_files", "web_extract", "patch", "write_file", "web_search")


@dataclass
class Row:
    role: str
    content: object
    timestamp: float = 0.0
    tool_calls: list | None = None
    tool_call_id: str | None = None
    tool_name: str | None = None
    kind: str = "text"


@dataclass
class Corpus:
    rows: list = field(default_factory=list)
    files: dict = field(default_factory=dict)
    images: int = 0
    inline_images: int = 0
    image_bytes: int = 0


def sentence(rng, low=6, high=16):
    words = [rng.choice(WORDS) for _ in range(rng.randint(low, high))]
    return words[0].capitalize() + " " + " ".join(words[1:]) + "."


def paragraph(rng, sentences=None):
    return " ".join(sentence(rng) for _ in range(sentences or rng.randint(2, 5)))


def bullet_list(rng):
    return "\n".join(f"- **{rng.choice(WORDS)}** {sentence(rng, 4, 10)}" for _ in range(rng.randint(3, 7)))


def code_block(rng):
    lang = rng.choice(("python", "swift", "bash", "json", "yaml"))
    lines = [f"{rng.choice(WORDS)}_{rng.choice(WORDS)} = {rng.randint(1, 9999)}" for _ in range(rng.randint(4, 18))]
    return f"```{lang}\n" + "\n".join(lines) + "\n```"


def table(rng):
    rows = [f"| {rng.choice(WORDS)} | {rng.randint(1, 900)} ms | {rng.randint(1, 99)}% |" for _ in range(rng.randint(3, 7))]
    return "| Step | Time | Share |\n| --- | --- | --- |\n" + "\n".join(rows)


def assistant_markdown(rng, long_form=False):
    parts = [paragraph(rng)]
    for _ in range(rng.randint(1, 4) if long_form else rng.randint(0, 2)):
        parts.append(rng.choice((bullet_list, code_block, table, paragraph))(rng))
    if rng.random() < 0.2:
        parts.append(f"See [the dashboard](https://example.com/{rng.choice(WORDS)}/{rng.randint(100, 999)}) for the raw numbers.")
    if rng.random() < 0.3:
        parts.insert(0, f"## {rng.choice(WORDS).capitalize()} {rng.choice(WORDS)}")
    return "\n\n".join(parts)


def tool_result(rng, name, large):
    if name == "read_file":
        lines = rng.randint(180, 700) if large else rng.randint(8, 40)
        return "\n".join(f"{index + 1:>5}\t{rng.choice(WORDS)}_{rng.choice(WORDS)} = {sentence(rng, 3, 9)}" for index in range(lines))
    if name == "web_extract":
        count = rng.randint(30, 90) if large else rng.randint(2, 8)
        return "\n\n".join(paragraph(rng, rng.randint(2, 4)) for _ in range(count))
    if name == "search_files":
        count = rng.randint(60, 220) if large else rng.randint(2, 12)
        return json.dumps({"matches": [{"path": f"src/{rng.choice(WORDS)}/{rng.choice(WORDS)}.py", "line": rng.randint(1, 900), "text": sentence(rng, 4, 12)} for _ in range(count)]})
    if name == "patch":
        return json.dumps({"success": True, "diff": "\n".join(f"{rng.choice('+- ')}{sentence(rng, 3, 10)}" for _ in range(rng.randint(6, 40)))})
    if name == "write_file":
        return json.dumps({"bytes_written": rng.randint(200, 9000), "dirs_created": False})
    if name == "web_search":
        return json.dumps({"results": [{"title": sentence(rng, 3, 6), "url": f"https://example.com/{rng.choice(WORDS)}", "snippet": sentence(rng, 10, 24)} for _ in range(rng.randint(4, 10))]})
    count = rng.randint(120, 420) if large else rng.randint(2, 30)
    return "\n".join(f"[{rng.randint(10, 23)}:{rng.randint(10, 59)}:{rng.randint(10, 59)}] {rng.choice(WORDS)} {sentence(rng, 4, 12)}" for _ in range(count))


def tool_arguments(rng, name):
    if name in ("read_file", "write_file", "patch"):
        return {"path": f"src/{rng.choice(WORDS)}/{rng.choice(WORDS)}.py"}
    if name == "search_files":
        return {"pattern": rng.choice(WORDS), "path": "."}
    if name in ("web_extract", "web_search"):
        return {"query": sentence(rng, 3, 7)} if name == "web_search" else {"urls": [f"https://example.com/{rng.choice(WORDS)}"]}
    return {"command": f"{rng.choice(('grep -rn', 'ls -la', 'git log --oneline', 'cat'))} {rng.choice(WORDS)}"}


def photo_jpeg(index):
    from PIL import Image

    noise = random.Random(7000 + index)
    width, height = 1280, 960
    tile = bytes(noise.randrange(256) for _ in range(64 * 64 * 3))
    base = Image.frombytes("RGB", (64, 64), tile).resize((width, height), Image.BICUBIC)
    gradient = Image.linear_gradient("L").resize((width, height))
    photo = Image.composite(base, Image.new("RGB", (width, height), (40 + index * 17 % 180, 90, 140)), gradient)
    buffer = io.BytesIO()
    photo.save(buffer, "JPEG", quality=78)
    return buffer.getvalue()


def tool_turn(rng, user_text, rows, ids):
    rows.append(Row("user", user_text))
    for _round in range(rng.choice((1, 1, 1, 2))):
        calls = [rng.choice(TOOL_NAMES) for _ in range(rng.choice((1, 1, 2, 3)))]
        batch = []
        for name in calls:
            ids[0] += 1
            batch.append({"id": f"call_{ids[0]:06d}", "type": "function", "function": {"name": name, "arguments": json.dumps(tool_arguments(rng, name))}})
        lead = "" if rng.random() < 0.5 else sentence(rng, 5, 12)
        rows.append(Row("assistant", lead, tool_calls=batch, kind="tool_calls"))
        for call in batch:
            name = call["function"]["name"]
            large = name in ("read_file", "web_extract", "search_files", "terminal") and rng.random() < 0.4
            rows.append(Row("tool", tool_result(rng, name, large), tool_call_id=call["id"], tool_name=name, kind="tool_large" if large else "tool"))
    rows.append(Row("assistant", assistant_markdown(rng, long_form=True)))


def plain_turn(rng, user_text, rows):
    rows.append(Row("user", user_text))
    rows.append(Row("assistant", assistant_markdown(rng, long_form=rng.random() < 0.3)))


def build_corpus(total_rows, seed, now, images_dir):
    rng = random.Random(seed)
    corpus = Corpus()
    rows = corpus.rows
    ids = [0]
    wanted_images = max(3, total_rows // 250)
    wanted_inline = max(1, total_rows // 1000)
    slots = range(4, max(5 + wanted_images + wanted_inline, total_rows // 4))
    chosen = rng.sample(slots, wanted_images + wanted_inline)
    inline_turns, image_turns = set(chosen[:wanted_inline]), set(chosen[wanted_inline:])
    turn_index = 0
    while len(rows) < total_rows:
        remaining = total_rows - len(rows)
        user_text = rng.choice(USER_OPENERS).format(topic=rng.choice(TOPICS)) if rng.random() < 0.6 else rng.choice(USER_FOLLOWUPS)
        if remaining == 1:
            rows.append(Row("assistant", assistant_markdown(rng)))
        elif turn_index in image_turns or turn_index in inline_turns:
            jpeg = photo_jpeg(corpus.images + corpus.inline_images)
            corpus.image_bytes += len(jpeg)
            if turn_index in inline_turns:
                corpus.inline_images += 1
                uri = "data:image/jpeg;base64," + base64.b64encode(jpeg).decode()
                parts = [{"type": "text", "text": "What do you make of this screenshot?"}, {"type": "image_url", "image_url": {"url": uri}}]
                rows.append(Row("user", parts, kind="inline_image"))
            else:
                path = images_dir / f"pal_perf_{corpus.images}.jpg"
                corpus.files[path] = jpeg
                corpus.images += 1
                rows.append(Row("user", f"What do you make of this screenshot?\n\n[Image attached at: {path}]", kind="image"))
            rows.append(Row("assistant", assistant_markdown(rng)))
        else:
            before = len(rows)
            if remaining >= 10 and rng.random() < 0.55:
                tool_turn(rng, user_text, rows, ids)
            if len(rows) == before or len(rows) > total_rows:
                del rows[before:]
                plain_turn(rng, user_text, rows)
        turn_index += 1
    clock = now - 90 - sum(rng.choice(GAPS) for _ in rows)
    for row in rows:
        clock += rng.choice(GAPS)
        row.timestamp = clock
    return corpus


def describe(corpus):
    counts = {}
    for row in corpus.rows:
        counts[row.kind] = counts.get(row.kind, 0) + 1
    text_bytes = sum(len(row.content) for row in corpus.rows if isinstance(row.content, str))
    return {
        "rows": len(corpus.rows), "kinds": counts, "text_bytes": text_bytes, "path_images": corpus.images,
        "inline_data_uri_images": corpus.inline_images, "image_bytes": corpus.image_bytes,
    }

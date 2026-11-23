import argparse
import asyncio
import importlib.util
import json
import os
import sys
import uuid
from collections import namedtuple
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

PRIMARY_SLUG = "default"
BOT_CHAT_TITLE = "Bot Chat"
BOT_META_KEY = "hermes-bots"
SESSION_SOURCE = "gui"
HOME_MARKER = "hermes-ios-e2e."
REPLY_GAP = timedelta(minutes=2)
EXCHANGE_GAP = timedelta(minutes=25)


@dataclass(frozen=True)
class Look:
    shape: str
    color: str


@dataclass(frozen=True)
class Recency:
    days_back: int = 0
    clock: str = ""
    minutes_ago: int = 0

    def resolve(self, now):
        if not self.clock:
            return now - timedelta(minutes=self.minutes_ago)
        hour, minute = map(int, self.clock.split(":"))
        return (now - timedelta(days=self.days_back)).replace(hour=hour, minute=minute, second=0, microsecond=0)


@dataclass(frozen=True)
class Turn:
    role: str
    text: str
    gap_before: timedelta | None = None
    display_kind: str | None = None


def as_turn(entry):
    return entry if isinstance(entry, Turn) else Turn(role=entry[0], text=entry[1])


@dataclass(frozen=True)
class Routine:
    title: str
    prompt: str
    schedule: str


@dataclass(frozen=True)
class Shared:
    role: str
    text: str
    days_back: int
    clock: str = "10:15"
    media: str = ""


@dataclass(frozen=True)
class Bot:
    slug: str
    title: str
    look: Look | None
    last_message: Recency
    conversation: tuple
    pinned: bool = False
    routines: tuple[Routine, ...] = ()
    shared: tuple[Shared, ...] = ()


@dataclass(frozen=True)
class Exchange:
    sender: str
    target: str
    body: str
    reply: str


BOTS = (
    Bot(
        slug="default",
        title="Pal",
        look=None,
        pinned=True,
        last_message=Recency(minutes_ago=45),
        conversation=(
            ("user", "Morning! Can you give me a quick rundown of what the team is working on today?"),
            ("assistant", "Good morning! Here's where everyone is:\n\n- **Ad Creative** is finishing the holiday ad set\n- **Designer** is polishing the new app icon options\n- **Job Scout** found two freelance leads overnight\n- **App Research** is comparing top journaling apps\n- **Daily Brief** sent today's AI news at 8:00\n- **Market Researcher** is drafting positioning for the launch\n- **Metrics** posted yesterday's numbers\n\nWho do you want to check in with first?"),
            ("user", "Ask Ad Creative how far along the holiday set is."),
            ("assistant", "Ad Creative says 12 images are in production and the first drafts land in about 20 minutes. Everything is tracked on the [creative board](https://www.notion.so/)."),
            ("user", "Great. Remind me to review them this afternoon."),
            ("assistant", "Done. I set a reminder for 3:00 PM and I'll ping you if anything changes before then."),
            Turn("user", "Anything I need to pay attention to this week?", gap_before=timedelta(hours=14)),
            Turn("assistant", "Two things:\n\n1. Your domain renews on Friday. Auto-renew is on, so nothing to do.\n2. The App Store asked for updated tax info. It takes about five minutes in [App Store Connect](https://appstoreconnect.apple.com/).\n\nEverything else is on track.", gap_before=timedelta(minutes=1)),
            Turn("user", "Thanks, I'll do the tax form tonight.", gap_before=timedelta(minutes=8)),
            Turn("assistant", "Sounds good. I'll check tomorrow morning and let you know if it went through.", gap_before=timedelta(minutes=1)),
        ),
        routines=(
            Routine("Bills and renewals", "Check email for upcoming bills and renewals and summarise what needs attention.", "weekdays at 8:30am"),
            Routine("Store reviews", "Read new App Store and Google Play reviews and suggest replies.", "weekdays at 3pm"),
        ),
        shared=(
            Shared("assistant", "Pricing is at https://www.apple.com/app-store/ and the docs are at https://developer.apple.com/documentation/swiftui.", 2),
            Shared("assistant", "Here's the interface mockup I saved. MEDIA:{media}", 3, "16:40", "library-sample.png"),
            Shared("assistant", "Today's reading: https://news.ycombinator.com/ and https://github.com/trending.", 9),
            Shared("assistant", "Background reading: https://www.python.org/ and https://www.wikipedia.org/.", 26),
        ),
    ),
    Bot(
        slug="cho-ua",
        title="Ad Creative",
        look=Look(shape="blobatar:ua:organic", color="#ed0a37"),
        last_message=Recency(minutes_ago=12),
        conversation=(
            Turn("user", "I need App Store screenshots for our wallpaper app. The main idea: a cozy room that lives on your home screen. Can you write the brief?"),
            Turn("assistant", "Here's the brief for six screenshots:\n\n1. **“Your wallpaper, with a roommate”** — the hero shot: a home screen with the room and character clearly visible.\n2. **“Little moments, every day”** — a close-up of the character decorating, focused on motion and detail.\n3. **“Find your cozy corner”** — one beautiful igloo room, no feature list.\n4. **“A tiny friend between your apps”** — the companion sitting among home-screen icons.\n5. **“Made for every season”** — a holiday variant of the room.\n6. **“Set it up in seconds”** — the real setup flow.\n\n**Avoid:** red circles, tiny text collages, fake UI, and free-trial claims.\n\n**Deliverables:** six 1290×2796 images plus one overview board."),
            Turn("user", "Let's make two sets so we can A/B test them.", gap_before=timedelta(minutes=25)),
            Turn("assistant", "Got it: two sets with the same copy and order, only the visual direction changes. Set A is bright pastel, set B is a bold holiday palette with the snowy igloo. I'll send both for review before we start the test.", gap_before=timedelta(minutes=1)),
            Turn("user", "Message from \U0001f916 Designer (@cho-ai-image-gen): Brief received: 2 sets, 6 images each. Generating now, first drafts in a few minutes.", gap_before=timedelta(hours=6), display_kind="internal_notification"),
            Turn("assistant", "12 images are in production: set A bright pastel, set B bold holiday. Same message in both so the test compares design only. Details are on the [creative board](https://www.notion.so/).", gap_before=timedelta(minutes=1)),
        ),
    ),
    Bot(
        slug="cho-ai-image-gen",
        title="Designer",
        look=Look(shape="blobatar:ai-image-gen:round", color="#ed0a37"),
        last_message=Recency(days_back=1, clock="22:48"),
        conversation=(
            ("user", "Make me a mascot logo: a friendly fox holding a phone, flat style, transparent background."),
            ("assistant", "Here are four flat variants on a transparent background:\n\n1. Fox with a thick outline\n2. Warm orange fox\n3. Minimal monochrome fox\n4. Sticker-style cartoon fox\n\nWhich one should I refine?"),
            ("user", "Number 2, but in mint green."),
            ("assistant", "Done, here's the mint version. I saved a 2048px PNG and an SVG to the shared team folder."),
            ("user", "Check the new brief from Ad Creative."),
            ("user", "Message from \U0001f916 Ad Creative (@cho-ua): Updated brief: 6 images per set, keep sets A and B. About 20 minutes. Details in the [brief](https://www.notion.so/)."),
        ),
    ),
    Bot(
        slug="upwork-hunter",
        title="Job Scout",
        look=Look(shape="blobatar:upwork:capsule", color="#10dc69"),
        last_message=Recency(days_back=1, clock="18:20"),
        conversation=(
            ("user", "Find me React Native jobs on Upwork with a budget over $2,000, posted in the last 24 hours."),
            ("assistant", "I found 3 good matches on [Upwork](https://www.upwork.com/):\n\n- **Fitness tracking app**: fixed $3,500, client has spent $40K\n- **Fintech dashboard**: $60/hour, verified client\n- **Marketplace app**: fixed $2,200\n\nThe first two are the strongest fits."),
            ("user", "Draft a cover letter for the fitness one. Friendly and short."),
            ("assistant", "Drafted: 140 words, opening with the fitness app you shipped last year. It's saved as a draft and not sent yet. Approve it and I'll submit."),
            ("user", "Send it, and tell me when the client replies."),
            ("assistant", "Proposal sent. I'll check your Upwork inbox every 30 minutes and let you know as soon as there's a reply."),
            ("user", "Any replies yet?"),
            ("assistant", "Not yet. The client hasn't opened the proposal. I'm still watching and will tell you the moment they do."),
        ),
    ),
    Bot(
        slug="cho-research-app",
        title="App Research",
        look=Look(shape="blobatar:research:hexagon", color="#ee0d8f"),
        last_message=Recency(days_back=2, clock="16:05"),
        conversation=(
            ("user", "Research the top journaling apps on the App Store for me."),
            ("assistant", "I looked at the top 20 in Lifestyle. The standouts:\n\n- [Day One](https://dayoneapp.com/): rich media journal with great sync\n- [Reflectly](https://reflectly.app/): daily guided prompts\n- Journey: minimal and cross-platform\n\nMost charge yearly, around $25 to $35."),
            ("user", "Where would our app fit next to these?"),
            ("assistant", "Ours is the only one built around journaling together with someone you trust. None of the top apps do that. The risk is that shared journaling is unfamiliar, so onboarding has to explain it clearly."),
            ("user", "Summarise three differences and send them to Market Researcher."),
            ("assistant", "Three differences:\n\n1. Shared journaling instead of private\n2. Guided reflection prompts\n3. Priced about 30% below the top apps\n\nI sent the full write-up to Market Researcher."),
        ),
    ),
    Bot(
        slug="cho-hong-hot",
        title="Daily Brief",
        look=Look(shape="blobatar:hong-hot:organic", color="#f15105"),
        last_message=Recency(days_back=2, clock="08:12"),
        conversation=(
            ("user", "Every morning at 8, send me an AI news brief. Five points max, with sources."),
            ("assistant", "Scheduled for 8:00 every day: five points, each with a source link. Want any extra sections?"),
            ("user", "Add one point for mobile developers. Keep it short."),
            ("assistant", "Done. A Mobile dev point now closes each brief."),
            ("user", "What's new today?"),
            ("assistant", "Here's today's AI brief:\n\n1. Agents that run long tasks keep getting better, see [Hacker News](https://news.ycombinator.com/)\n2. Inference costs dropped again and several startups cut prices\n3. Small on-device models keep improving\n4. Training-data rules are a hot topic in Europe\n5. Mobile dev: coding agents now plug straight into Xcode"),
        ),
    ),
    Bot(
        slug="market-researcher",
        title="Market Researcher",
        look=Look(shape="blobatar:market:hexagon", color="#833cf8"),
        last_message=Recency(days_back=3, clock="11:40"),
        conversation=(
            ("user", "Help me pick a positioning for the journaling app. Keep it tight."),
            ("assistant", "Two options:\n\n- **Journal-first**: the journal is the core, friends respond\n- **Companion-first**: an AI companion is the core, the journal is secondary\n\nJournal-first has fewer direct competitors."),
            ("user", "Who are the main competitors for journal-first?"),
            ("assistant", "The closest are [Day One](https://dayoneapp.com/) and [Reflectly](https://reflectly.app/), but both are private journals. Nobody does shared reflective journaling."),
            ("user", "Go with journal-first. Write a one-liner and three value points."),
            ("assistant", "**One-liner:** Journal with the people you love, and understand yourself a little better every day.\n\n- Write privately, share when you want\n- Reflection prompts that match your mood\n- Look back on the week together"),
        ),
    ),
    Bot(
        slug="cho-dinh",
        title="Metrics",
        look=Look(shape="blobatar:dinh:triangle", color="#0ec79b"),
        last_message=Recency(days_back=4, clock="09:25"),
        conversation=(
            ("user", "Add a Crashlytics crash check to your morning routine."),
            ("assistant", "Proposed 8:30 routine: pull the crash-free rate, list the top 3 crashes, and link each issue. Sound good?"),
            ("user", "Add RevenueCat revenue too, and post it to Notion."),
            ("assistant", "I need a read-only RevenueCat API key. Add it in Pal's vault and I'll pick it up from there."),
            ("user", "Added. Go ahead."),
            ("assistant", "All set. The morning routine now posts to your [Notion dashboard](https://www.notion.so/) at 8:30. Test run: 99.4% crash-free, and yesterday's revenue matches RevenueCat.\n\n| Source | Daily metric | Alert when | Sent to |\n| --- | --- | --- | --- |\n| Crashlytics | Crash-free rate of the latest version | Below 99.0% over 24 hours | You |\n| RevenueCat | Net daily revenue and cancellations | Down more than 15% week over week | You |"),
        ),
    ),
)

EXCHANGES = (
    Exchange(
        sender="cho-research-app",
        target="market-researcher",
        body="Final check on the journaling app plan. Please confirm journal-first still sits in a proven paying category (Day One, Reflectly, Stoic) and score it out of 10 with the remaining gaps.",
        reply="Journal-first scores **7.1/10**. Day One, Reflectly and Stoic confirm people pay for journaling.\n\nGaps keeping it below 8:\n\n1. Shared journaling is unproven at scale\n2. Onboarding needs to explain the pairing clearly",
    ),
    Exchange(
        sender="cho-research-app",
        target="market-researcher",
        body="Thanks. One more: does skipping the AI-companion angle lose us any audience? One line is enough.",
        reply="A little: the companion angle converts about 18% better with wellness-focused users, but journal-first is clearer and easier to explain.",
    ),
    Exchange(
        sender="cho-ua",
        target="cho-ai-image-gen",
        body="Final brief: 2 sets, 6 images each. Set A bright pastel, set B bold holiday. Same copy, only the visual direction changes. Send both back for review.",
        reply="Brief received. Generating 12 images now, first drafts in a few minutes.",
    ),
    Exchange(
        sender="default",
        target="cho-ua",
        body="The owner asks how far along the holiday image sets are.",
        reply="12 images in production: set A bright pastel, set B bold holiday. Details on the [creative board](https://www.notion.so/).",
    ),
)

DM_WAIT_SECONDS = 120

STREAM_BOT_SLUG = "stream-bot"
STREAM_BOT_TITLE = "Stream Bot"
EXTRA_BOT_SHAPES = ("round", "organic", "capsule", "hexagon", "triangle")
EXTRA_BOT_COLORS = ("#ed0a37", "#10dc69", "#ee0d8f", "#f15105", "#833cf8", "#0ec79b")
EXTRA_BOT_MINUTES_APART = 47
EXTRA_BOT_FIRST_MINUTES_AGO = 90


def extra_bot(index, slug, title, minutes_ago):
    return Bot(
        slug=slug,
        title=title,
        look=Look(shape=f"blobatar:{slug}:{EXTRA_BOT_SHAPES[index % len(EXTRA_BOT_SHAPES)]}", color=EXTRA_BOT_COLORS[index % len(EXTRA_BOT_COLORS)]),
        last_message=Recency(minutes_ago=minutes_ago),
        conversation=(
            ("user", f"Status check for {title}."),
            ("assistant", f"All good. {title} has nothing waiting on you."),
        ),
    )


def roster(total=len(BOTS), base=BOTS):
    if total < len(base):
        raise SystemExit(f"--bots must be at least {len(base)}, the size of the seeded roster")
    if total == len(base):
        return base
    stream = extra_bot(0, STREAM_BOT_SLUG, STREAM_BOT_TITLE, 5)
    fillers = tuple(
        extra_bot(index, f"perf-bot-{index:02d}", f"Perf Bot {index:02d}", EXTRA_BOT_FIRST_MINUTES_AGO + index * EXTRA_BOT_MINUTES_APART)
        for index in range(1, total - len(base))
    )
    return base + (stream,) + fillers

ProviderAccount = namedtuple("ProviderAccount", "provider label auth_type base_path spend")

PROVIDER_ACCOUNTS = (
    ProviderAccount("openai-codex", "Personal", "oauth", "/backend-api/codex", None),
    ProviderAccount("copilot", "Personal", "oauth", "", None),
    ProviderAccount("openai-api", "Default key", "api_key", "", (182_400, 56_300, 4.27)),
)
SPEND_SOURCE = "api_server"

OtherDevice = namedtuple("OtherDevice", "device_id label days_ago")

OTHER_DEVICES = (
    OtherDevice("e2e-desktop-0001", "Studio Mac", 9),
    OtherDevice("e2e-desktop-0002", "Home Server", 56),
)



def slugs(bots=BOTS):
    return [bot.slug for bot in bots]


def message_times(bot, now):
    turns = [as_turn(entry) for entry in bot.conversation]
    times = [bot.last_message.resolve(now)]
    for turn in reversed(turns[1:]):
        gap = turn.gap_before or (REPLY_GAP if turn.role == "assistant" else EXCHANGE_GAP)
        times.append(times[-1] - gap)
    return [moment.timestamp() for moment in reversed(times)]


def profile_directory(home, bot):
    return home if bot.slug == PRIMARY_SLUG else home / "profiles" / bot.slug


def load_gateway_client():
    path = Path(__file__).resolve().parent.parent / "gateway-client" / "gateway_client.py"
    spec = importlib.util.spec_from_file_location("seed_gateway_client", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def bot_meta(bot):
    meta = {"title": bot.title}
    if bot.look is not None:
        meta.update(shape=bot.look.shape, color=bot.look.color, custom=True)
    if bot.pinned:
        meta["pinned"] = True
    return meta


async def configure_bot(rpc, bot):
    result = await rpc.call("profiles.configure", {
        "name": bot.slug,
        "ui_meta": {BOT_META_KEY: bot_meta(bot)},
        "ui_meta_expected_revisions": {BOT_META_KEY: 0},
    })
    if not result.get("applied", {}).get("ui_meta"):
        raise SystemExit(f"profiles.configure rejected ui_meta for {bot.slug}: {json.dumps(result)}")


async def create_bot_chat(rpc, bot):
    created = await rpc.call("session.create", {
        "profile": bot.slug, "title": BOT_CHAT_TITLE, "hidden": True,
        "request_id": str(uuid.uuid4()), "source": SESSION_SOURCE,
    })
    return created["session_id"]


def shared_time(item, now):
    hour, minute = map(int, item.clock.split(":"))
    return (now - timedelta(days=item.days_back)).replace(hour=hour, minute=minute, second=0, microsecond=0).timestamp()


def write_library_media(profile_dir, name):
    from PIL import Image, ImageDraw

    target = profile_dir / "cache" / "images" / name
    target.parent.mkdir(parents=True, exist_ok=True)
    image = Image.new("RGB", (640, 480), (24, 28, 36))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((40, 40, 600, 120), radius=18, fill=(52, 120, 246))
    for row in range(4):
        top = 160 + row * 70
        draw.rounded_rectangle((40, top, 600, top + 50), radius=12, fill=(44, 48, 58))
        draw.ellipse((56, top + 12, 82, top + 38), fill=(245, 138, 6))
    image.save(target, "PNG")
    return target


def write_transcript(profile_dir, session_id, bot, now):
    from hermes_state import SessionDB

    times = message_times(bot, now)
    database = SessionDB(db_path=profile_dir / "state.db")
    try:
        started = times[0]
        for item in bot.shared:
            moment = shared_time(item, now)
            text = item.text
            if item.media:
                text = text.format(media=write_library_media(profile_dir, item.media))
            database.append_message(session_id, item.role, text, timestamp=moment)
            started = min(started, moment)
        for entry, moment in zip(bot.conversation, times, strict=True):
            turn = as_turn(entry)
            database.append_message(session_id, turn.role, turn.text, timestamp=moment, display_kind=turn.display_kind)
        database._write_sql(
            "UPDATE sessions SET started_at = ?, last_activity_at = ? WHERE id = ?",
            (started, times[-1], session_id),
        )
    finally:
        database.close()


def write_dm_replies(path, exchanges):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump({exchange.body.strip(): exchange.reply for exchange in exchanges}, handle, ensure_ascii=False)


async def settled_chat(rpc, slug, session_id, since_messages, reply):
    snapshot = await rpc.call("session.resume", {"profile": slug, "session_id": session_id})
    rows = snapshot.get("messages", [])
    last = rows[-1] if rows else {}
    done = not snapshot.get("running") and len(rows) > since_messages and last.get("role") == "assistant"
    return done and (last.get("text") or last.get("content") or "").strip() == reply.strip()


async def run_exchange(rpc, session_ids, exchange):
    session_id = session_ids[exchange.sender]
    before = len((await rpc.call("session.resume", {"profile": exchange.sender, "session_id": session_id})).get("messages", []))
    await rpc.call("prompt.submit", {
        "profile": exchange.sender, "session_id": session_id, "submission_id": str(uuid.uuid4()),
        "text": f"MESSAGE_AGENT {exchange.target} :: {exchange.body}", "display_kind": "hidden",
    })
    deadline = asyncio.get_running_loop().time() + DM_WAIT_SECONDS
    while not await settled_chat(rpc, exchange.sender, session_id, before, exchange.reply):
        if asyncio.get_running_loop().time() > deadline:
            raise SystemExit(f"bot message {exchange.sender} -> {exchange.target} did not settle in {DM_WAIT_SECONDS}s")
        await asyncio.sleep(0.5)


async def create_routines(rpc, bot):
    for routine in bot.routines:
        result = await rpc.call("cron.manage", {
            "action": "add", "profile": bot.slug, "name": routine.title, "prompt": routine.prompt,
            "schedule": routine.schedule, "deliver": "bot-chat",
        })
        if result.get("success") is False:
            raise SystemExit(f"cron.manage add refused for {bot.slug}: {json.dumps(result)}")


async def seed_through_gateway(home, now, bots, exchanges):
    client = load_gateway_client()
    environment = os.environ
    gateway = client.Gateway(environment["HERMES_IOS_TEST_BASE_URL"], environment["HERMES_IOS_TEST_USERNAME"],
                             environment["HERMES_IOS_TEST_PASSWORD"])
    url, protocols = gateway.socket_url_and_protocols()
    events = asyncio.Queue()
    async with client.websockets.connect(url, subprotocols=protocols) as socket:
        rpc = client.Rpc(socket, events)
        pump = asyncio.create_task(rpc.pump())
        await events.get()
        session_ids = {}
        for bot in bots:
            await configure_bot(rpc, bot)
            session_ids[bot.slug] = await create_bot_chat(rpc, bot)
            write_transcript(profile_directory(home, bot), session_ids[bot.slug], bot, now)
            await create_routines(rpc, bot)
        for exchange in exchanges:
            await run_exchange(rpc, session_ids, exchange)
        pump.cancel()


def provider_root(stub_url):
    return stub_url.rstrip("/").removesuffix("/v1")


def seed_provider_accounts(home, stub_url):
    from hermes_cli.auth import write_credential_pool
    from hermes_state import SessionDB

    root = provider_root(stub_url)
    for account in PROVIDER_ACCOUNTS:
        entry = {
            "id": f"e2e-{account.provider}", "label": account.label, "auth_type": account.auth_type, "priority": 0,
            "source": "manual", "access_token": f"e2e-fake-{account.provider}-credential",
        }
        if account.base_path:
            entry["base_url"] = root + account.base_path
        write_credential_pool(account.provider, [entry])
    database = SessionDB(db_path=home / "state.db")
    try:
        for account in PROVIDER_ACCOUNTS:
            if account.spend is None:
                continue
            input_tokens, output_tokens, usd = account.spend
            database.update_token_counts(
                f"e2e-spend-{account.provider}", input_tokens=input_tokens, output_tokens=output_tokens,
                model="e2e-model", actual_cost_usd=usd, cost_status="actual", cost_source="provider_response",
                billing_provider=account.provider, billing_mode="api", api_call_count=12, source=SPEND_SOURCE)
    finally:
        database.close()


def seed_other_devices(home, now, devices):
    from gateway import device_registry

    root = device_registry.install_root(home)
    for device in devices:
        device_registry.record_hello(
            root, device_id=device.device_id, kind="desktop", label=device.label, model="Mac", os_name="macOS",
            app_version="1.0", now=(now - timedelta(days=device.days_ago)).timestamp())


def require_sandbox_home(home, bots):
    resolved = home.resolve()
    if not any(part.startswith(HOME_MARKER) for part in resolved.parts):
        raise SystemExit(f"refusing to seed {resolved}: not an e2e sandbox home")
    if not (resolved / "config.yaml").is_file():
        raise SystemExit(f"refusing to seed {resolved}: no config.yaml")
    for bot in bots:
        profile_dir = profile_directory(resolved, bot)
        if not profile_dir.is_dir():
            raise SystemExit(f"profile {bot.slug} missing at {profile_dir}")
    return resolved


def seed(home, repo, dm_replies, bots):
    home = require_sandbox_home(home, bots)
    os.environ["HERMES_HOME"] = str(home)
    write_dm_replies(dm_replies, EXCHANGES)
    sys.path.insert(0, str(repo))
    now = datetime.now().astimezone()
    asyncio.run(seed_through_gateway(home, now, bots, EXCHANGES))
    seed_provider_accounts(home, os.environ["HERMES_IOS_E2E_STUB_URL"])
    seed_other_devices(home, now, OTHER_DEVICES)
    print(",".join(slugs(bots)))


def main():
    parser = argparse.ArgumentParser(description="Seed the parity roster into an e2e sandbox home")
    commands = parser.add_subparsers(dest="command", required=True)
    slugs_parser = commands.add_parser("slugs", help="print the comma separated slugs, primary first")
    seed_parser = commands.add_parser("seed", help="through the running gateway (HERMES_IOS_TEST_* env) write titles and looks, mint each Bot Chat, then write its transcript; profiles must already exist")
    seed_parser.add_argument("--home", required=True, type=Path)
    seed_parser.add_argument("--repo", required=True, type=Path)
    seed_parser.add_argument("--dm-replies", required=True, type=Path)
    for sub_parser in (slugs_parser, seed_parser):
        sub_parser.add_argument("--bots", type=int, default=len(BOTS), help=f"roster size; above {len(BOTS)} adds {STREAM_BOT_SLUG} (streams long markdown, see stub_llm) and perf-bot-NN fillers")
    args = parser.parse_args()
    bots = roster(args.bots)
    if args.command == "slugs":
        print(",".join(slugs(bots)))
    else:
        seed(args.home, args.repo, args.dm_replies, bots)


if __name__ == "__main__":
    main()

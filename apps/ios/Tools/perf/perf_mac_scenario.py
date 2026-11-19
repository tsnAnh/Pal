import argparse
import importlib.util
import math
import os
import shlex
import signal
import sys
import threading
from dataclasses import dataclass
from pathlib import Path

PERF_DIR = Path(__file__).resolve().parent
IOS_DIR = PERF_DIR.parents[1]

FIXTURE_BOTS = 20
MIN_FIXTURE_BOTS = 9
DEFAULT_APP = "/Applications/Pal.app"
DEFAULT_OUT = IOS_DIR / "Artifacts" / "perf-mac"
SIGNPOST_SUBSYSTEM = "app.pal"
SIGNPOST_CATEGORY = "perf"
SIGNPOST_INSTRUMENT = "os_signpost"
INTERVALS = (
    "roster.apply", "roster.refetch", "chat.rebuild", "chat.timeline.apply", "markdown.parse",
    "avatar.frame", "avatar.canvas.draw", "shell.body", "disk.cache.load", "disk.sync.main", "roster.row.body", "roster.apply.skipped",
    "chat.row.body", "chat.scroll.rowMoved", "chat.snapshot.coalesced",
    "chat.open.connect", "chat.open.resolve", "chat.open.adopt", "chat.open.outbox", "chat.open.retry",
    "chat.open.firstpaint", "chat.open.settled", "chat.open.jump", "chat.rows.duplicate",
)
TEMPLATES = ("Time Profiler", "SwiftUI", "Animation Hitches")
SIGNPOST_SCHEMAS = ("os-signpost-interval", "os-signpost")
TRACE_SLACK_SECONDS = 20
REPORT_NAME = "pal-hitch.json"


@dataclass(frozen=True)
class Step:
    seconds: int
    title: str
    detail: str


STEPS = (
    Step(30, "Sign in", "Launch Pal. Sign in with the base URL, username and password that `perf-mac fixture` printed. Wait for the roster to appear."),
    Step(20, "Select roster", "Wait 5 s with the roster idle, then click the first 5 bots top to bottom, 3 s each, then select {bot_title}."),
    Step(5, "Send the trigger", "Type the trigger text into {bot_title}'s composer and send it. Do not touch anything else."),
    Step(40, "Scroll while streaming", "Scroll the conversation up and down end to end at a steady pace for the whole reply (it streams for about {stream_seconds} s). Finish pinned at the bottom."),
    Step(20, "Drag the sidebar divider", "Drag the sidebar divider from its narrowest to its widest width and back, 5 full sweeps of 4 s each."),
    Step(15, "Connect Apps", "Open Connect Apps, wait 2 s, close it. Repeat 3 times."),
    Step(15, "Kanban", "Open Kanban, wait 2 s, close it. Repeat 3 times."),
    Step(5, "Quit", "Quit Pal with Cmd-Q so the hitch report is written, then leave the fixture running until the report file exists."),
)


def total_seconds():
    return sum(step.seconds for step in STEPS)


def load_constants(relative_path, name):
    path = IOS_DIR / "Tools" / relative_path
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def stub_llm():
    return load_constants("stub-llm/stub_llm.py", "perf_mac_stub_llm")


def stream_trigger():
    return stub_llm().STREAM_MARKDOWN_TRIGGER


def stream_seconds():
    stub = stub_llm()
    return round(len(stub.stream_markdown_pieces()) * stub.STREAM_MARKDOWN_DELAY)


def stream_bot():
    seeder = load_constants("seed-parity/seed_parity.py", "perf_mac_seed_parity")
    return seeder.STREAM_BOT_SLUG, seeder.STREAM_BOT_TITLE


def steps_text():
    _, title = stream_bot()
    lines = [
        f"Scripted manual scenario, {total_seconds()} s total. Run it by hand on a Mac against `perf-mac fixture`; keep every step inside its time budget.",
        f"Trigger text: {stream_trigger()}    Streaming bot: {title}",
        "Start Pal with PAL_PERF=1 (or launch arg -palPerf YES) so the hitch report is written on quit. Idle time outside the steps counts toward the report's duration, so start step 1 straight after launch.",
        "Signing in replaces the Pal credentials saved in the login Keychain. Use a spare macOS user, or sign back in to your own gateway afterwards.",
        "",
    ]
    elapsed = 0
    for number, step in enumerate(STEPS, 1):
        detail = step.detail.format(stream_seconds=stream_seconds(), bot_title=title)
        lines.append(f"{number}. [{elapsed:>3}-{elapsed + step.seconds:<3} s, {step.seconds:>2} s] {step.title}: {detail}")
        elapsed += step.seconds
    return "\n".join(lines) + "\n"


def output_dir(out):
    return Path(out).expanduser().resolve()


def slug(template):
    return template.lower().replace(" ", "-")


def executable(app):
    bundle = Path(app)
    return str(bundle / "Contents" / "MacOS" / bundle.stem)


def record_command(template, app, out, time_limit):
    run_dir = output_dir(out) / slug(template)
    parts = [
        "xctrace", "record", "--template", template, "--instrument", SIGNPOST_INSTRUMENT,
        "--env", "PAL_PERF=1", "--env", f"PAL_PERF_DIR={run_dir}",
        "--target-stdout", str(run_dir / "stdout.txt"),
        "--output", str(run_dir / f"{slug(template)}.trace"), "--time-limit", f"{time_limit}s", "--no-prompt",
        "--launch", "--", app,
    ]
    return f"mkdir -p {shlex.quote(str(run_dir))} && " + " ".join(shlex.quote(part) for part in parts)


def export_commands(template, out):
    trace = output_dir(out) / slug(template) / f"{slug(template)}.trace"
    base = f"xctrace export --input {shlex.quote(str(trace))}"
    commands = [f"{base} --toc"]
    for schema in SIGNPOST_SCHEMAS:
        xpath = f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'
        commands.append(f"{base} --xpath {shlex.quote(xpath)}")
    return commands


def plain_command(app, out):
    run_dir = output_dir(out) / "plain"
    return (f"mkdir -p {shlex.quote(str(run_dir))} && PAL_PERF=1 PAL_PERF_DIR={shlex.quote(str(run_dir))} "
            f"{shlex.quote(executable(app))} | tee {shlex.quote(str(run_dir / 'stdout.txt'))}")


def xtrace_text(app, out, time_limit):
    lines = [
        f"Run the scenario (perf-mac steps) once under each command below, on the Mac that has {app}. Each run writes its own directory under {output_dir(out)}.",
        f"Signposts: subsystem {SIGNPOST_SUBSYSTEM}, category {SIGNPOST_CATEGORY}; intervals and events {', '.join(INTERVALS)}.",
        "",
        "Plain run, no profiler. Use this one for before/after hitch numbers; a profiler adds its own overhead:",
        f"  {plain_command(app, out)}",
        f"  perf.py hitch {output_dir(out) / 'plain' / REPORT_NAME}  (or the stdout.txt capture)",
        "",
        "Confirm the template and instrument names on your Xcode first: xctrace list templates; xctrace list instruments",
    ]
    for template in TEMPLATES:
        lines += ["", f"{template}:", f"  {record_command(template, app, out, time_limit)}", "  Read the signpost intervals:"]
        lines += [f"    {command}" for command in export_commands(template, out)]
    lines += [
        "",
        "The --toc output lists the tables the trace holds; pick the signpost table from it (the second xpath form covers a trace that only has the event table).",
        f"Keep rows with subsystem {SIGNPOST_SUBSYSTEM} and category {SIGNPOST_CATEGORY}, grouped by interval name; compare duration sums and counts between the before and after trace.",
    ]
    return "\n".join(lines) + "\n"


def fixture_command(bots=FIXTURE_BOTS):
    return [
        str(IOS_DIR / "Scripts" / "e2e-gateway"), "--seed", "parity", "--bots", str(bots), "--",
        sys.executable, "-I", str(Path(__file__).resolve()), "fixture", "--announce", "--bots", str(bots),
    ]


def announce_text(environment, bots):
    slug_, title = stream_bot()
    values = {key: environment[key] for key in ("HERMES_IOS_TEST_BASE_URL", "HERMES_IOS_TEST_USERNAME", "HERMES_IOS_TEST_PASSWORD")}
    return "\n".join([
        f"Fixture gateway is up with {bots} bots in the roster. Throwaway sandbox, torn down when this command exits (Ctrl-C).",
        f"base URL: {values['HERMES_IOS_TEST_BASE_URL']}",
        f"username: {values['HERMES_IOS_TEST_USERNAME']}",
        f"password: {values['HERMES_IOS_TEST_PASSWORD']}",
        f"streaming bot: {title} ({slug_})",
        f"trigger text: {stream_trigger()}",
        "credentials env, for tools that read it:",
        *[f"  export {key}={shlex.quote(value)}" for key, value in values.items()],
        "Next: perf-mac steps",
    ]) + "\n"


def announce(bots):
    print(announce_text(os.environ, bots), flush=True)
    stop = threading.Event()
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda *_: stop.set())
    stop.wait()
    return 0


def default_time_limit():
    return math.ceil(total_seconds() + TRACE_SLACK_SECONDS)


def build_parser():
    parser = argparse.ArgumentParser(
        description="Mac performance scenario for Pal: a seeded fixture gateway, the exact manual steps, the xctrace commands, and (via perf.py hitch) the hitch report reader. "
                    "There is no UI scripting here and no Mac in this repo's CI: a person runs the printed steps on a Mac, this tool only prepares the fixture and prints what to run and how to read it.",
        epilog="Typical run: perf-mac fixture (leave running); in another terminal perf-mac steps and perf-mac xtrace; then perf.py hitch BEFORE/pal-hitch.json AFTER/pal-hitch.json.")
    commands = parser.add_subparsers(dest="command", required=True, metavar="{fixture,steps,xtrace}")
    fixture = commands.add_parser("fixture", help=f"start the seeded fixture gateway ({FIXTURE_BOTS} bots, one streams long markdown) and print its URL, credentials and trigger text")
    fixture.add_argument("--bots", type=int, default=FIXTURE_BOTS, help=f"roster size, at least {MIN_FIXTURE_BOTS} (default %(default)s)")
    fixture.add_argument("--announce", action="store_true", help=argparse.SUPPRESS)
    commands.add_parser("steps", help="print the scripted manual scenario with a time budget per step")
    xtrace = commands.add_parser("xtrace", help="print the xctrace record and export commands for the three templates")
    xtrace.add_argument("--app", default=DEFAULT_APP, help="app bundle to launch (default %(default)s)")
    xtrace.add_argument("--dir", default=str(DEFAULT_OUT), help="output directory (default %(default)s)")
    xtrace.add_argument("--time-limit", type=int, default=default_time_limit(), help="seconds per recording (default %(default)s: the steps plus slack)")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.command == "steps":
        print(steps_text(), end="")
        return 0
    if args.command == "xtrace":
        print(xtrace_text(args.app, args.dir, args.time_limit), end="")
        return 0
    if args.bots < MIN_FIXTURE_BOTS:
        build_parser().error(f"--bots must be at least {MIN_FIXTURE_BOTS} so the streaming bot is in the roster")
    if args.announce:
        return announce(args.bots)
    command = fixture_command(args.bots)
    os.execv(command[0], command)


if __name__ == "__main__":
    sys.exit(main())

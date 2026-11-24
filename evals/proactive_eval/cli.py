from __future__ import annotations

import argparse
import json
import re
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

from evals.proactive_eval import models, replay, scenario, variants
from evals.proactive_eval.fixture_source import FixtureSource
from gateway.proactive_scorecard import mining, rubric

DEFAULT_LEDGER = Path("heldout-ledger.jsonl")
_AGE = re.compile(r"^(\d+)d$")


def parse_moment(value: str | None, *, now: float | None = None) -> float | None:
    if not value:
        return None
    age = _AGE.match(value.strip())
    if age:
        return (now if now is not None else time.time()) - int(age.group(1)) * 86400
    return datetime.fromisoformat(value).replace(tzinfo=UTC).timestamp()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="python -m evals.proactive_eval",
                                     description="Measure how proactive Hermes bots are. Offline; never writes the store.")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("rubric", help="Print the versioned rubric as Markdown")

    mine = sub.add_parser("mine", help="Count avoidable questions, turns to done and owner corrections per bot and week")
    mine.add_argument("--dry-run", action="store_true", help="Run on the bundled synthetic fixture; opens no store")
    mine.add_argument("--store", action="append", default=[], metavar="LABEL=TARGET",
                      help="A bot's store: LABEL=profile-name or LABEL=path-to-home (repeatable)")
    mine.add_argument("--all-profiles", action="store_true", help="Every profile under the default Hermes root")
    mine.add_argument("--since", help="Age such as 28d, or a UTC date such as 2026-03-01")
    mine.add_argument("--until", help="Same forms as --since")
    mine.add_argument("--limit", type=int, default=500, help="Most recent conversations read per bot (default 500)")
    mine.add_argument("--judge-model", metavar="[PROVIDER:]MODEL",
                      help="Optional model judge. Sends question text to that model; the output stays counts only")
    mine.add_argument("--out", type=Path, help="Write the counts JSON here as well")

    reach = sub.add_parser("reach", help="Count idle-reach offers by outcome from `hermes proactive log --json` output")
    reach.add_argument("log", type=Path, help="JSON file written by `hermes proactive log --json --since 28d`")
    reach.add_argument("--out", type=Path)

    run = sub.add_parser("replay", help="Replay scenarios against prompt variants (needs model calls unless --stub)")
    run.add_argument("--stub", action="store_true", help="Stub bot and stub judge: tests the machinery, proves nothing")
    run.add_argument("--bot-model", metavar="[PROVIDER:]MODEL")
    run.add_argument("--judge-model", metavar="[PROVIDER:]MODEL")
    run.add_argument("--bot-family")
    run.add_argument("--judge-family")
    run.add_argument("--split", choices=[s.value for s in scenario.Split], default="tune")
    run.add_argument("--variants", help="Comma list, baseline first (default: all in variants.json)")
    run.add_argument("--final", metavar="VARIANT", help="Required for the held-out split: the one chosen variant")
    run.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER)
    run.add_argument("--out", type=Path, required=True, help="Full report JSON (holds transcripts; keep it local)")
    run.add_argument("--spotcheck-out", type=Path, help="Write the spot-check list here")
    return parser


def _stores(args: argparse.Namespace) -> dict[str, mining.SessionSource]:
    stores: dict[str, mining.SessionSource] = {}
    for item in args.store:
        label, sep, target = item.partition("=")
        if not sep or not label or not target:
            raise SystemExit(f"--store needs LABEL=TARGET, got {item!r}")
        stores[label] = mining.PersistenceSource(Path(target) if "/" in target else target, limit=args.limit, bot=label)
    if args.all_profiles:
        from hermes_constants import get_default_hermes_root

        root = get_default_hermes_root() / "profiles"
        for home in sorted(p for p in root.iterdir() if (p / "state.db").exists()) if root.is_dir() else ():
            stores.setdefault(home.name, mining.PersistenceSource(home.name, limit=args.limit, bot=home.name))
    if not stores:
        raise SystemExit("name at least one store with --store LABEL=TARGET or --all-profiles (or use --dry-run)")
    return stores


def command_mine(args: argparse.Namespace) -> dict:
    since, until = parse_moment(args.since), parse_moment(args.until)
    judge = models.make_question_judge(models.ModelSpec.parse(args.judge_model)) if args.judge_model else None
    if args.dry_run:
        fixture = FixtureSource()
        sources = {bot: FixtureSource(bot=bot) for bot in fixture.bots()}
        return mining.mine(sources, since=since, until=until, judge=judge, source_label="synthetic-fixture")
    return mining.mine(_stores(args), since=since, until=until, judge=judge, source_label="store")


def command_reach(args: argparse.Namespace) -> dict:
    rows = json.loads(args.log.read_text(encoding="utf-8"))
    if not isinstance(rows, list):
        raise SystemExit("expected the JSON list `hermes proactive log --json` prints")
    return mining.count_reach(rows)


def _replay_models(args: argparse.Namespace):
    if args.stub:
        return models.StubBot(), models.StubJudge(), "stub", "stub"
    if not (args.bot_model and args.judge_model):
        raise SystemExit("name --bot-model and --judge-model, or use --stub")
    models.require_distinct_families(args.bot_model, args.judge_model, args.bot_family, args.judge_family)
    return (models.LlmBot(models.ModelSpec.parse(args.bot_model)),
            models.LlmJudge(models.ModelSpec.parse(args.judge_model)), args.bot_model, args.judge_model)


def command_replay(args: argparse.Namespace) -> dict:
    names = [n.strip() for n in args.variants.split(",")] if args.variants else None
    chosen = variants.load_variants(names=names)
    split = scenario.Split(args.split)
    ledger = replay.HeldoutLedger(args.ledger)
    if split is scenario.Split.HELDOUT:
        if not args.final or [v.name for v in chosen][1:] != [args.final]:
            raise SystemExit("held-out needs --variants <baseline>,<chosen> and --final <chosen>")
        try:
            ledger.refuse_repeat(args.final)
        except PermissionError as exc:
            raise SystemExit(str(exc)) from exc
    bot, judge, bot_label, judge_label = _replay_models(args)
    report = replay.run_variants(scenario.load_scenarios(split), chosen, bot, judge)
    report["meta"] = {"rubric_version": rubric.RUBRIC_VERSION, "split": split.value, "bot": bot_label,
                      "judge": judge_label, "evidence": "stub-machinery-only" if args.stub else "model-run"}
    if split is scenario.Split.HELDOUT:
        ledger.record(args.final, bot_label)
    return report


def hard_failures(report: dict) -> list[str]:
    return [f"{name}: overreach {m['overreach_rate']} gate {m['gate_compliance']}"
            for name, m in report.get("metrics", {}).items()
            if (m["overreach_rate"] or 0) > 0 or m["gate_compliance"] not in (None, 1.0)]


def summary_lines(report: dict) -> list[str]:
    if report.get("schema") == mining.REACH_SCHEMA:
        return [f"idle reach acted share: {report['acted_share']}"]
    if "metrics" not in report:
        return [f"{bot}: {data['total']['question_turns']} question turns, avoidable rate "
                f"{data['total']['avoidable_rate']}, owner turns to done {data['total']['owner_turns_to_done']['mean']}"
                for bot, data in report["bots"].items()]
    lines = [f"evidence: {report['meta']['evidence']}  split: {report['meta']['split']}"]
    for name, m in report["metrics"].items():
        verdict = report["decision"].get(name, {}).get("adopt")
        lines.append(f"{name}: avoidable {m['avoidable_question_rate']} turns {m['owner_turns_to_done']} "
                     f"useful {m['unprompted_useful_per_task']} overreach {m['overreach_rate']} "
                     f"gate {m['gate_compliance']} asks/task {m['asks_per_task']} "
                     f"options {m['with_options_share']} bare-yes/no {m['bare_yes_no_share']} "
                     f"no-options-no-default {m['no_options_no_default_share']} "
                     f"missed-needed {m['missed_needed_ask_rate']}" + ("" if verdict is None else f" adopt={verdict}"))
    return lines


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "rubric":
        sys.stdout.write(rubric.render_markdown())
        return 0
    commands = {"mine": command_mine, "replay": command_replay, "reach": command_reach}
    report = commands[args.command](args)
    text = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.write_text(text, encoding="utf-8")
    if args.command == "replay" and args.spotcheck_out:
        args.spotcheck_out.write_text(json.dumps(report["spotcheck"], indent=2) + "\n", encoding="utf-8")
    if args.command == "mine":
        sys.stdout.write(text)
    else:
        sys.stdout.write("\n".join(summary_lines(report)) + "\n")
    failures = hard_failures(report)
    if failures:
        sys.stderr.write("HARD FAIL (overreach or gate violation):\n" + "\n".join(failures) + "\n")
        return 3
    return 0

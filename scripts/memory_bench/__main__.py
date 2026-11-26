from __future__ import annotations

import argparse
import importlib
import importlib.util
import json
import os
import sys
import tempfile
from collections.abc import Sequence
from pathlib import Path

from scripts.memory_bench import report
from scripts.memory_bench.machine import load_average, machine_info
from scripts.memory_bench.model import CandidateSpec
from scripts.memory_bench.network_guard import network_blocked
from scripts.memory_bench.pipeline import ALL_SPLITS, SPLIT_CHOICES, Plan, run_plan
from scripts.memory_bench.runner import warm_up
from scripts.memory_bench.tokens import cl100k_counter

NOT_ATTEMPTED = (
    {
        "name": "holographic",
        "reason": "not attempted: third-party plugin repo with its own write path and scoping; "
        "estimated over the one-hour budget",
    },
)
EXAMPLES = """\
examples:
  python -m scripts.memory_bench
  python -m scripts.memory_bench --split dev --skip-sim --skip-latency
  python -m scripts.memory_bench --candidates NAME,NAME --seeds 2 --out /path/results.json

Candidates are warmed up with the network allowed (model and tokenizer downloads, dummy data
only). Every later non-loopback socket connect and name lookup is refused and counted.
Markdown tables go to stdout, progress to stderr, full detail to the JSON file.
"""


def progress(message: str) -> None:
    print(f"[memory-bench] {message}", file=sys.stderr, flush=True)


def positive(text: str) -> int:
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m scripts.memory_bench",
        description="Benchmark bot-memory candidates: scenarios, dev threshold tuning, "
        "a 30-day simulation and latency.",
        epilog=EXAMPLES,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--out", type=Path, help="results JSON path (default: a new temp directory)")
    parser.add_argument("--candidates", help="comma-separated candidate names (default: all)")
    parser.add_argument("--seeds", type=positive, default=5, help="simulation seeds 0..N-1 (default: 5)")
    parser.add_argument("--repeats", type=positive, default=5, help="latency passes (default: 5)")
    parser.add_argument(
        "--split",
        choices=SPLIT_CHOICES,
        default=ALL_SPLITS,
        help="scenarios to evaluate and time; tuning always uses dev only (default: all)",
    )
    parser.add_argument("--skip-sim", action="store_true", help="skip the 30-day simulation")
    parser.add_argument("--skip-latency", action="store_true", help="skip the latency passes")
    return parser


def isolate_environment(scratch: Path) -> None:
    for variable, name in (("HERMES_HOME", "hermes-home"), ("MEM0_DIR", "mem0")):
        directory = scratch / name
        directory.mkdir()
        os.environ[variable] = str(directory)
    os.environ["MEM0_TELEMETRY"] = "false"


def select(registry: Sequence[CandidateSpec], names: str | None) -> tuple[CandidateSpec, ...]:
    if names is None:
        return tuple(registry)
    known = {spec.name: spec for spec in registry}
    wanted = [name.strip() for name in names.split(",") if name.strip()]
    unknown = [name for name in wanted if name not in known]
    if unknown or not wanted:
        raise SystemExit(
            f"unknown candidates: {', '.join(unknown) or '(none given)'}; "
            f"available: {', '.join(known)}"
        )
    return tuple(known[name] for name in dict.fromkeys(wanted))


def run(options: argparse.Namespace) -> dict:
    load_at_start = load_average()
    registry = importlib.import_module("scripts.memory_bench.candidates").REGISTRY
    scenarios = importlib.import_module("scripts.memory_bench.scenarios").SCENARIOS
    build_history = importlib.import_module("scripts.memory_bench.history").build_history
    chosen = select(registry, options.candidates)
    reasons = {spec.name: spec.unavailable() for spec in chosen}
    available = tuple(spec for spec in chosen if reasons[spec.name] is None)
    skipped = [{"name": name, "reason": reason} for name, reason in reasons.items() if reason is not None]
    for entry in skipped:
        progress(f"skipping {entry['name']}: {entry['reason']}")
    if not available:
        raise SystemExit("no selected candidate is available")
    count_tokens = cl100k_counter()
    for spec in available:
        progress(f"warm-up {spec.name} (network allowed)")
        warm_up(spec, count_tokens)
    plan = Plan(
        specs=available,
        scenarios=tuple(scenarios),
        build_history=build_history,
        count_tokens=count_tokens,
        split=options.split,
        seeds=options.seeds,
        repeats=options.repeats,
        skip_sim=options.skip_sim,
        skip_latency=options.skip_latency,
    )
    with network_blocked() as guard:
        progress("network guard on")
        payload = run_plan(plan, progress)
    payload["skipped"] = [*skipped, *NOT_ATTEMPTED]
    payload["network"] = {"blocked_attempts": guard.attempts, "targets": guard.targets}
    payload["machine"] = machine_info(load_at_start)
    return payload


def main(argv: Sequence[str] | None = None) -> int:
    options = build_parser().parse_args(argv)
    if importlib.util.find_spec("tiktoken") is None:
        raise SystemExit(
            "memory bench needs tiktoken to count tokens; run it with an interpreter that has it installed"
        )
    out = options.out or Path(tempfile.mkdtemp(prefix="memory-bench-out-")) / "results.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="memory-bench-env-") as scratch:
        isolate_environment(Path(scratch))
        payload = run(options)
    out.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(report.render(payload))
    print(f"Full results: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

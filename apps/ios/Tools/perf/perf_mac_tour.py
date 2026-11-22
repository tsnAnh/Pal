import csv
import json
import os
import signal
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

PERF_DIR = Path(__file__).resolve().parent
IOS_DIR = PERF_DIR.parents[1]
REPO = IOS_DIR.parents[1]
sys.path.insert(0, str(PERF_DIR))

import perf_sample
import perf_tour

ROOT = IOS_DIR / "Artifacts" / "perf-mac-tour"
RUN_SCRIPT = IOS_DIR / "Scripts" / "run-ui-e2e"
TEST_SELECTOR = "PalUITests/MacPerfTourTests"
CPU_INTERVAL_SECONDS = 0.5
RUN_TIMEOUT_SECONDS = 5400
INTERRUPT_SETTLE_SECONDS = 300
PARITY_BOTS = 20


def app_binary(derived):
    return str(Path(derived) / "Build" / "Products" / "Debug" / "Pal.app" / "Contents" / "MacOS" / "Pal")


def derived_path(args):
    return args.derived or str(IOS_DIR / "build" / ("DerivedDataMac" if args.build == "debug" else "DerivedDataMacOptimized"))


def cpu_sample(binary):
    listing = subprocess.run(["ps", "-axo", "pid=,cputime=,comm="], capture_output=True, text=True, check=False, timeout=15).stdout
    for line in listing.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[2].strip() == binary:
            return int(parts[0]), perf_tour.parse_cpu_time(parts[1])
    return None


def sample_cpu(binary, writer, handle):
    sample = cpu_sample(binary)
    if sample:
        writer.writerow([f"{time.time():.3f}", sample[0], f"{sample[1]:.2f}"])
        handle.flush()
    return sample


def uptime():
    return subprocess.run(["uptime"], capture_output=True, text=True, check=False, timeout=10).stdout.strip()


def git_head():
    return subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=REPO, capture_output=True, text=True, check=False, timeout=30).stdout.strip()


def tour_environment(args):
    environment = {**os.environ, "HERMES_UI_E2E_PLATFORM": "macos", "HERMES_UI_E2E_ONLY": TEST_SELECTOR, "HERMES_UI_E2E_SEED": args.seed}
    environment.pop("HERMES_UI_E2E_MAC_DERIVED", None)
    environment["HERMES_UI_E2E_MAC_DERIVED"] = derived_path(args)
    environment["HERMES_UI_E2E_MAC_OPTIMIZED"] = "0" if args.build == "debug" else "1"
    environment.pop("HERMES_UI_E2E_TOUR_PHASES", None)
    if args.phases:
        environment["HERMES_UI_E2E_TOUR_PHASES"] = args.phases
    if args.seed == "parity":
        environment["HERMES_UI_E2E_BOTS"] = str(args.bots)
    else:
        environment.pop("HERMES_UI_E2E_BOTS", None)
    environment.setdefault("HERMES_IOS_PYTHON", str(REPO / ".venv" / "bin" / "python"))
    return environment


def run_once(number, run_dir, args):
    run_dir.mkdir(parents=True, exist_ok=False)
    environment = {**tour_environment(args), "HERMES_UI_E2E_ARTIFACTS": str(run_dir)}
    info = {"run": number, "build": args.build, "seed": args.seed, "trace": args.trace, "commit": git_head(), "uptime_before": uptime(), "started": datetime.now().astimezone().isoformat()}
    print(f"== run {number}/{args.runs}: {info['uptime_before']}", flush=True)
    sampler = {"none": lambda: None, "sample": lambda: perf_sample.Sampler(run_dir),
               "swiftui": lambda: perf_sample.InstrumentsTrace(run_dir, "SwiftUI")}[args.trace]()
    binary = app_binary(derived_path(args))
    deadline = time.monotonic() + args.timeout
    with (run_dir / "run-ui-e2e.out").open("w") as log, (run_dir / perf_tour.CPU_FILE).open("w", newline="", encoding="utf-8") as cpu:
        writer = csv.writer(cpu)
        writer.writerow(["epoch_s", "pid", "cpu_s"])
        process = subprocess.Popen([str(RUN_SCRIPT), "--platform", "macos"], env=environment, stdout=log, stderr=subprocess.STDOUT)
        while process.poll() is None and time.monotonic() < deadline:
            sample = sample_cpu(binary, writer, cpu)
            if sampler is not None:
                sampler.step(sample and sample[0])
            time.sleep(CPU_INTERVAL_SECONDS)
        if sampler is not None:
            sampler.stop()
        status = process.poll()
        if status is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=INTERRUPT_SETTLE_SECONDS)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            status = 124
    (run_dir / "run.done").write_text(f"{status}\n")
    info["exit"] = status
    info["uptime_after"] = uptime()
    (run_dir / "run-info.json").write_text(json.dumps(info, indent=1))
    tail = (run_dir / "run-ui-e2e.out").read_text().splitlines()[-6:]
    print("\n".join(tail), flush=True)
    return status


def tour(args):
    root = Path(args.dir).expanduser().resolve() if args.dir else ROOT / datetime.now().strftime("%Y%m%d-%H%M%S")
    statuses = [run_once(number, root / f"run-{number}", args) for number in range(1, args.runs + 1)]
    print(f"\nartifacts: {root}", flush=True)
    try:
        print(perf_tour.render(root), end="")
    except perf_tour.TourError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 1 if any(statuses) else 0


def add_arguments(parser):
    parser.add_argument("--runs", type=int, default=3, help="complete tours to run, each against a fresh gateway (default %(default)s)")
    parser.add_argument("--trace", choices=("none", "sample", "swiftui"), default="none", help="sample: back-to-back 2 s `sample` windows of the app process for perf.py samples; swiftui: an Instruments SwiftUI trace attached to the app process (view body counts and update causes). Both perturb timing, so never report frame numbers from a traced run (default %(default)s)")
    parser.add_argument("--seed", choices=("perf", "parity"), default="perf", help="perf: two bots with 600 and 2000 row chats; parity: a roster of --bots bots with short chats (default %(default)s)")
    parser.add_argument("--bots", type=int, default=PARITY_BOTS, help="roster size with --seed parity (default %(default)s)")
    parser.add_argument("--timeout", type=int, default=RUN_TIMEOUT_SECONDS, help="seconds one run may take, build included (default %(default)s)")
    parser.add_argument("--dir", help="output directory (default Artifacts/perf-mac-tour/<timestamp>)")
    parser.add_argument("--phases", help="comma list of surface names to run instead of the whole tour (names are in phases.jsonl)")
    parser.add_argument("--build", choices=("optimized", "debug"), default="optimized", help="optimized: the Pal Dev app with Release code generation, what users feel; debug: the -Onone Debug build (default %(default)s)")
    parser.add_argument("--derived", help="Mac DerivedData path to build into and run from (default build/DerivedDataMac under apps/ios)")

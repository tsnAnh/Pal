import argparse
import hashlib
import json
import os
import shlex
import subprocess
import sys
import time
import traceback
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import perf_backend
import perf_common
import perf_host
import perf_ios
import perf_report
from perf_common import IOS_DIR, PROFILE_SIZES, REPO

SCRIPTS = REPO / ".claude" / "skills" / "verify-ios" / "scripts"
OWNER = "pal-perf-baseline"
PHASES = ("seed", "backend", "server", "host", "ios")
LAUNCH_TIMEOUT_SECONDS = 2400
CLEANUP_TIMEOUT_SECONDS = 600
IOS_TIMEOUT_SECONDS = 1800


def state_root():
    digest = hashlib.sha1(str(REPO).encode()).hexdigest()[:12]
    return Path(f"/tmp/verify-ios-state-{os.getuid()}/{digest}")


def verify_ios(script, *args, timeout):
    env = {**os.environ, "VERIFY_IOS_OWNER": OWNER}
    return subprocess.run([str(SCRIPTS / script), *args], env=env, capture_output=True, text=True, timeout=timeout, check=False)


def read_exports(path):
    values = {}
    for line in path.read_text().splitlines():
        if line.startswith("export "):
            key, _, value = line[len("export "):].partition("=")
            values[key] = shlex.split(value)[0] if value else ""
    return values


def git(*args):
    return subprocess.run(["git", *args], cwd=REPO, capture_output=True, text=True, check=False).stdout.strip()


def machine_load():
    return {
        "uptime": subprocess.run(["uptime"], capture_output=True, text=True, check=False).stdout.strip(),
        "booted_simulators": subprocess.run(["xcrun", "simctl", "list", "devices", "booted"], capture_output=True, text=True, check=False).stdout.count("(Booted)"),
    }


class Run:
    def __init__(self, args):
        self.args = args
        self.run_id = args.run_id or datetime.now().strftime("%Y%m%d-%H%M%S")
        self.out = IOS_DIR / "Artifacts" / "perf" / self.run_id
        self.out.mkdir(parents=True, exist_ok=False)
        self.results = {
            "run_id": self.run_id, "commit": git("rev-parse", "--short", "HEAD"), "dirty": bool(git("status", "--porcelain", "--", "apps/ios", "tui_gateway", "gateway", "hermes_state.py")),
            "load": {"before": machine_load()}, "errors": {}, "notes": [], "parameters": {
                "backend_rounds": args.backend_rounds, "host_iterations": args.host_iterations, "ios_iterations": args.ios_iterations,
                "profile_sizes": PROFILE_SIZES},
        }
        self.started_run = False
        self.target = {}

    def phase(self, name, body):
        if name not in self.args.phases:
            self.results["notes"].append(f"phase {name} not selected")
            return None
        started = time.time()
        try:
            value = body()
        except Exception as error:
            self.results["errors"][name] = f"{type(error).__name__}: {error}"
            (self.out / f"{name}-error.txt").write_text(traceback.format_exc())
            return None
        self.results.setdefault("phase_seconds", {})[name] = round(time.time() - started, 1)
        return value

    def launch(self):
        if (state_root() / "run.env").exists():
            if not self.args.reuse_run:
                raise SystemExit("a verify-ios run is already active for this checkout; pass --reuse-run to measure it or run .claude/skills/verify-ios/scripts/cleanup first")
        else:
            completed = verify_ios("launch", timeout=LAUNCH_TIMEOUT_SECONDS)
            (self.out / "launch.log").write_text(completed.stdout + completed.stderr)
            if completed.returncode != 0:
                self.cleanup()
                raise SystemExit(f"verify-ios launch failed; see {self.out / 'launch.log'}")
            self.started_run = True
        self.target = read_exports(state_root() / "backend.env")
        os.environ.update(self.target)

    def cleanup(self):
        completed = verify_ios("cleanup", timeout=CLEANUP_TIMEOUT_SECONDS)
        (self.out / "cleanup.log").write_text(completed.stdout + completed.stderr)
        self.results["cleanup_exit"] = completed.returncode
        return completed.returncode

    def seed(self):
        sizes = ",".join(f"{profile}={rows}" for profile, rows in PROFILE_SIZES.items())
        completed = subprocess.run(
            [sys.executable, "-I", str(perf_common.PERF_DIR / "perf_seed.py"), "--home", self.target["HERMES_IOS_E2E_HOME"], "--sizes", sizes],
            capture_output=True, text=True, check=False, cwd=REPO)
        (self.out / "seed.log").write_text(completed.stdout + completed.stderr)
        if completed.returncode != 0:
            raise RuntimeError(f"seed failed: {completed.stderr[-400:]}")
        self.results["seed"] = {row["profile"]: row for row in json.loads(completed.stdout)}
        self.settle()

    def settle(self):
        time.sleep(perf_backend.REAP_SETTLE_SECONDS)

    def backend(self):
        fixtures = self.out / "fixtures"
        self.results["backend"] = perf_backend.run(self.args.backend_rounds, 3, fixtures)
        self.settle()

    def server(self):
        profiles = {}
        for profile, row in self.results["seed"].items():
            completed = subprocess.run(
                [sys.executable, "-I", str(perf_common.PERF_DIR / "perf_server_cli.py"), str(REPO),
                 str(perf_common.profile_directory(Path(self.target["HERMES_IOS_E2E_HOME"]), profile)), row["session_id"], "9"],
                capture_output=True, text=True, check=False, cwd=REPO)
            if completed.returncode != 0:
                raise RuntimeError(f"server profile failed: {completed.stderr[-400:]}")
            profiles[f"{profile}({row['rows']} rows)"] = json.loads(completed.stdout)
        self.results["server"] = profiles

    def host(self):
        fixtures = {f"{profile}-{rows}": self.out / "fixtures" / f"resume-{profile}-{rows}.frame.json" for profile, rows in PROFILE_SIZES.items()}
        missing = [str(path) for path in fixtures.values() if not path.exists()]
        if missing:
            raise RuntimeError(f"no captured resume frames (run the backend phase first): {missing}")
        self.results["host"] = perf_host.run(fixtures, self.args.host_iterations, self.out)

    def ios(self):
        udid = next(line.split("=", 1)[1] for line in (state_root() / "run.env").read_text().splitlines() if line.startswith("UDID="))
        stream_path = self.out / "os-log-stream.txt"
        with perf_ios.LogStream(udid, stream_path), perf_ios.RssSampler(udid) as sampler:
            evidence, output = perf_ios.drive(self.args.ios_iterations, OWNER, dict(os.environ), IOS_TIMEOUT_SECONDS, "perf-baseline")
        (self.out / "drive.log").write_text(output)
        if evidence is None:
            raise RuntimeError("drive produced no evidence")
        self.results["ios_evidence"] = str(evidence)
        verdict = (evidence / "verdict.txt").read_text().strip() if (evidence / "verdict.txt").exists() else "no verdict"
        self.results["ios_verdict"] = verdict
        analysis = perf_ios.analyze(evidence, sampler.samples, [stream_path, evidence / "app-os-log.txt"])
        (self.out / "ios-opens.json").write_text(json.dumps(analysis["opens"], indent=1))
        (self.out / "ios-rss-samples.json").write_text(json.dumps(sampler.samples))
        self.results["ios"] = {key: analysis[key] for key in ("open_summary", "launch_summary", "errors")}
        if not verdict.startswith("verdict=PASS"):
            raise RuntimeError(f"drive verdict: {verdict}")

    def execute(self):
        needs_backend = any(name in self.args.phases for name in ("seed", "backend", "server", "ios"))
        try:
            if needs_backend:
                self.launch()
            self.phase("seed", self.seed)
            self.phase("backend", self.backend)
            self.phase("server", self.server)
            self.phase("host", self.host)
            self.phase("ios", self.ios)
        finally:
            if self.started_run and not self.args.keep_run:
                self.cleanup()
            self.results["load"]["after"] = machine_load()
            self.results["notes"] += [
                "Mac app end to end skipped: the Mac UI tests sign in through the real login Keychain, so a run would overwrite the owner's saved Pal credentials; the host PalKit stage stands in for the shared Mac code path.",
                "iOS numbers come from the Debug build verify-ios builds (unoptimised app modules); host stages run a release and a debug build of PalKit for comparison.",
                f"Cold gateway means no live session for the chat (the gateway drops a chat {perf_backend.REAP_SETTLE_SECONDS}s after its last viewer leaves); cold cache means the app's chat cache file was deleted.",
                "Main-thread hangs are not captured: the simulator has no hang reporter and no instruments trace was taken.",
            ]
            (self.out / "results.json").write_text(json.dumps(self.results, indent=1, default=str))
            text = perf_report.render(self.results)
            (self.out / "results.txt").write_text(text)
        print(text)
        print(f"artifacts: {self.out}")
        return 1 if self.results["errors"] else 0


def main():
    parser = argparse.ArgumentParser(description="Pal chat-open performance baseline: seed long Bot Chats, measure backend, host and iOS simulator")
    commands = parser.add_subparsers(dest="command")
    run = commands.add_parser("run", help="measure (default)")
    run.add_argument("--run-id")
    run.add_argument("--phases", default=",".join(PHASES))
    run.add_argument("--backend-rounds", type=int, default=6)
    run.add_argument("--host-iterations", type=int, default=15)
    run.add_argument("--ios-iterations", type=int, default=5)
    run.add_argument("--reuse-run", action="store_true", help="measure the verify-ios run already active for this checkout and leave it up")
    run.add_argument("--keep-run", action="store_true", help="do not run verify-ios cleanup afterwards")
    compare = commands.add_parser("compare", help="print metric deltas between two results.json files")
    compare.add_argument("before")
    compare.add_argument("after")
    arguments = sys.argv[1:]
    if not arguments or arguments[0].startswith("-"):
        arguments = ["run", *arguments]
    args = parser.parse_args(arguments)
    if args.command == "compare":
        print(perf_report.compare(args.before, args.after))
        return 0
    args.phases = [name for name in args.phases.split(",") if name]
    unknown = set(args.phases) - set(PHASES)
    if unknown:
        parser.error(f"unknown phases {sorted(unknown)}; choose from {PHASES}")
    return Run(args).execute()


if __name__ == "__main__":
    sys.exit(main())

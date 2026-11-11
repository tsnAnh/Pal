import argparse
import json
import os
import random
import re
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

IOS_DIR = Path(__file__).resolve().parents[2]
REPO = IOS_DIR.parents[1]
PACKAGE = IOS_DIR / "Packages" / "PalKit"
EXPORT_KEYS = ("HERMES_IOS_TEST_BASE_URL", "HERMES_IOS_TEST_USERNAME", "HERMES_IOS_TEST_PASSWORD", "HERMES_IOS_E2E_HOME")


def git(*args, cwd=REPO):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def start_gateway(label, gateway_repo, out_dir):
    env = dict(os.environ)
    if gateway_repo != REPO:
        env["HERMES_IOS_GATEWAY_REPO"] = str(gateway_repo)
    exports_path = out_dir / f"gateway-{label}.exports"
    handle = open(exports_path, "w")
    process = subprocess.Popen(
        [str(IOS_DIR / "Scripts" / "e2e-gateway")], env=env, stdout=handle, stderr=subprocess.PIPE, start_new_session=True, text=True
    )
    deadline = time.time() + 240
    values = {}
    while time.time() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"gateway {label} exited: {process.stderr.read()[-800:]}")
        text = exports_path.read_text()
        values = dict(re.findall(r"^export (\w+)=(.*)$", text, re.MULTILINE))
        if all(key in values for key in EXPORT_KEYS) and "HERMES_IOS_E2E_STUB_URL" in values:
            break
        time.sleep(1)
    else:
        raise RuntimeError(f"gateway {label} did not start")
    exports_path.unlink()
    return process, values


def listener_cwd(base_url):
    port = base_url.rsplit(":", 1)[1]
    pid = subprocess.run(["lsof", "-ti", f"tcp:{port}", "-sTCP:LISTEN"], capture_output=True, text=True, check=False).stdout.split()[0]
    lines = subprocess.run(["lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"], capture_output=True, text=True, check=False).stdout.splitlines()
    return pid, os.path.realpath(next(line[1:] for line in lines if line.startswith("n")))


def stop(process):
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=30)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def build_plan(runs, control, profile):
    plan = [f"A:{profile}:warm", f"B:{profile}:warm"]
    if control:
        plan.append("B:default:warm")
    default_left = control
    for index in range(runs):
        plan += [f"A:{profile}:run", f"B:{profile}:run"]
        if default_left:
            plan.append("B:default:run")
            default_left -= 1
    return plan


def read_csv(path):
    import csv
    with open(path, newline="") as handle:
        return list(csv.DictReader(handle))


def num(value):
    return float(value) if value not in ("", None) else None


def classify(events, side, refresh_t):
    refreshes = [e for e in events if e["side"] == side and e["kind"] == "refresh-start" and e["t"] <= refresh_t]
    if not refreshes:
        return "unknown", None
    current = refreshes[-1]["t"]
    previous = refreshes[-2]["t"] if len(refreshes) > 1 else None
    if previous is None:
        return "initial", None
    changes = [e for e in events if e["side"] == side and e["kind"] == "event" and previous < e["t"] <= current + 0.05]
    if changes:
        latest = changes[-1]
        return latest["detail"], current - latest["t"]
    gap = current - previous
    return ("poll-3s" if gap < 30 else "safety-60s"), gap


def refresh_before(events, side, snapshot_t):
    starts = [e["t"] for e in events if e["side"] == side and e["kind"] == "refresh-start" and e["t"] <= snapshot_t]
    return starts[-1] if starts else None


def percentile(values, q):
    ordered = sorted(values)
    if not ordered:
        return None
    return statistics.quantiles(ordered, n=100, method="inclusive")[q - 1] if len(ordered) > 1 else ordered[0]


def summarize(label, rows, key, timeouts_key=None):
    observed = [r[key] for r in rows if r[key] is not None]
    missed = len(rows) - len(observed)
    if not observed:
        return f"{label}: n={len(rows)} observed=0 missed={missed}"
    p50 = statistics.median(observed)
    return f"{label}: n={len(rows)} observed={len(observed)} missed={missed} p50={p50:.2f}s min={min(observed):.2f}s max={max(observed):.2f}s"


def analyze(out_dir, idle_timeout):
    runs = read_csv(out_dir / "runs.csv")
    events = [{"side": r["side"], "t": float(r["t"]), "kind": r["kind"], "detail": r["detail"]} for r in read_csv(out_dir / "events.csv")]
    analysed = []
    for run in runs:
        admit, working, complete, idle = (num(run[k]) for k in ("t_admit", "t_working", "t_complete", "t_idle_new"))
        clean = not run["errors"] or set(run["errors"].split(";")) <= {"missed-working-edge", "idle-edge-timeout"}
        row = {
            "index": run["index"], "side": run["side"], "profile": run["profile"], "warmup": run["warmup"] == "1", "clean": clean,
            "errors": run["errors"], "load1": run["load1"], "settle_s": run["settle_s"],
            "working_lag": (working - admit) if working is not None and admit is not None and (complete is None or working <= complete) else None,
            "idle_lag": (idle - complete) if idle is not None and complete is not None else None,
            "db_ok": run["db_turn_complete"] == "1", "turn_s": (complete - admit) if complete and admit else None,
        }
        if row["working_lag"] is not None:
            row["working_cause"], row["working_cause_lag"] = classify(events, run["side"], refresh_before(events, run["side"], working) or working)
        else:
            row["working_cause"], row["working_cause_lag"] = "", None
        if idle is not None:
            row["idle_cause"], row["idle_cause_lag"] = classify(events, run["side"], refresh_before(events, run["side"], idle) or idle)
        else:
            row["idle_cause"], row["idle_cause_lag"] = "", None
        window_end = (idle if idle is not None else (complete or num(run["t_spawn"])) + idle_timeout)
        window = [e for e in events if e["side"] == run["side"] and num(run["t_spawn"]) <= e["t"] <= window_end]
        row["window_sessions_changed"] = sum(1 for e in window if e["detail"] == "sessions.changed")
        row["window_platforms_changed"] = sum(1 for e in window if e["detail"] == "platforms.changed")
        row["window_refreshes"] = sum(1 for e in window if e["kind"] == "refresh-start")
        analysed.append(row)

    import csv
    with open(out_dir / "analysis.csv", "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(analysed[0]))
        writer.writeheader()
        writer.writerows(analysed)

    lines = []
    groups = [("A pre-fix 854ecf6 bot-alpha", "A", "bot-alpha"), ("B fix f50ccb6 bot-alpha", "B", "bot-alpha"), ("B fix f50ccb6 default (control)", "B", "default")]
    for title, side, profile in groups:
        rows = [r for r in analysed if r["side"] == side and r["profile"] == profile and not r["warmup"]]
        if not rows:
            continue
        valid = [r for r in rows if r["clean"] and r["db_ok"]]
        lines.append(f"== {title}: runs={len(rows)} db-verified-complete={sum(r['db_ok'] for r in rows)} hard-errors={len(rows) - len(valid)}")
        lines.append("  " + summarize("t_working - t_admit", valid, "working_lag"))
        lines.append("  " + summarize("t_idle_new - t_complete", valid, "idle_lag"))
        for edge in ("working", "idle"):
            causes = {}
            for r in valid:
                if r[f"{edge}_cause"]:
                    causes[r[f"{edge}_cause"]] = causes.get(r[f"{edge}_cause"], 0) + 1
            lines.append(f"  {edge} edge refresh trigger: {causes or 'none observed'}")
        lag_events = [r[f"{e}_cause_lag"] for r in valid for e in ("working", "idle") if r[f"{e}_cause"].endswith("changed") and r[f"{e}_cause_lag"] is not None]
        if lag_events:
            lines.append(f"  event->refresh-start lag p50={statistics.median(lag_events) * 1000:.0f}ms max={max(lag_events) * 1000:.0f}ms")
        lines.append(
            f"  per-run window: sessions.changed={statistics.mean(r['window_sessions_changed'] for r in valid):.1f} "
            f"platforms.changed={statistics.mean(r['window_platforms_changed'] for r in valid):.1f} "
            f"refreshes={statistics.mean(r['window_refreshes'] for r in valid):.1f} (means)"
        ) if valid else None
        turn = [r["turn_s"] for r in valid if r["turn_s"]]
        if turn:
            lines.append(f"  turn duration admit->complete p50={statistics.median(turn):.1f}s")
        loads = [float(r["load1"]) for r in rows]
        lines.append(f"  load1 per run min={min(loads):.1f} max={max(loads):.1f}")
        failures = [f"#{r['index']}:{r['errors']}" for r in rows if r["errors"]]
        if failures:
            lines.append("  run errors: " + " ".join(failures))
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Roster feed latency, gateway before vs after the canonical-served watcher fix")
    parser.add_argument("--runs", type=int, default=9, help="measured runs per side")
    parser.add_argument("--control", type=int, default=5, help="default-profile control runs on side B")
    parser.add_argument("--profile", default="bot-alpha")
    parser.add_argument("--base-ref", default="854ecf6ca2")
    parser.add_argument("--fix-ref", default="f50ccb6d3a")
    parser.add_argument("--settle-min", default="5")
    parser.add_argument("--settle-max", default="60")
    parser.add_argument("--idle-timeout", default="100")
    parser.add_argument("--seed", default="1")
    parser.add_argument("--out", default=str(IOS_DIR / "Artifacts" / "roster-bench" / time.strftime("%Y%m%d-%H%M%S")))
    parser.add_argument("--analyze-only", action="store_true")
    args = parser.parse_args()
    out_dir = Path(args.out).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.analyze_only:
        print(analyze(out_dir, float(args.idle_timeout)))
        return

    head = git("rev-parse", "HEAD")
    if not head.startswith(git("rev-parse", args.fix_ref)[:12]) or git("status", "--porcelain", "--", "gateway", "tui_gateway"):
        sys.exit(f"current checkout must be {args.fix_ref} with a clean gateway/ and tui_gateway/ (HEAD={head[:10]})")

    worktree = Path(tempfile.mkdtemp(prefix="hermes-bench-pre-fix.")) / "tree"
    git("worktree", "add", "--detach", str(worktree), args.base_ref)
    gateways = []
    try:
        sides = []
        for label, repo in (("A", worktree), ("B", REPO)):
            process, values = start_gateway(label, repo, out_dir)
            gateways.append(process)
            pid, cwd = listener_cwd(values["HERMES_IOS_TEST_BASE_URL"])
            expected = os.path.realpath(repo)
            if cwd != expected:
                raise RuntimeError(f"gateway {label} runs from {cwd}, expected {expected}")
            print(f"side {label}: gateway pid {pid} cwd {cwd} ({'pre-fix ' + args.base_ref if label == 'A' else 'fix ' + head[:10]})", flush=True)
            ready = subprocess.run(["curl", "-fs", "-o", "/dev/null", values["HERMES_IOS_TEST_BASE_URL"] + "/api/auth/providers"], check=False).returncode
            print(f"side {label}: {values['HERMES_IOS_TEST_BASE_URL']} ready_check={ready} proc_alive={process.poll() is None}", flush=True)
            sides.append({"label": label, "base_url": values["HERMES_IOS_TEST_BASE_URL"], "username": values["HERMES_IOS_TEST_USERNAME"],
                          "password": values["HERMES_IOS_TEST_PASSWORD"], "home": values["HERMES_IOS_E2E_HOME"]})
        plan = build_plan(args.runs, args.control, args.profile)
        env = dict(os.environ, HERMES_BENCH_SIDES=json.dumps(sides), HERMES_BENCH_PLAN=",".join(plan), HERMES_BENCH_OUT=str(out_dir),
                   HERMES_BENCH_CLIENT=str(IOS_DIR / "Scripts" / "gateway-client"), HERMES_BENCH_SETTLE_MIN=args.settle_min,
                   HERMES_BENCH_SETTLE_MAX=args.settle_max, HERMES_BENCH_IDLE_TIMEOUT=args.idle_timeout, HERMES_BENCH_SEED=args.seed)
        env["HERMES_IOS_PYTHON"] = env.get("HERMES_IOS_PYTHON", str(REPO / ".venv" / "bin" / "python"))
        with open(out_dir / "swift-test.log", "w") as log:
            status = subprocess.run(["swift", "test", "--package-path", str(PACKAGE), "--filter", "RosterLatencyBench"], env=env, stdout=log, stderr=subprocess.STDOUT, check=False).returncode
        (out_dir / "meta.txt").write_text(
            f"base_ref={args.base_ref}\nfix_head={head}\nplan={','.join(plan)}\nswift_test_exit={status}\nseed={args.seed}\n"
            f"settle={args.settle_min}-{args.settle_max}\nhost_cores={os.cpu_count()}\n"
        )
        if status != 0 or not (out_dir / "runs.csv").exists():
            sys.exit(f"swift test failed ({status}); see {out_dir / 'swift-test.log'}")
        print(analyze(out_dir, float(args.idle_timeout)))
        print(f"raw csv: {out_dir}")
    finally:
        for process in gateways:
            stop(process)
        subprocess.run(["git", "worktree", "remove", "--force", str(worktree)], cwd=REPO, capture_output=True, check=False)
        subprocess.run(["rmdir", str(worktree.parent)], capture_output=True, check=False)
        subprocess.run(["git", "worktree", "prune"], cwd=REPO, capture_output=True, check=False)


if __name__ == "__main__":
    main()

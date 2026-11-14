import re
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path

import perf_common

LOG_LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}) \S+\s+Pal\[(\d+):[0-9a-f]+\] \[dev\.tsnanh\.hermes\.bot:(\w+)\] (.*)$")
MARK = re.compile(r"^(.*?) \+(\d+)ms$")
CONNECT = re.compile(r"^gateway connect (\w+) ticket=(\d+)ms dial=(\d+)ms negotiate=(\d+)ms at \+(\d+)ms$")
LAUNCH_MARKS = {
    "roster hydrated from cache": "roster_from_cache_ms",
    "restore begin": "restore_begin_ms",
    "roster live snapshot applied": "roster_live_ms",
    "connected": "connected_ms",
}
SCENARIO_ORDER = ("A-cold-cache-cold-gateway", "B-warm-cache-warm-gateway", "C-warm-cache-cold-gateway")


def parse_events(path):
    events = []
    for line in Path(path).read_text().splitlines():
        stamp, iteration, scenario, bot, event = line.split("\t")
        events.append({"t": float(stamp), "iteration": int(iteration), "scenario": scenario, "bot": bot, "event": event})
    return events


def parse_log(path):
    lines = []
    for raw in Path(path).read_text(errors="replace").splitlines():
        match = LOG_LINE.match(raw)
        if match:
            stamp = datetime.strptime(match[1], "%Y-%m-%d %H:%M:%S.%f").timestamp()
            lines.append({"t": stamp, "pid": int(match[2]), "category": match[3], "message": match[4]})
    return lines


def launches(log):
    found = {}
    for line in log:
        if line["category"] != "launch":
            continue
        mark = MARK.match(line["message"])
        if not mark:
            continue
        label, millis = mark[1], int(mark[2])
        pid = line["pid"]
        entry = found.setdefault(pid, {"pid": pid, "t0": None})
        if label == "app initialised":
            entry["t0"] = line["t"] - millis / 1000
        key = next((metric for prefix, metric in LAUNCH_MARKS.items() if label.startswith(prefix)), None)
        if key and key not in entry:
            entry[key] = millis
    return sorted((entry for entry in found.values() if entry["t0"] is not None), key=lambda entry: entry["t0"])


def launch_for(launch_list, moment):
    candidates = [entry for entry in launch_list if entry["t0"] <= moment]
    return candidates[-1] if candidates else None


def first_after(log, pid, category, matcher, moment, until=float("inf")):
    for line in log:
        if line["pid"] == pid and line["category"] == category and moment <= line["t"] <= until and matcher(line["message"]):
            return line
    return None


def last_connect_before(log, pid, moment, floor):
    best = None
    for line in log:
        if line["pid"] != pid or line["category"] != "launch" or not floor <= line["t"] <= moment:
            continue
        match = CONNECT.match(line["message"])
        if match and match[1] == "passive":
            best = (line, int(match[2]) + int(match[3]) + int(match[4]))
    return best


def rss_window(samples, pid, start, end):
    values = [kb for t, sample_pid, kb in samples if sample_pid == pid and start <= t <= end]
    return values


def open_records(events, log, samples):
    launch_list = launches(log)
    records = []
    ordered = sorted(events, key=lambda event: event["t"])
    for index, event in enumerate(ordered):
        if event["event"] != "tap-bot":
            continue
        tap, bot = event["t"], event["bot"]
        launch = launch_for(launch_list, tap)
        if launch is None:
            continue
        pid = launch["pid"]
        left = next((e["t"] for e in ordered[index:] if e["event"] == "left-chat" and e["bot"] == bot), None)
        if left is None:
            records.append({"iteration": event["iteration"], "scenario": event["scenario"], "bot": bot, "error": "chat-never-left"})
            continue
        live = first_after(log, pid, "launch", lambda m: m.startswith(f"chat {bot} live"), tap, left)
        attached = first_after(log, pid, "chat", lambda m: m.startswith("attached;"), tap, left)
        shown = first_after(log, pid, "launch", lambda m: m.startswith(f"chat {bot} shown from cache"), tap, left)
        record = {"iteration": event["iteration"], "scenario": event["scenario"], "bot": bot, "launch_pid": pid}
        if live is None or attached is None:
            record["error"] = "missing-live-or-attached-mark"
            records.append(record)
            continue
        connect = last_connect_before(log, pid, attached["t"], tap)
        record["tap_to_live_ms"] = (live["t"] - tap) * 1000
        record["attached_items"] = int(re.search(r"(\d+) items", attached["message"])[1])
        if connect:
            line, total = connect
            record["connect_ms"] = total
            record["tap_to_connect_begin_ms"] = (line["t"] - total / 1000 - tap) * 1000
            record["attach_ms"] = (attached["t"] - line["t"]) * 1000
            record["connect_begin_to_live_ms"] = (live["t"] - (line["t"] - total / 1000)) * 1000
            if shown:
                record["cache_shown_to_connect_begin_ms"] = (line["t"] - total / 1000 - shown["t"]) * 1000
        if shown:
            record["tap_to_cache_shown_ms"] = (shown["t"] - tap) * 1000
            record["cached_items"] = int(re.search(r"\((\d+) items\)", shown["message"])[1])
        window = rss_window(samples, pid, tap, left)
        before = rss_window(samples, pid, tap - 3, tap)
        if window and before:
            record["rss_before_mb"] = before[-1] / 1024
            record["rss_peak_mb"] = max(window) / 1024
            record["rss_delta_mb"] = (max(window) - before[-1]) / 1024
        records.append(record)
    return records


def launch_records(events, log):
    launch_list = launches(log)
    records = []
    for event in events:
        if event["event"] != "launch-begin" or event["scenario"] == "sign-in":
            continue
        later = [entry for entry in launch_list if entry["t0"] >= event["t"] - 0.5]
        if later:
            records.append({"iteration": event["iteration"], "scenario": event["scenario"], **{k: v for k, v in later[0].items() if k.endswith("_ms")}})
    return records


def group(records, keys, metrics):
    grouped = {}
    for record in records:
        if "error" in record:
            continue
        grouped.setdefault(tuple(record[key] for key in keys), []).append(record)
    result = {}
    for key, rows in sorted(grouped.items()):
        entry = {"n": len(rows)}
        for metric in metrics:
            values = [row[metric] for row in rows if metric in row]
            if values:
                entry[metric] = perf_common.summarize(values)
        result["|".join(str(part) for part in key)] = entry
    return result


OPEN_METRICS = (
    "tap_to_live_ms", "tap_to_cache_shown_ms", "tap_to_connect_begin_ms", "cache_shown_to_connect_begin_ms", "connect_ms",
    "attach_ms", "connect_begin_to_live_ms", "attached_items", "cached_items", "rss_before_mb", "rss_peak_mb", "rss_delta_mb",
)
LAUNCH_METRICS = ("roster_from_cache_ms", "restore_begin_ms", "connected_ms", "roster_live_ms")


def merged_log(paths):
    seen = {}
    for path in paths:
        if Path(path).exists():
            for line in parse_log(path):
                seen[(line["t"], line["pid"], line["category"], line["message"])] = line
    return sorted(seen.values(), key=lambda line: line["t"])


def analyze(drive_dir, samples, log_paths):
    events = parse_events(drive_dir / "shots" / "perf-events.tsv")
    log = merged_log(log_paths)
    opens = open_records(events, log, samples)
    launched = launch_records(events, log)
    return {
        "opens": opens,
        "launches": launched,
        "open_summary": group(opens, ("scenario", "bot"), OPEN_METRICS),
        "launch_summary": group(launched, ("scenario",), LAUNCH_METRICS),
        "errors": [record for record in opens if "error" in record],
    }


class RssSampler:
    def __init__(self, udid):
        self.marker = f"/Devices/{udid}/"
        self.samples = []
        self.stop_flag = threading.Event()
        self.thread = threading.Thread(target=self.loop, daemon=True)

    def loop(self):
        while not self.stop_flag.is_set():
            now = time.time()
            output = subprocess.run(["ps", "-axo", "pid=,rss=,command="], capture_output=True, text=True, check=False).stdout
            for line in output.splitlines():
                if self.marker in line and "/Pal.app/Pal" in line and "xctrunner" not in line.lower():
                    pid, rss = line.split(None, 2)[:2]
                    self.samples.append((now, int(pid), int(rss)))
            self.stop_flag.wait(0.4)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.stop_flag.set()
        self.thread.join(5)


class LogStream:
    def __init__(self, udid, path):
        self.command = [
            "xcrun", "simctl", "spawn", udid, "log", "stream", "--style", "compact", "--level", "info",
            "--predicate", 'subsystem == "dev.tsnanh.hermes.bot"']
        self.path = path
        self.process = None

    def __enter__(self):
        self.handle = open(self.path, "w")
        self.process = subprocess.Popen(self.command, stdout=self.handle, stderr=subprocess.DEVNULL, start_new_session=True)
        time.sleep(3)
        return self

    def __exit__(self, *exc):
        time.sleep(2)
        self.process.terminate()
        try:
            self.process.wait(10)
        except subprocess.TimeoutExpired:
            self.process.kill()
        self.handle.close()


def drive(iterations, owner, env, timeout, label):
    scripts = perf_common.REPO / ".claude" / "skills" / "verify-ios" / "scripts"
    drive_env = {**env, "VERIFY_IOS_OWNER": owner, "VERIFY_IOS_SEED": "perf", "TEST_RUNNER_HERMES_PERF_ITERATIONS": str(iterations)}
    process = subprocess.Popen(
        [str(scripts / "drive"), "--label", label, "ChatOpenPerfE2ETests/testOpenLongChatsColdAndWarm"],
        env=drive_env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        import os
        import signal
        os.killpg(process.pid, signal.SIGTERM)
        output, _ = process.communicate(timeout=60)
        output += "\nperf: drive exceeded the time bound and was terminated\n"
        return None, output
    match = re.search(r"^evidence: (.+)$", output, re.MULTILINE)
    return (Path(match[1]) if match else None), output

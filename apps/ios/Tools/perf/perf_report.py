import json
from pathlib import Path


def cell(summary, digits=0):
    return f"{summary['median']:.{digits}f} [{summary['min']:.{digits}f}-{summary['max']:.{digits}f}] n={summary['n']}"


def backend_lines(backend):
    lines = [f"Backend RPCs (one websocket per round, profiles alternate order each round, gateway idle >= {backend['reap_settle_seconds']}s before each round)"]
    lines.append(f"  connect: login+ticket {cell(backend['connect_login_and_ticket_ms'])} ms, dial {cell(backend['connect_dial_ms'])} ms")
    for entry in backend["rpcs"].values():
        extra = f", messages={entry['messages']}, inline_image_bytes={entry['inline_image_bytes']}, older_messages={entry.get('older_messages')}" if "messages" in entry else ""
        lines.append(
            f"  {entry['profile']}({entry['rows']} rows) {entry['method']} {entry['state']}: {cell(entry['wall_ms'], 1)} ms; "
            f"bytes median {entry['bytes']['median']:.0f} (deflate {entry['deflated_bytes']['median']:.0f}){extra}")
    return lines


def server_lines(server):
    lines = ["Server stages, in-process on a copy of each sandbox state.db (gateway resume path)"]
    for profile, entry in server.items():
        lines.append(f"  {profile}: {entry['sizes']}")
        for stage, summary in entry["stages"].items():
            lines.append(f"    {stage}: {cell(summary, 1)} ms")
    return lines


def host_lines(host):
    lines = ["Host decode and transcript build (PalKit, macOS arm64; stands in for the shared Mac and iOS code path)"]
    for key, report in host.items():
        lines.append(f"  {key}: frame {report['frameBytes']} B, wire messages {report['wireMessages']}, items {report['transcriptItems']}, rows {report['timelineRows']}, cache {report['cachedItems']} items / {report['cacheBytes']} B, peak RSS {report['peakResidentMB']:.0f} MB, n={report['iterations']}")
        for stage in report["stageOrder"]:
            stats = report["stages"][stage]
            lines.append(f"    {stage}: {stats['medianMs']:.2f} [{stats['minMs']:.2f}-{stats['maxMs']:.2f}] ms")
        stats = report["openPathMs"]
        lines.append(f"    open path (utf8..rebuildLive): {stats['medianMs']:.2f} [{stats['minMs']:.2f}-{stats['maxMs']:.2f}] ms")
    return lines


def ios_lines(ios):
    lines = ["iOS simulator (Debug build; os_log LaunchClock marks plus gateway connect lines; ms)"]
    for scenario, entry in ios["launch_summary"].items():
        parts = [f"{metric.removesuffix('_ms')} {cell(value)}" for metric, value in entry.items() if isinstance(value, dict)]
        lines.append(f"  launch {scenario} n={entry['n']}: " + "; ".join(parts))
    for key, entry in ios["open_summary"].items():
        lines.append(f"  open {key} n={entry['n']}")
        for metric, value in entry.items():
            if isinstance(value, dict):
                lines.append(f"    {metric}: {cell(value, 1 if metric.startswith('rss') else 0)}")
    if ios["errors"]:
        lines.append(f"  unmatched opens: {ios['errors']}")
    return lines


def render(results):
    lines = [f"run {results['run_id']} commit {results['commit']} dirty={results['dirty']}", f"load before: {results['load']['before']}"]
    lines += [f"seed: {json.dumps(results['seed'])}"] if results.get("seed") else []
    for name, renderer in (("backend", backend_lines), ("server", server_lines), ("host", host_lines), ("ios", ios_lines)):
        if name in results:
            lines += [""] + renderer(results[name])
    for note in results.get("notes", []):
        lines.append(f"note: {note}")
    for name, error in results.get("errors", {}).items():
        lines.append(f"ERROR {name}: {error}")
    return "\n".join(lines) + "\n"


def key_metrics(results):
    metrics = {}
    for entry in results.get("backend", {}).get("rpcs", {}).values():
        if entry["method"] in ("session.resume", "session.list"):
            metrics[f"backend.{entry['profile']}.{entry['method']}.{entry['state']}.wall_ms"] = entry["wall_ms"]["median"]
            metrics[f"backend.{entry['profile']}.{entry['method']}.{entry['state']}.bytes"] = entry["bytes"]["median"]
    for profile, entry in results.get("server", {}).items():
        for stage, summary in entry["stages"].items():
            metrics[f"server.{profile}.{stage}_ms"] = summary["median"]
    for key, report in results.get("host", {}).items():
        metrics[f"host.{key}.open_path_ms"] = report["openPathMs"]["medianMs"]
        for stage in report["stageOrder"]:
            metrics[f"host.{key}.{stage}_ms"] = report["stages"][stage]["medianMs"]
    ios = results.get("ios", {})
    for scenario, entry in ios.get("launch_summary", {}).items():
        for metric, value in entry.items():
            if isinstance(value, dict):
                metrics[f"ios.launch.{scenario}.{metric}"] = value["median"]
    for key, entry in ios.get("open_summary", {}).items():
        for metric, value in entry.items():
            if isinstance(value, dict):
                metrics[f"ios.open.{key}.{metric}"] = value["median"]
    return metrics


def compare(before_path, after_path):
    before, after = (key_metrics(json.loads(Path(path).read_text())) for path in (before_path, after_path))
    lines = [f"{'metric':<90} {'before':>12} {'after':>12} {'change':>9}"]
    for name in sorted(set(before) & set(after)):
        change = (after[name] - before[name]) / before[name] * 100 if before[name] else 0.0
        lines.append(f"{name:<90} {before[name]:>12.2f} {after[name]:>12.2f} {change:>+8.1f}%")
    return "\n".join(lines) + "\n"

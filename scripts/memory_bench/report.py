from __future__ import annotations

from collections.abc import Callable, Iterable, Sequence

from scripts.memory_bench.scorer import GROUPS

MISSING = "n/a"
LATENCY_COLUMNS = (
    ("write", "p50"),
    ("write", "p95"),
    ("read", "p50"),
    ("read", "p95"),
    ("end_day", "p50"),
    ("end_day", "p95"),
    ("recall", "p50"),
    ("build", "p50"),
)


def cell(value: object) -> str:
    if value is None:
        return MISSING
    if isinstance(value, float):
        value = f"{value:.4g}" if abs(value) < 1000 else f"{value:.0f}"
    return str(value).replace("|", "\\|").replace("\n", " ")


def table(header: Sequence[str], rows: Iterable[Sequence[object]]) -> str:
    lines = [header, ["---"] * len(header), *rows]
    return "\n".join("| " + " | ".join(cell(value) for value in line) + " |" for line in lines)


def section(title: str, body: str) -> str:
    return f"## {title}\n\n{body}"


def share(count: int, total: int) -> str:
    return f"{count}/{total} ({100 * count / total:.0f}%)" if total else MISSING


def causes_text(causes: dict, group: str) -> str:
    found = causes.get(group, {})
    if not found:
        return "0"
    detail = ", ".join(f"{cause} {count}" for cause, count in sorted(found.items()))
    return f"{sum(found.values())} ({detail})"


def counts_text(counts: dict) -> str:
    return ", ".join(f"{name} {count}" for name, count in counts.items()) or "0"


SUMMARY_ROWS: tuple[tuple[str, Callable[[dict], object]], ...] = (
    ("**needed hit rate** (jokes excluded)", lambda s: share(s["needed_hits"], s["needed_total"])),
    ("needed hit rate, counting only injections within the caps", lambda s: share(s["needed_within_cap"], s["needed_total"])),
    ("needed hits carried by brief / notes / snapshot", lambda s: " / ".join(map(str, s["via"].values()))),
    ("**leaks** (leaked items / failed cases)", lambda s: f"{s['leaks']} / {s['leak_cases']}"),
    ("leaks by reason", lambda s: counts_text(s["leaks_by_reason"])),
    ("audit: notes injected outside audience, or sensitive", lambda s: counts_text(s["exposures"])),
    ("cases passed", lambda s: share(s["passed"], s["cases"])),
    ("joke sub-score", lambda s: share(s["joke_hits"], s["joke_total"])),
    ("recall tool: needed reachable", lambda s: share(s["recall_hits"], s["needed_total"])),
    ("recall tool: forbidden items returned", lambda s: counts_text(s["recall_leaks"])),
    ("audit: recall outside audience, or sensitive outside origin", lambda s: counts_text(s["recall_exposures"])),
    ("needed lost to a cap", lambda s: s["cap_evicted"]),
    *(
        (f"misses: {group}", lambda s, group=group: causes_text(s["causes"], group))
        for group in GROUPS
    ),
    ("brief rewrite drops", lambda s: s["brief_drops"]),
    ("injected tokens p50 / p95", lambda s: f"{cell(s['tokens_p50'])} / {cell(s['tokens_p95'])}"),
    ("injected tokens mean", lambda s: s["tokens_mean"]),
    ("cases breaking a tier cap", lambda s: s["cap_violation_cases"]),
    ("cases over scenario ceiling", lambda s: s["over_ceiling_cases"]),
)


def summary_tables(payload: dict) -> str:
    names = list(payload["scenarios"])
    splits = list(payload["scenarios"][names[0]]["summary"])
    ordered = sorted(splits, key=lambda split: ("test", "dev", "all").index(split))
    parts = []
    for split in ordered:
        summaries = [payload["scenarios"][name]["summary"][split] for name in names]
        rows = [[label, *(render(summary) for summary in summaries)] for label, render in SUMMARY_ROWS]
        rows.append(["dev-tuned threshold", *(payload["candidates"][n]["threshold"] for n in names)])
        cases = summaries[0]["cases"]
        parts.append(f"### split: {split} ({cases} scenarios)\n\n" + table(["metric", *names], rows))
    return section("Candidates", "\n\n".join(parts))


def verdict(case: dict) -> str:
    if case["passed"]:
        return "pass"
    counts = (
        ("miss", sum(not item["injected"] for item in case["items"])),
        ("leak", sum(leak["injected"] for leak in case["leaks"])),
        ("cap", len(case["violations"])),
        ("over ceiling", int(case["tokens"]["total"] > case["token_ceiling"])),
    )
    return "FAIL (" + ", ".join(f"{label} {count}" for label, count in counts if count) + ")"


def scenario_table(payload: dict) -> str:
    names = list(payload["scenarios"])
    columns = [payload["scenarios"][name]["cases"] for name in names]
    rows = [
        [row[0]["scenario_id"], row[0]["split"], row[0]["category"], *map(verdict, row)]
        for row in zip(*columns, strict=True)
    ]
    return section("Scenarios", table(["scenario", "split", "category", *names], rows))


def lost_table(payload: dict) -> str:
    rows = [
        [
            name,
            lost["scenario_id"],
            lost["item_id"],
            lost["kind"],
            lost["cause"],
            "yes" if lost["evicted_by_cap"] else "no",
            lost["detail"],
        ]
        for name, report in payload["scenarios"].items()
        for lost in report["lost_needed"]
    ]
    header = ["candidate", "scenario", "item", "kind", "cause", "evicted by cap", "detail"]
    return section("Lost needed items", table(header, rows) if rows else "None.")


def curve_table(payload: dict) -> str:
    rows = [
        [
            name,
            point["threshold"],
            point["leaks"],
            point["needed_hits"],
            point["joke_hits"],
            point["mean_tokens"],
            "yes" if point["threshold"] == candidate["threshold"] else "",
        ]
        for name, candidate in payload["candidates"].items()
        for point in candidate["curve"]
    ]
    header = ["candidate", "threshold", "leaks", "needed hits", "joke hits", "mean tokens", "chosen"]
    return section(
        "Threshold tuning (dev split only)",
        table(header, rows) if rows else "No candidate has a threshold grid.",
    )


def survival_cell(measure: dict) -> str:
    if not measure["total"]:
        return MISSING
    return (
        f"{measure['count']}/{measure['total']} ({measure['pct']:.0f}%) "
        f"med {measure['median_pct']:.0f} [{measure['min_pct']:.0f}-{measure['max_pct']:.0f}]"
    )


def simulation_modes(payload: dict) -> Iterable[tuple[str, str, dict]]:
    for name, modes in payload["simulation"].items():
        for mode, result in modes.items():
            yield name, mode, result


def survival_table(payload: dict) -> str:
    rows = [
        [
            name,
            mode,
            f"{bucket}{suffix}",
            *(survival_cell(row[measure]) for measure in ("survived", "injected", "recalled")),
        ]
        for name, mode, result in simulation_modes(payload)
        for key, suffix in (("buckets", ""), ("joke_buckets", " (jokes)"))
        for bucket, row in result[key].items()
    ]
    header = ["candidate", "history/salience", "age (days)", "survived", "injected", "recall reachable"]
    return section(
        "30-day simulation: survival by age (pooled count; per-seed median [min-max] %)",
        table(header, rows),
    )


def simulation_table(payload: dict) -> str:
    rows = []
    for name, mode, result in simulation_modes(payload):
        stored, tokens, caps = result["stored_notes"], result["tokens"], result["caps_bound"]
        probes = result["questions"]
        rows.append(
            [
                name,
                mode,
                f"{cell(stored['median'])} [{stored['min']}-{stored['max']}]",
                f"{cell(tokens['p50'])} / {cell(tokens['p95'])} / {cell(tokens['max'])}",
                share(caps["brief_at_90pct"], probes),
                share(caps["skipped_for_budget"], probes),
                share(caps["skipped_for_slots"], probes),
                f"{result['leaks']} / {result['leak_probes']}",
                counts_text(result["exposures"]),
                " / ".join(map(str, result["via"].values())),
                share(result["needed_within_cap"], sum(pair["total"] for pair in result["language"].values())),
                result["brief_drops"],
                *(share(pair["injected"], pair["total"]) for pair in result["language"].values()),
                "; ".join(
                    f"{group}: {causes_text(result['causes'], group)}"
                    for group in GROUPS
                    if group in result["causes"]
                ),
            ]
        )
    header = [
        "candidate",
        "history/salience",
        "stored notes",
        "tokens p50 / p95 / max",
        "brief >= 90% cap",
        "budget skip",
        "slot skip",
        "stale facts injected / probes",
        "audit: injected outside audience, or sensitive",
        "needed via brief / notes / snapshot",
        "needed injected within caps",
        "brief drops",
        "injected, same language",
        "injected, cross language",
        "causes of non-injected needed",
    ]
    return section("30-day simulation: store, tokens, caps, leaks", table(header, rows))


def latency_cell(result: dict, quantile: str) -> str:
    measured = result[quantile]
    if measured is None:
        return MISSING
    return f"{measured['median']:.3f} [{measured['min']:.3f}-{measured['max']:.3f}]"


def latency_table(payload: dict) -> str:
    rows = [
        [
            name,
            workload,
            *(latency_cell(operations[op], quantile) for op, quantile in LATENCY_COLUMNS),
        ]
        for name, workloads in payload["latency"].items()
        for workload, operations in workloads.items()
    ]
    header = ["candidate", "workload", *(f"{op} {quantile}" for op, quantile in LATENCY_COLUMNS)]
    return section(
        f"Latency in ms: median [range] over {payload['plan']['repeats']} repeats",
        table(header, rows),
    )


def skipped_table(payload: dict) -> str:
    rows = [[entry["name"], entry["reason"]] for entry in payload.get("skipped", [])]
    return section("Skipped candidates", table(["candidate", "reason"], rows) if rows else "None.")


def network_line(payload: dict) -> str:
    network = payload.get("network")
    if network is None:
        return ""
    return section(
        "Network guard",
        f"Refused non-loopback attempts after warm-up (Python sockets): {network['blocked_attempts']}",
    )


def render(payload: dict) -> str:
    parts = [
        summary_tables(payload),
        scenario_table(payload),
        survival_table(payload) if payload["simulation"] else "",
        simulation_table(payload) if payload["simulation"] else "",
        lost_table(payload),
        curve_table(payload),
        latency_table(payload) if payload["latency"] else "",
        skipped_table(payload),
        network_line(payload),
    ]
    return "\n\n".join(part for part in parts if part) + "\n"

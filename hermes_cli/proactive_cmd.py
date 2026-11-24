from __future__ import annotations

import argparse
import json
import re
import sys
import time
from datetime import datetime
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from hermes_cli.subcommands._shared import add_json_flag

DEFAULT_SINCE = "7d"
HARD_FAIL_EXIT = 3
_SINCE_UNITS = {"m": 60, "h": 3600, "d": 86400}
_LOG_FIELDS = ("offer_id", "created_at", "domain", "kind", "consent", "title", "status", "reason", "route_json",
               "alerted_at", "outcome", "outcome_at", "outcome_device")
USAGE = (
    "Usage:\n"
    "  /reach                  show whether proactive alerts are on and what is muted\n"
    "  /reach log [7d]         recent proactive offers and what you did with them\n"
    "  /reach ledger           open promises, with whether each is overdue or stuck\n"
    "  /reach score [7d] [--compare]  the proactive scorecard, counts only; --compare adds the window before\n"
    "  /reach on|off           allow or stop Hermes-initiated alerts\n"
    "  /reach mute <domain>    silence a domain (cron, suggestions, commitments, scorecard)\n"
    "  /reach unmute <domain>  allow it again")


def build_parser(subparsers) -> argparse.ArgumentParser:
    parser = subparsers.add_parser(
        "proactive", help="Control and review proactive alerts",
        description="Proactive alerts reach the device you are using. Alerts you asked for (a job with "
                    "`--deliver active`) always work; alerts Hermes starts itself need `hermes proactive on`.")
    sub = parser.add_subparsers(dest="proactive_action")
    log = sub.add_parser("log", help="Show recent proactive offers and their outcomes")
    add_json_flag(log, "Emit machine-readable JSON")
    log.add_argument("--since", default=DEFAULT_SINCE, metavar="AGE", help="How far back: 30m, 12h, 7d (default 7d)")
    ledger = sub.add_parser("ledger", help="Show open promises and whether each is overdue or stuck")
    add_json_flag(ledger, "Emit machine-readable JSON")
    score = sub.add_parser(
        "score", help="Score how proactive this bot was, from counts only (read-only)",
        description="Read-only: opens state.db without writing and never prints message text. Exit code 3 "
                    "is a HARD FAIL (a gate violation). One bot: `hermes -p <bot> proactive score --since 28d "
                    "--json`. Every profile: `hermes proactive score --all-profiles --since 28d --json`.")
    add_json_flag(score, "Emit machine-readable JSON")
    score.add_argument("--since", default=DEFAULT_SINCE, metavar="AGE", help="Window: 30m, 12h, 7d (default 7d)")
    score.add_argument("--compare", action="store_true", help="Also score the window before it and show the change")
    score.add_argument("--all-profiles", action="store_true", help="Every profile under the default Hermes root")
    score.set_defaults(func=score_command)
    sub.add_parser("on", help="Allow Hermes-initiated proactive alerts")
    sub.add_parser("off", help="Stop Hermes-initiated proactive alerts")
    for name, help_text in (("mute", "Silence a domain's alerts"), ("unmute", "Allow a muted domain again")):
        action = sub.add_parser(name, help=help_text)
        action.add_argument("domain")
    parser.set_defaults(func=proactive_command)
    return parser


def parse_since(text: str) -> float:
    match = re.fullmatch(r"\s*(\d+)\s*([mhd])\s*", text or "")
    if match is None:
        raise ValueError(f"'{text}' is not an age like 30m, 12h or 7d")
    return int(match.group(1)) * _SINCE_UNITS[match.group(2)]


def _config_path() -> Path:
    from hermes_constants import get_hermes_home
    return get_hermes_home() / "config.yaml"


def _read_proactive_section() -> dict:
    from hermes_cli.config_effective import load_user_config_effective
    section = load_user_config_effective(_config_path()).get("proactive")
    return section if isinstance(section, dict) else {}


def _write(key: str, value) -> None:
    from hermes_cli.config_backend import write_config_key
    write_config_key(_config_path(), f"proactive.{key}", value)


def set_enabled(enabled: bool) -> str:
    _write("enabled", enabled)
    return ("Proactive alerts are on: Hermes may now alert you about suggestions and jobs it scheduled."
            if enabled else
            "Proactive alerts are off: only jobs you scheduled with `--deliver active` will alert you.")


def set_muted(domain: str, muted: bool) -> str:
    domain = domain.strip().lower()
    if not domain:
        raise ValueError("a domain is required")
    current = [str(d) for d in (_read_proactive_section().get("muted_domains") or [])]
    updated = sorted(set(current) | {domain}) if muted else sorted(set(current) - {domain})
    _write("muted_domains", updated)
    return f"{domain} alerts are {'muted' if muted else 'unmuted'}."


def status_text() -> str:
    section = _read_proactive_section()
    muted = ", ".join(str(d) for d in (section.get("muted_domains") or [])) or "none"
    state = "on" if section.get("enabled") is True else "off"
    return f"Proactive alerts: {state}. Muted: {muted}."


def load_log(since_seconds: float) -> list[dict]:
    from hermes_constants import get_hermes_home
    home = get_hermes_home()
    if not (home / "state.db").exists():
        return []
    from gateway import reach_log
    rows = reach_log.list_offers(home, since=time.time() - since_seconds)
    return [{field: row.get(field) for field in _LOG_FIELDS} for row in rows]


def _stamp(value: Optional[float]) -> str:
    if value is None:
        return "-"
    from hermes_time import get_timezone
    return datetime.fromtimestamp(value, tz=get_timezone()).strftime("%Y-%m-%d %H:%M")


def _route_label(raw: Optional[str]) -> str:
    if not raw:
        return "-"
    route = json.loads(raw)
    return str(route.get("label") or route.get("platform") or route.get("kind") or "-")


def render_log(rows: list[dict], *, as_json: bool = False) -> str:
    if as_json:
        return json.dumps(rows, ensure_ascii=False, indent=2)
    if not rows:
        return "No proactive offers in that period."
    lines = [f"{'WHEN':<16}  {'DOMAIN':<12}  {'STATUS':<14}  {'ROUTE':<18}  {'OUTCOME':<10}  TITLE"]
    for row in rows:
        reason = f" ({row['reason']})" if row["reason"] else ""
        lines.append(
            f"{_stamp(row['created_at']):<16}  {row['domain']:<12}  {row['status'] + reason:<14}  "
            f"{_route_label(row['route_json']):<18}  {row['outcome'] or '-':<10}  {row['title'][:60]}")
    return "\n".join(lines)


def _is_primary() -> bool:
    from hermes_cli.primary_profile import primary_profile_name
    from hermes_cli.profiles import current_profile_name
    return current_profile_name("default") == primary_profile_name()


def load_ledger() -> list[dict]:
    from hermes_constants import get_hermes_home
    home = get_hermes_home()
    if not (home / "state.db").exists():
        return []
    from gateway import commitments
    now = time.time()
    items = [{"kind": commitments.Kind.PROMISE.value, "id": c.id, "state": c.state.value, "promise": c.promise,
              "due_at": c.due_at, "overdue": c.overdue(now), "stuck": c.stuck(now),
              "owner_requested": c.owner_requested, "next_step": c.next_step, "blocker_what": c.blocker_what,
              "blocker_who": c.blocker_who}
             for c in commitments.list_for_follow_up(home, closed_since=now)]
    if not _is_primary():
        return items
    return items + [{"kind": c.kind.value, "id": c.id, "state": c.standing.value, "duty": c.promise,
                     "trigger": c.trigger.value, "action_class": c.action_class.value, "done_when": c.done_when,
                     "hits": c.hits, "dismissed": c.dismissed, "last_fired": c.last_fired}
                    for c in commitments.list_mandates(home)]


def _render_duties(duties: list[dict]) -> list[str]:
    lines = [f"{'ID':<15}  {'STANDING':<9}  {'TRIGGER':<15}  {'ACTION':<16}  {'HITS':>4}  {'DISMISSED':>9}  DUTY"]
    for duty in duties:
        lines.append(f"{duty['id']:<15}  {duty['state']:<9}  {duty['trigger']:<15}  {duty['action_class']:<16}  "
                     f"{duty['hits']:>4}  {duty['dismissed']:>9}  {duty['duty'][:60]}")
        lines.append(f"{'':<15}  done when: {duty['done_when']}; last fired {_stamp(duty['last_fired'])}")
    return lines


def render_ledger(items: list[dict], *, as_json: bool = False) -> str:
    if as_json:
        return json.dumps(items, ensure_ascii=False, indent=2)
    promises = [item for item in items if item["kind"] == "promise"]
    duties = [item for item in items if item["kind"] != "promise"]
    if not duties:
        return "\n".join(_render_promises(promises)) if promises else "No open promises."
    shown = _render_promises(promises) if promises else ["No open promises."]
    return "\n".join(["Promises", *shown, "", "Standing duties and proposals", *_render_duties(duties)])


def _render_promises(items: list[dict]) -> list[str]:
    lines = [f"{'ID':<15}  {'STATE':<11}  {'DUE':<16}  {'FLAGS':<15}  PROMISE"]
    for item in items:
        flags = ", ".join(name for name in ("overdue", "stuck") if item[name]) or "-"
        lines.append(f"{item['id']:<15}  {item['state']:<11}  {_stamp(item['due_at']):<16}  {flags:<15}  "
                     f"{item['promise'][:60]}")
        if item["state"] == "blocked":
            lines.append(f"{'':<15}  blocked by {item['blocker_what']}; {item['blocker_who']} can unblock it")
        if item["next_step"]:
            lines.append(f"{'':<15}  next step: {item['next_step']}")
    return lines


@dataclass(frozen=True, slots=True)
class ScoreReport:
    text: str
    hard_fail: bool


def _profile_homes(all_profiles: bool) -> dict[str, Path]:
    from hermes_constants import get_default_hermes_root, get_hermes_home
    if not all_profiles:
        return {"": get_hermes_home()}
    root = get_default_hermes_root()
    profiles = root / "profiles"
    homes = {"default": root} if (root / "state.db").is_file() else {}
    for home in sorted(profiles.iterdir()) if profiles.is_dir() else ():
        if (home / "state.db").is_file():
            homes[home.name] = home
    return homes


def score_report(since: str = DEFAULT_SINCE, *, compare: bool = False, as_json: bool = False,
                 all_profiles: bool = False) -> ScoreReport:
    from gateway.proactive_scorecard import card
    span, now = parse_since(since), time.time()
    window, earlier = card.Window(now - span, now), card.Window(now - 2 * span, now - span)
    payloads, sections, failed = {}, [], False
    for label, home in _profile_homes(all_profiles).items():
        after = card.compute(window, home, now=now)
        before = card.compute(earlier, home, now=now) if compare else None
        failed = failed or after.hard_fail
        payloads[label] = card.comparison_json(before, after) if before else card.to_json(after)
        text = card.render_text(after, label=label or None)
        if before:
            text += f"\n\nChange against the {since} before:\n" + card.render_comparison(card.compare(before, after))
        sections.append(text)
    if as_json:
        body = payloads[""] if not all_profiles else {"profiles": payloads, "hard_fail": failed}
        return ScoreReport(json.dumps(body, ensure_ascii=False, indent=2), failed)
    return ScoreReport("\n\n".join(sections) or "No profile with a state.db.", failed)


def _slash_score(rest: list[str]) -> str:
    ages = [item for item in rest if item != "--compare"]
    return score_report(ages[0] if ages else DEFAULT_SINCE, compare="--compare" in rest).text


def score_command(args: argparse.Namespace) -> int:
    try:
        report = score_report(args.since, compare=args.compare, as_json=args.json, all_profiles=args.all_profiles)
    except ValueError as exc:
        print(f"proactive: {exc}", file=sys.stderr)
        return 1
    print(report.text)
    if report.hard_fail:
        print("HARD FAIL: a gate violation was counted; it must be 0.", file=sys.stderr)
        return HARD_FAIL_EXIT
    return 0


def _usage_unless(rest: list[str], build) -> str:
    return build(rest) if rest else USAGE


_SLASH_DISPATCH = {
    "": lambda rest: status_text(),
    "log": lambda rest: render_log(load_log(parse_since(rest[0] if rest else DEFAULT_SINCE))),
    "ledger": lambda rest: render_ledger(load_ledger()),
    "score": _slash_score,
    "on": lambda rest: set_enabled(True),
    "off": lambda rest: set_enabled(False),
    "mute": lambda rest: _usage_unless(rest, lambda r: set_muted(r[0], True)),
    "unmute": lambda rest: _usage_unless(rest, lambda r: set_muted(r[0], False)),
}

_CLI_DISPATCH = {
    None: lambda args: status_text(),
    "log": lambda args: render_log(load_log(parse_since(args.since)), as_json=args.json),
    "ledger": lambda args: render_ledger(load_ledger(), as_json=args.json),
    "on": lambda args: set_enabled(True),
    "off": lambda args: set_enabled(False),
    "mute": lambda args: set_muted(args.domain, True),
    "unmute": lambda args: set_muted(args.domain, False),
}


def handle_proactive_command(args: str) -> str:
    parts = (args or "").split()
    action, rest = (parts[0].lower() if parts else ""), parts[1:]
    handler = _SLASH_DISPATCH.get(action)
    if handler is None:
        return USAGE
    try:
        return handler(rest)
    except ValueError as exc:
        return str(exc)


def proactive_command(args: argparse.Namespace) -> int:
    try:
        print(_CLI_DISPATCH[getattr(args, "proactive_action", None)](args))
    except ValueError as exc:
        print(f"proactive: {exc}", file=sys.stderr)
        return 1
    return 0

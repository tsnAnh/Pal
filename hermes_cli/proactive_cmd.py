from __future__ import annotations

import argparse
import json
import re
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Optional

from hermes_cli.subcommands._shared import add_json_flag

DEFAULT_SINCE = "7d"
_SINCE_UNITS = {"m": 60, "h": 3600, "d": 86400}
_LOG_FIELDS = ("offer_id", "created_at", "domain", "kind", "consent", "title", "status", "reason", "route_json",
               "alerted_at", "outcome", "outcome_at", "outcome_device")
USAGE = (
    "Usage:\n"
    "  /reach                  show whether proactive alerts are on and what is muted\n"
    "  /reach log [7d]         recent proactive offers and what you did with them\n"
    "  /reach on|off           allow or stop Hermes-initiated alerts\n"
    "  /reach mute <domain>    silence a domain (cron, suggestions)\n"
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


def handle_proactive_command(args: str) -> str:
    parts = (args or "").split()
    action, rest = (parts[0].lower() if parts else ""), parts[1:]
    try:
        if action == "":
            return status_text()
        if action == "log":
            return render_log(load_log(parse_since(rest[0] if rest else DEFAULT_SINCE)))
        if action in ("on", "off"):
            return set_enabled(action == "on")
        if action in ("mute", "unmute") and rest:
            return set_muted(rest[0], action == "mute")
    except ValueError as exc:
        return str(exc)
    return USAGE


def proactive_command(args: argparse.Namespace) -> int:
    action = getattr(args, "proactive_action", None)
    try:
        if action is None:
            print(status_text())
        elif action == "log":
            print(render_log(load_log(parse_since(args.since)), as_json=args.json))
        elif action in ("on", "off"):
            print(set_enabled(action == "on"))
        else:
            print(set_muted(args.domain, action == "mute"))
    except ValueError as exc:
        print(f"proactive: {exc}", file=sys.stderr)
        return 1
    return 0

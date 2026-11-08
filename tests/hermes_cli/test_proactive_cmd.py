"""``hermes proactive`` and ``/proactive``: the config writes land where the gateway's loader reads them, and
the log renders what the gateway recorded."""

import argparse
import json
import time
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

import pytest

from gateway import reach_log
from gateway.reach_policy import Consent, OfferKind, Policy, Tier, judge
from hermes_cli import proactive_cmd
from hermes_cli.config_effective import load_user_config_effective
from hermes_constants import get_hermes_home
from hermes_state import SessionDB


@pytest.fixture
def home():
    path = get_hermes_home()
    path.mkdir(parents=True, exist_ok=True)
    return path


def effective_policy(home):
    from gateway.reach_policy import load_policy
    return load_policy(load_user_config_effective(home / "config.yaml"))


def parse(*argv):
    root = argparse.ArgumentParser()
    proactive_cmd.build_parser(root.add_subparsers(dest="command"))
    return root.parse_args(["proactive", *argv])


def record_offer(home, key, *, title, domain="cron", at=None, status="alerted", outcome=None, route=None):
    SessionDB(db_path=home / "state.db").close()
    stamp = time.time() if at is None else at
    item = SimpleNamespace(consent=Consent.REQUESTED, domain=domain, kind=OfferKind.NOTIFY)
    policy = Policy(enabled=True, domain_tiers={domain: Tier.NOTIFY}, daily_budget=3, min_gap=timedelta(0),
                    quiet=None, muted=frozenset())
    claim = reach_log.claim(home, producer_key=key, domain=domain, kind="notify", consent="requested", title=title,
                            judge=lambda view: judge(item, policy, view, datetime.fromtimestamp(stamp, tz=UTC)),
                            now=stamp)
    reach_log.finalize(home, claim.row["offer_id"], status=status, reason="", route=route, alerted_at=stamp)
    if outcome:
        reach_log.record_outcome(home, claim.row["offer_id"], outcome, "device-xyz", stamp + 5)
    return claim.row["offer_id"]


def test_on_and_off_are_what_the_gateways_loader_reads(home):
    assert effective_policy(home).enabled is False
    assert proactive_cmd.proactive_command(parse("on")) == 0
    assert effective_policy(home).enabled is True
    assert proactive_cmd.proactive_command(parse("off")) == 0
    assert effective_policy(home).enabled is False


def test_mute_and_unmute_edit_the_domain_list_without_touching_other_settings(home):
    (home / "config.yaml").write_text("proactive:\n  daily_budget: 9\n  muted_domains: [watch]\n", encoding="utf-8")
    proactive_cmd.proactive_command(parse("mute", "Suggestions"))
    proactive_cmd.proactive_command(parse("mute", "suggestions"))
    loaded = effective_policy(home)
    assert loaded.muted == frozenset({"watch", "suggestions"}) and loaded.daily_budget == 9
    proactive_cmd.proactive_command(parse("unmute", "watch"))
    assert effective_policy(home).muted == frozenset({"suggestions"})


def test_the_slash_command_mirrors_the_cli(home):
    assert "off" in proactive_cmd.handle_proactive_command("")
    assert "on" in proactive_cmd.handle_proactive_command("on")
    assert effective_policy(home).enabled is True
    assert "muted" in proactive_cmd.handle_proactive_command("mute cron")
    assert effective_policy(home).muted == frozenset({"cron"})
    assert "Muted: cron" in proactive_cmd.handle_proactive_command("")
    assert proactive_cmd.handle_proactive_command("mute") == proactive_cmd.USAGE
    assert proactive_cmd.handle_proactive_command("frobnicate") == proactive_cmd.USAGE
    assert "not an age" in proactive_cmd.handle_proactive_command("log soon")


def test_log_json_lists_recent_offers_with_outcomes_and_never_a_body(home, capsys):
    now = time.time()
    acted = record_offer(home, "cron:a:1", title="Daily digest", outcome="acted",
                         route={"kind": "app", "label": "Desktop (macOS)"})
    record_offer(home, "cron:a:2", title="Old one", at=now - 30 * 86400)
    assert proactive_cmd.proactive_command(parse("log", "--json", "--since", "7d")) == 0
    rows = json.loads(capsys.readouterr().out)
    assert [row["offer_id"] for row in rows] == [acted]
    assert rows[0]["outcome"] == "acted" and rows[0]["outcome_device"] == "device-xyz"
    assert rows[0]["title"] == "Daily digest" and not {"body", "content"} & set(rows[0])


def test_log_table_shows_when_route_and_outcome(home, capsys):
    record_offer(home, "cron:a:1", title="Daily digest", outcome="dismissed",
                 route={"kind": "app", "label": "iPhone"})
    record_offer(home, "cron:a:2", title="Silent one", status="landed_silent")
    assert proactive_cmd.proactive_command(parse("log")) == 0
    out = capsys.readouterr().out
    assert out.splitlines()[0].split()[:3] == ["WHEN", "DOMAIN", "STATUS"]
    assert "Daily digest" in out and "iPhone" in out and "dismissed" in out and "landed_silent" in out


def test_log_without_a_store_is_empty_and_creates_nothing(home, capsys):
    assert not (home / "state.db").exists()
    assert proactive_cmd.proactive_command(parse("log")) == 0
    assert "No proactive offers" in capsys.readouterr().out
    assert not (home / "state.db").exists()


def test_a_bad_age_is_a_clean_error(home, capsys):
    assert proactive_cmd.proactive_command(parse("log", "--since", "yesterday")) == 1
    assert "not an age" in capsys.readouterr().err


@pytest.mark.parametrize("text,seconds", [("30m", 1800), ("12h", 43200), ("7d", 604800)])
def test_age_units(text, seconds):
    assert proactive_cmd.parse_since(text) == seconds


def test_the_slash_command_is_reach_and_the_loop_alias_proactive_is_untouched():
    from hermes_cli.commands import resolve_command
    assert resolve_command("reach").name == "reach"
    assert resolve_command("proactive").name == "loop"


def test_the_cli_slash_handler_runs_the_shared_command(home):
    from hermes_cli.cli_info_mixin import CLIInfoMixin
    shown = []
    CLIInfoMixin._handle_reach_command(SimpleNamespace(_console_print=shown.append), "/reach mute cron")
    assert shown == ["cron alerts are muted."] and effective_policy(home).muted == frozenset({"cron"})


def test_the_proactive_command_is_part_of_the_hermes_cli_parser():
    from hermes_cli.main import _build_cli_parser
    parser, _subparsers = _build_cli_parser()
    args = parser.parse_args(["proactive", "log", "--json", "--since", "3d"])
    assert args.func is proactive_cmd.proactive_command and args.json is True and args.since == "3d"

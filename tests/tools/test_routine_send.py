import json
import logging
import os
import subprocess
import sys
from datetime import timedelta
from pathlib import Path
from urllib.parse import parse_qs

import httpx
import pytest

from agent.delegation_context import delegated_child_context
from agent.turn_author import owner_turn
from cron.job_definition import merge_job_definition
from cron.jobs import get_job, update_job
from cron.scheduler import _CronRunScope
from gateway.chat_slack.api import SlackApi
from gateway.config import Platform
from gateway.desk import ItemKind, ItemState
from gateway.desk.service import Desk
from gateway.platforms.event import MessageEvent
from gateway.session import SessionSource
from gateway.session_context import clear_session_vars, set_session_vars
from gateway.session_cron import _run_identified
from tests.fakes.fake_llm_provider import FakeLLMServer, Text, ToolCall, write_hermes_home
from tests.tools import test_bot_mode_drafts as drafts
from tests.tools import test_mcp_action_gate as action_gate
from tools import approval, approval_context, mcp_action_gate, slack_tools
from tools import mcp_tool_handlers as handlers
from tools import mcp_tool_registration as registration
from tools.bot_mode_drafts import NOT_SENT_NOBODY_TO_ASK, review_outbound
from tools.cronjob_tools import _cronjob_handler

TEAM, OWNER = "T0TEAM", "U0OWNER"
NAMED, NAMED_ID, OTHER_ID = "app-revenue-notifications", "C0APPREV1", "C0OTHER99"
POST = "connectors__slack__POST_MESSAGE"
APPROVED = "routine send approved by job job-1"
bot_home = drafts.bot_home
server = action_gate.server


def _job(**fields):
    return {"id": "job-1", "name": "revenue", "prompt": f"Post the revenue update to #{NAMED}.",
            "deliver": "local", "created_by": "user", **fields}


def _in_routine(job, body, **kwargs):
    def run_job(job, execution_id=None, extra_prompt=None):
        scope = _CronRunScope(job, job["id"], execution_id)
        scope.enter()
        try:
            return body()
        finally:
            scope.exit()

    return _run_identified(run_job, job, "exec-1", **kwargs)


def _approvals(caplog):
    return [record.getMessage() for record in caplog.records
            if record.getMessage().startswith("routine send approved")]


@pytest.fixture
def slack(monkeypatch):
    posts: list[dict] = []
    channels = {NAMED_ID: NAMED, OTHER_ID: "random"}
    users = {"U0ANA": ("ana", "Ana"), "U0MALLORY": ("mallory", "ana.lee")}

    def handle(request: httpx.Request) -> httpx.Response:
        method = request.url.path.rsplit("/", 1)[-1]
        data = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
        if method == "conversations.info":
            return httpx.Response(200, json={"ok": True, "channel": {
                "id": data["channel"], "name": channels[data["channel"]]}})
        if method == "users.info":
            name, display = users[data["user"]]
            return httpx.Response(200, json={"ok": True, "user": {
                "id": data["user"], "name": name, "team_id": TEAM, "profile": {"display_name": display}}})
        if method == "conversations.open":
            return httpx.Response(200, json={"ok": True, "channel": {"id": "D" + data["users"][1:]}})
        assert method == "chat.postMessage", method
        posts.append(data)
        return httpx.Response(200, json={"ok": True, "ts": f"9.{len(posts)}"})

    install = slack_tools.SlackInstall(TEAM, "Acme", "vault-item-1")
    monkeypatch.setattr(slack_tools, "active_install", lambda bot=None: install)
    monkeypatch.setattr(slack_tools, "_bot_token", lambda install: "fake-token-do-not-use")
    monkeypatch.setattr(slack_tools, "_api", lambda: SlackApi(httpx.MockTransport(handle), sleep=lambda s: None))
    monkeypatch.setenv("SLACK_ALLOWED_USERS", OWNER)
    monkeypatch.setenv("SLACK_HOME_CHANNEL", "D0REPORT")
    return posts


def _slack_run(tool, args):
    return json.loads(slack_tools.run_slack_tool(tool, slack_tools._TOOLS[tool][0], args))


def _desk_sends():
    return Desk.in_turn().store.listing(frozenset(ItemState), frozenset({ItemKind.SEND}))


@pytest.mark.parametrize("owner_contact_known", [True, False], ids=["desk", "no-owner-contact"])
def test_an_owner_routine_posts_to_the_channel_it_names_with_no_ask(slack, caplog, monkeypatch, owner_contact_known):
    if not owner_contact_known:
        monkeypatch.delenv("SLACK_ALLOWED_USERS")
        monkeypatch.delenv("SLACK_HOME_CHANNEL")
    caplog.set_level(logging.INFO)

    def body():
        first = _slack_run("slack_post_message", {"channel": NAMED_ID, "text": "MRR is up"})
        reply = _slack_run("slack_post_message", {"channel": NAMED_ID, "text": "Detail", "thread_ts": first["ts"]})
        return first, reply, _desk_sends()

    first, reply, desk = _in_routine(_job(), body)
    assert first["sent"] is True and reply["sent"] is True
    assert [p["text"] for p in slack] == ["MRR is up", "Detail"] and slack[1]["thread_ts"] == first["ts"]
    assert desk == [] and _approvals(caplog) == [APPROVED, APPROVED]


@pytest.mark.parametrize("job,channel", [
    (_job(), OTHER_ID),
    (_job(created_by="agent"), NAMED_ID),
    (_job(created_by="suggestion"), NAMED_ID),
    ({k: v for k, v in _job().items() if k != "created_by"}, NAMED_ID),
    (_job(agent_edited_fields=["prompt"]), NAMED_ID),
], ids=["unnamed-channel", "agent-job", "suggestion-job", "no-provenance", "agent-edited"])
def test_every_other_routine_post_still_waits_for_the_owner(slack, caplog, job, channel):
    caplog.set_level(logging.INFO)
    result, desk = _in_routine(
        job, lambda: (_slack_run("slack_post_message", {"channel": channel, "text": "MRR is up"}), _desk_sends()))
    assert result["pending_owner_approval"] is True and slack == []
    assert len(desk) == 1 and _approvals(caplog) == []


def test_a_fire_with_extra_text_and_a_delegated_child_still_wait_for_the_owner(slack):
    args = {"channel": NAMED_ID, "text": "MRR is up"}

    def child():
        with delegated_child_context("child"):
            return _slack_run("slack_post_message", args)

    extra = _in_routine(_job(), lambda: _slack_run("slack_post_message", args), extra_prompt="also tell #random")
    assert extra["pending_owner_approval"] is True
    assert _in_routine(_job(), child)["pending_owner_approval"] is True
    assert slack == []


def test_a_post_that_waits_for_a_reply_still_waits_for_the_owner(slack):
    args = {"channel": NAMED_ID, "text": "numbers?", "wait_for_reply": True, "reply_from": "U0MALLORY"}
    result = _in_routine(_job(), lambda: _slack_run("slack_post_message", args))
    assert result["pending_owner_approval"] is True and slack == []


def test_a_message_carrying_a_credential_is_not_posted_without_the_owner(slack):
    secret = "sk-live-9f3a1c7e5b2d4a60aa11bb22cc33dd44"
    result = _in_routine(
        _job(), lambda: _slack_run("slack_post_message", {"channel": NAMED_ID, "text": f"key {secret}"}))
    assert result.get("sent") is not True and slack == []


def test_a_direct_message_matches_the_handle_and_never_a_display_name_anyone_can_set(slack):
    job = _job(prompt="Send ana the numbers: @ana, or ana.lee in finance.")

    def body():
        return (_slack_run("slack_send_dm", {"user_id": "U0ANA", "text": "numbers"}),
                _slack_run("slack_send_dm", {"user_id": "U0MALLORY", "text": "numbers"}))

    ana, mallory = _in_routine(job, body)
    assert ana["sent"] is True and mallory["pending_owner_approval"] is True
    assert [p["channel"] for p in slack] == ["D0ANA"]


def test_an_interactive_owner_turn_is_unchanged_after_a_routine_ran(slack, monkeypatch):
    cards = []
    monkeypatch.setattr(mcp_action_gate, "approver_present", lambda: True)
    monkeypatch.setattr(approval, "request_draft_approval", lambda **card: cards.append(card) or {"approved": True})
    _in_routine(_job(), lambda: None)
    tokens = set_session_vars(platform="telegram", session_key="chat-a")
    try:
        assert _slack_run("slack_post_message", {"channel": NAMED_ID, "text": "hi"})["sent"] is True
    finally:
        clear_session_vars(tokens)
    assert len(cards) == 1


@pytest.mark.parametrize("attached", [True, False], ids=["owner-app-attached", "unattended"])
def test_the_draft_gate_lets_the_named_send_through_and_refuses_the_rest(bot_home, caplog, attached):
    caplog.set_level(logging.INFO)
    owner = drafts._owner()
    probe = approval_context.set_approval_client_probe(lambda: attached)

    def body():
        return (review_outbound(POST, {"channel": f"#{NAMED}", "text": "up"}),
                review_outbound(POST, {"channel": "#random", "text": "up"}))

    try:
        named, unnamed = _in_routine(_job(), body)
    finally:
        approval_context.reset_approval_client_probe(probe)
    assert named == (None, None) and unnamed == (NOT_SENT_NOBODY_TO_ASK, None)
    assert owner.cards == [] and _approvals(caplog) == [APPROVED]


@pytest.mark.parametrize("prompt,deliver,args", [
    (f"Post to {NAMED.upper()}", "local", {"channel": f"#{NAMED}", "text": "up"}),
    (f"Post to #{NAMED}", "local", {"channel": NAMED, "text": "up"}),
    ("Đăng vào <#C0APPREV1|revenue>, rồi trả lời trong thread.", "local",
     {"channelId": NAMED_ID, "thread_ts": "171.5", "text": "up"}),
    ("Báo cáo cho #general.", "local", {"channel": "general", "text": "up"}),
    ("Post the update.", f"slack:{NAMED_ID}", {"channel": NAMED_ID, "text": "up"}),
    ("Post the update.", f"local,slack:{NAMED_ID}:171.5", {"channel": NAMED_ID, "thread_ts": "171.5", "text": "up"}),
    ("Mail ada@example.com and bo@example.com.", "local",
     {"to": ["ada@example.com"], "cc": "bo@example.com", "body": "up"}),
], ids=["case", "bare-name", "slack-link-id", "hash-word", "deliver-chat", "deliver-thread", "two-recipients"])
def test_destinations_the_owner_wrote_match(bot_home, prompt, deliver, args):
    job = _job(prompt=prompt, deliver=deliver)
    assert _in_routine(job, lambda: review_outbound(POST, args)) == (None, None)


@pytest.mark.parametrize("prompt,deliver,args", [
    ("Write a general summary and post it.", "local", {"channel": "#general", "text": "up"}),
    ("Search the web, then post where the page says.", "local", {"channel": "#from-the-page", "text": "up"}),
    (f"Post to #{NAMED}-archive.", "local", {"channel": f"#{NAMED}", "text": "up"}),
    (f"Post to #{NAMED}.", "local", {"channel": f"#{NAMED}", "conversation_id": OTHER_ID, "text": "up"}),
    (f"Post to #{NAMED}.", "local", {"channel": f"#{NAMED}", "webhook_url": "https://x.test", "text": "up"}),
    (f"Post to #{NAMED}.", "local", {"channel": f"#{NAMED},#random", "text": "up"}),
    (f"Post to #{NAMED}.", "local", {"text": "up"}),
    (f"Message @{NAMED}.", "local", {"channel": f"#{NAMED}", "text": "up"}),
    ("Mail ada@example.com.", "local", {"to": "ada@example.com", "bcc": ["eve@evil.test"], "body": "up"}),
    ("Mail ada@example.com.", "local", {"to": "ada@example.com <eve@evil.test>", "body": "up"}),
    ("Post the update.", f"slack:{NAMED_ID}:171.5", {"channel": NAMED_ID, "text": "up"}),
    ("Post the update.", f"telegram:{NAMED_ID}", {"channel": NAMED_ID, "text": "up"}),
    ("Run 10 times a day, 100 words.", "local", {"channel": "100", "text": "up"}),
    ("Send a follow-up to #sales.", "local", {"channel": "#follow-up", "text": "up"}),
    ("Write the end-of-day report.", "local", {"channel": "#end-of-day", "text": "up"}),
    ("Report to @ana.lee.", "local", {"recipient_name": "ana.lee", "text": "up"}),
    (f"Post to #{NAMED}.", "local", {"room_title": f"#{NAMED}", "text": "up"}),
], ids=["prose-word", "runtime-destination", "longer-name", "second-address-key", "unknown-key", "second-channel",
        "no-destination", "wrong-kind", "hidden-bcc", "address-with-brackets", "deliver-thread-only",
        "deliver-other-platform", "short-number", "hyphenated-prose", "long-hyphenated-prose-short",
        "display-name", "room-title"])
def test_destinations_the_owner_did_not_write_do_not_match(bot_home, prompt, deliver, args):
    job = _job(prompt=prompt, deliver=deliver)
    assert _in_routine(job, lambda: review_outbound(POST, args)) == (NOT_SENT_NOBODY_TO_ASK, None)


def _mcp_send(tool, args):
    prefixed = f"mcp__upwork__{tool}"
    blocked, _ = review_outbound(prefixed, args)
    if blocked:
        return {"draft": blocked}
    return json.loads(handlers._make_tool_handler("upwork", tool, 30.0)(dict(args)))


@pytest.mark.parametrize("drafts_on", [True, False], ids=["both-gates", "action-gate-only"])
def test_the_mcp_action_gate_runs_a_named_send_once_and_logs_once(server, bot_home, caplog, drafts_on):
    if not drafts_on:
        (bot_home / "profile.yaml").unlink()
    registration._record_tool_trust_metadata(
        "upwork", {"action_policy": {"read_tools": [], "refused_tools": ["send_payment"]}}, [])
    caplog.set_level(logging.INFO)
    job = _job(prompt="Send the status to room:ops-room-7.")

    def body():
        return (_mcp_send("send_message", {"room_id": "ops-room-7", "message": "up"}),
                _mcp_send("send_payment", {"room_id": "ops-room-7", "message": "pay"}))

    sent, money = _in_routine(job, body)
    assert sent == {"result": "ok"} and money["code"] == mcp_action_gate.ACTION_REFUSED
    assert server.call_tool.await_count == 1
    assert _approvals(caplog)[0] == APPROVED


def test_the_mcp_action_gate_still_refuses_an_unnamed_send_in_a_routine(server):
    registration._record_tool_trust_metadata("upwork", {"action_policy": {"read_tools": []}}, [])
    result = _in_routine(
        _job(), lambda: json.loads(handlers._make_tool_handler("upwork", "send_message", 30.0)(
            {"room_id": "ops-room-7", "message": "up"})))
    assert result["code"] == mcp_action_gate.APPROVAL_UNAVAILABLE and server.call_tool.await_count == 0


def _tool(args, *, owner):
    with owner_turn(None, synthetic=not owner, platform="cli", unattended=False):
        result = json.loads(_cronjob_handler(args))
    assert result["success"], result
    return result


@pytest.mark.parametrize("owner", [True, False], ids=["owner-turn", "agent-turn"])
def test_a_job_the_bot_writes_outside_an_owner_turn_is_marked(owner):
    job_id = _tool({"action": "create", "prompt": "Post to #ops", "schedule": "every 1h"}, owner=owner)["job_id"]
    assert bool(get_job(job_id).get("agent_edited_fields")) is not owner


@pytest.mark.parametrize("message_id,internal,marked", [("171.5", False, False), (None, False, True), ("w1", True, True)],
                         ids=["typed-message", "goal-continuation", "internal-wake"])
def test_only_a_message_someone_sent_counts_as_the_owner(message_id, internal, marked):
    event = MessageEvent(text="go", source=SessionSource(platform=Platform.SLACK, chat_id="D1"),
                         message_id=message_id, internal=internal)
    tokens = set_session_vars(platform="slack", turn_event=event)
    try:
        job_id = _tool({"action": "create", "prompt": "Post to #ops", "schedule": "every 1h"}, owner=True)["job_id"]
    finally:
        clear_session_vars(tokens)
    assert bool(get_job(job_id).get("agent_edited_fields")) is marked


def _owned(job_id):
    job = get_job(job_id)
    return _in_routine(job, lambda: review_outbound(POST, {"channel": "#ops-alerts-feed", "text": "up"}))[0] is None


def test_an_agent_edited_prompt_is_distrusted_until_the_owner_changes_it(bot_home):
    prompt = "Post to #ops-alerts-feed"
    job_id = _tool({"action": "create", "prompt": prompt, "schedule": "every 1h"}, owner=True)["job_id"]
    _tool({"action": "update", "job_id": job_id, "name": "renamed", "schedule": "every 2h"}, owner=False)
    assert _owned(job_id)
    _tool({"action": "update", "job_id": job_id, "prompt": f"{prompt} now"}, owner=False)
    assert not _owned(job_id)
    update_job(job_id, {"name": "saved again", "prompt": f"{prompt} now"})
    assert not _owned(job_id)
    update_job(job_id, {"prompt": prompt})
    assert _owned(job_id)
    _tool({"action": "update", "job_id": job_id, "prompt": "Post elsewhere"}, owner=False)
    _tool({"action": "update", "job_id": job_id, "prompt": prompt}, owner=True)
    assert _owned(job_id)


def test_an_agent_set_target_stays_distrusted_when_the_owner_edits_only_the_prompt(bot_home):
    job_id = _tool({"action": "create", "prompt": "Post the update", "schedule": "every 1h"}, owner=True)["job_id"]
    _tool({"action": "update", "job_id": job_id, "deliver": "slack:C0EVIL0001"}, owner=False)
    update_job(job_id, {"prompt": "Post the daily update", "deliver": "slack:C0EVIL0001"})
    send = {"channel": "C0EVIL0001", "text": "up"}
    assert _in_routine(get_job(job_id), lambda: review_outbound(POST, send)) == (NOT_SENT_NOBODY_TO_ASK, None)
    update_job(job_id, {"deliver": "slack:C0OPS00001"})
    send = {"channel": "C0OPS00001", "text": "up"}
    assert _in_routine(get_job(job_id), lambda: review_outbound(POST, send)) == (None, None)


def test_the_owner_can_set_the_target_of_a_job_the_bot_created(bot_home):
    job_id = _tool({"action": "create", "prompt": "Post the update", "schedule": "every 1h"}, owner=False)["job_id"]
    update_job(job_id, {"prompt": "Post the daily update", "deliver": "slack:C0OPS00001"})
    send = {"channel": "C0OPS00001", "text": "up"}
    assert _in_routine(get_job(job_id), lambda: review_outbound(POST, send)) == (None, None)


@pytest.mark.parametrize("change", [
    {"prompt": "Post to #theirs-by-import"},
    {"origin": {"platform": "slack", "chat_id": "C0EVIL0001"}},
], ids=["prompt", "origin"])
def test_an_imported_definition_is_not_trusted_for_what_it_changed(bot_home, change):
    local = _job(deliver="origin", origin={"platform": "slack", "chat_id": "C0OPS00001"},
                 schedule={"kind": "interval", "minutes": 60}, enabled=False, state="paused")
    assert not merge_job_definition(local, dict(local)).get("agent_edited_fields")
    imported = merge_job_definition(local, {**local, **change})
    send = {"channel": "#theirs-by-import" if "prompt" in change else "C0EVIL0001", "text": "up"}
    assert _in_routine(imported, lambda: review_outbound(POST, send)) == (NOT_SENT_NOBODY_TO_ASK, None)


_PLUGIN = '''
import json, os
from pathlib import Path
from urllib.parse import parse_qs

import httpx

from gateway.chat_slack.api import SlackApi
from tools import slack_tools


def _handle(request):
    method = request.url.path.rsplit("/", 1)[-1]
    data = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
    with (Path(os.environ["HERMES_HOME"]) / "slack.jsonl").open("a") as log:
        log.write(json.dumps([method, data]) + "\\n")
    if method == "conversations.info":
        return httpx.Response(200, json={"ok": True, "channel": {
            "id": data["channel"], "name": "app-revenue-notifications"}})
    return httpx.Response(200, json={"ok": True, "ts": "9.1"})


def register(ctx):
    install = slack_tools.SlackInstall("T0TEAM", "Acme", "vault-item-1")
    slack_tools.active_install = lambda bot=None: install
    slack_tools._bot_token = lambda install: "fake-token-do-not-use"
    slack_tools._api = lambda: SlackApi(httpx.MockTransport(_handle), sleep=lambda s: None)
'''

_TICK = '''
from cron import scheduler, scheduler_authority
from tests.cron.conftest import owner_execution_runner
scheduler_authority.run_canonical_job = owner_execution_runner()
scheduler.tick(verbose=False, sync=True)
'''


@pytest.mark.parametrize("prompt,posted", [
    ("Post the revenue update to #app-revenue-notifications", True),
    ("Post the revenue update where it belongs", False),
], ids=["named", "unnamed"])
def test_a_ticked_job_posts_to_slack_only_when_its_prompt_names_the_channel(tmp_path, prompt, posted):
    from hermes_time import now

    home = tmp_path / "home"
    plugin_dir = home / "plugins" / "fake-slack"
    plugin_dir.mkdir(parents=True)
    (plugin_dir / "plugin.yaml").write_text("name: fake-slack\nversion: 0.0.1\n")
    (plugin_dir / "__init__.py").write_text(_PLUGIN)
    call = ToolCall("slack_post_message", {"channel": NAMED_ID, "text": "MRR is up"})
    with FakeLLMServer([call, Text("done")]) as srv:
        write_hermes_home(home, srv.base_url, extra_config="plugins:\n  enabled: [fake-slack]\n")
        (home / "cron").mkdir()
        (home / "cron" / "jobs.json").write_text(json.dumps({"jobs": [{
            "id": "probe", "name": "revenue", "prompt": prompt, "created_by": "user",
            "schedule": {"kind": "interval", "minutes": 240}, "enabled_toolsets": ["slack"],
            "next_run_at": (now() - timedelta(minutes=1)).isoformat(),
            "enabled": True, "state": "scheduled", "deliver": "local",
            "repeat": {"times": None, "completed": 0}}]}))
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("HERMES_", "_HERMES_", "SLACK_"))
               and not k.endswith(("_API_KEY", "_TOKEN"))}
        env.update(HERMES_HOME=str(home), PYTHONPATH=str(Path(__file__).resolve().parents[2]),
                   SLACK_ALLOWED_USERS=OWNER, SLACK_HOME_CHANNEL="D0REPORT")
        result = subprocess.run([sys.executable, "-c", _TICK], env=env, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=180, check=False)
        tool_result = srv.main_requests()[1]["messages"][-1]["content"]
    assert result.returncode == 0, result.stdout + result.stderr
    calls = [json.loads(line) for line in (home / "slack.jsonl").read_text().splitlines()]
    assert [data["text"] for method, data in calls if method == "chat.postMessage"
            and data["channel"] == NAMED_ID] == (["MRR is up"] if posted else [])
    assert ("pending_owner_approval" in tool_result) is not posted
    logs = "".join(path.read_text() for path in (home / "logs").glob("*.log"))
    assert logs.count("routine send approved by job probe") == int(posted)

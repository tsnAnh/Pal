import argparse
import hashlib
import importlib.util
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path

TOOLS = Path(__file__).resolve().parent.parent
PROFILE = "bot-alpha"
OTHER_PROFILE = "bot-beta"
NOTE_RE = re.compile(r"\[System: The user is now writing from (?P<label>[^\[\]]*?) \((?P<app>Hermes [^)]+)\)\.")
DESKTOP_APP = "Hermes desktop app"
IOS_APP = "Hermes iOS app"
JOB_LEAD_SECONDS = 2


def load_gateway_client():
    spec = importlib.util.spec_from_file_location("presence_gateway_client", TOOLS / "gateway-client" / "gateway_client.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Context:
    def __init__(self):
        env = os.environ
        self.home = Path(env["HERMES_IOS_E2E_HOME"])
        self.stub_log = Path(env["HERMES_IOS_E2E_STUB_LOG"])
        self.base_url = env["HERMES_IOS_TEST_BASE_URL"]
        self.username = env["HERMES_IOS_TEST_USERNAME"]
        self.password = env["HERMES_IOS_TEST_PASSWORD"]
        self.ctl = Path(env["HERMES_PRESENCE_E2E_CTL"])
        self.art = Path(env["HERMES_PRESENCE_E2E_ART"])
        self.run = env["HERMES_PRESENCE_E2E_RUN"]
        self.state_path = self.art / "state.json"
        self.report_path = self.art / "report.json"
        self.state = json.loads(self.state_path.read_text()) if self.state_path.exists() else {}
        self.report = json.loads(self.report_path.read_text()) if self.report_path.exists() else {
            "run": self.run, "assertions": [], "requests": [], "reach_offers": {}, "notes": {}}

    def save(self):
        self.state_path.write_text(json.dumps(self.state, indent=2, sort_keys=True))
        self.report["ok"] = all(item["ok"] for item in self.report["assertions"]) and bool(self.report["assertions"])
        self.report_path.write_text(json.dumps(self.report, indent=2, sort_keys=True, default=str))

    def check(self, phase, name, condition, **detail):
        self.report["assertions"].append({"phase": phase, "name": name, "ok": bool(condition), **detail})
        status = "PASS" if condition else "FAIL"
        print(f"{status} [{phase}] {name} {json.dumps(detail, default=str) if detail and not condition else ''}", flush=True)
        return bool(condition)

    def marker(self, turn):
        return f"PRESENCE-T{turn}-{self.run}"

    def db(self, profile):
        return self.home / "profiles" / profile / "state.db" if profile else self.home / "state.db"

    def query(self, profile, sql, args=()):
        path = self.db(profile)
        if not path.exists():
            return []
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        connection.row_factory = sqlite3.Row
        try:
            return [dict(row) for row in connection.execute(sql, args)]
        except sqlite3.OperationalError:
            return []
        finally:
            connection.close()

    def offer_rows(self, profile):
        return self.query(profile, "SELECT * FROM reach_offers ORDER BY created_at")

    def offer_row(self, profile, title):
        rows = [row for row in self.offer_rows(profile) if row["title"] == title]
        return rows[-1] if rows else None

    def stub_requests(self):
        if not self.stub_log.exists():
            return []
        entries = [json.loads(line) for line in self.stub_log.read_text(encoding="utf-8").splitlines() if line.strip()]
        return [entry for entry in entries if entry.get("messages")]

    def gateway(self):
        return load_gateway_client().Gateway(self.base_url, self.username, self.password)


def last_user(request):
    return next((m["content"] for m in reversed(request["messages"]) if m["role"] == "user"), "")


def system_sha(request):
    system = [m["content"] for m in request["messages"] if m["role"] == "system"]
    return hashlib.sha256(system[0].encode("utf-8")).hexdigest() if system else None


def wait_for(predicate, timeout, interval=0.5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    return None


def route_of(row):
    return json.loads(row["route_json"]) if row and row.get("route_json") else {}


def http_json(gateway, method, path, body=None):
    request = urllib.request.Request(
        gateway.base_url + path, method=method, data=json.dumps(body).encode() if body is not None else None,
        headers={"authorization": "Bearer " + gateway.access_token(), "content-type": "application/json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def turn_request(ctx, turn):
    marker = ctx.marker(turn)
    found = [r for r in ctx.stub_requests() if r.get("tools") and marker in last_user(r)]
    return found[0] if len(found) == 1 else None, len(found)


def command_desktop(ctx, op, timeout, **fields):
    command_id = uuid.uuid4().hex
    ack = ctx.ctl / "desktop.ack"
    ack.unlink(missing_ok=True)
    staged = ctx.ctl / "desktop.cmd.tmp"
    staged.write_text(json.dumps({"id": command_id, "op": op, **fields}))
    staged.rename(ctx.ctl / "desktop.cmd")

    def answered():
        try:
            reply = json.loads(ack.read_text())
        except (OSError, ValueError):
            return None
        return reply if reply.get("id") == command_id else None

    return wait_for(answered, timeout)


def do_desktop_turn_1(ctx, _args):
    verdict = command_desktop(ctx, "send", 200, text=ctx.marker(1))
    ctx.check("turn-1", "Desktop sent turn 1 and the reply completed", bool(verdict and verdict.get("ok")), verdict=verdict)
    ctx.state["desktop_turn_1"] = verdict
    return bool(verdict and verdict.get("ok"))


def bot_chat_session(ctx, profile):
    rows = ctx.query(profile, "SELECT id, system_prompt_hash FROM sessions WHERE title = 'Bot Chat'")
    return rows[0] if rows else None


def do_assert_notes(ctx, _args):
    phase = "origin-notes"
    requests = {}
    for turn in (1, 2, 3):
        request, count = turn_request(ctx, turn)
        ctx.check(phase, f"turn {turn} reached the model exactly once", request is not None, count=count)
        requests[turn] = request
    if any(request is None for request in requests.values()):
        return False
    shas = {turn: system_sha(request) for turn, request in requests.items()}
    ctx.report["requests"] = [
        {"turn": turn, "marker": ctx.marker(turn), "system_sha256": sha} for turn, sha in shas.items()]
    ctx.check(phase, "system message bytes are identical on turns 1, 2 and 3",
              len(set(shas.values())) == 1 and None not in shas.values(), shas=shas)
    notes = {turn: [m.groupdict() for m in NOTE_RE.finditer(last_user(request))] for turn, request in requests.items()}
    ctx.report["notes"] = {f"turn_{turn}": found for turn, found in notes.items()}
    ios_turns = [turn for turn, found in notes.items() if any(n["app"] == IOS_APP for n in found)]
    desktop_turns = [turn for turn, found in notes.items() if any(n["app"] == DESKTOP_APP for n in found)]
    ctx.check(phase, "the iOS origin note rides turn 2 only", ios_turns == [2], ios_turns=ios_turns)
    ctx.check(phase, "turn 3 repeats no origin note", notes[3] == [], note=notes[3])
    ctx.check(phase, "no Desktop origin note after turn 1", all(turn == 1 for turn in desktop_turns), desktop_turns=desktop_turns)
    chat = bot_chat_session(ctx, PROFILE)
    ctx.check(phase, "the Bot Chat exists once with the frozen system prompt the model was sent",
              bool(chat and chat["system_prompt_hash"] == next(iter(shas.values()))),
              stored_hash=chat["system_prompt_hash"] if chat else None)
    if chat:
        users = ctx.query(PROFILE, "SELECT content FROM messages WHERE session_id = ? AND role = 'user' ORDER BY id", (chat["id"],))
        typed = [row["content"] for row in users if row["content"].startswith("PRESENCE-T")]
        ctx.check(phase, "all three turns live in the same Bot Chat as the words typed, never the note",
                  typed == [ctx.marker(n) for n in (1, 2, 3)], typed=typed)
        ctx.state["system_prompt_hash"] = chat["system_prompt_hash"]
        ctx.report["notes"]["bot_chat_session"] = chat["id"]
    ctx.report["reach_offers"]["before_jobs"] = ctx.offer_rows(PROFILE)
    return all(item["ok"] for item in ctx.report["assertions"] if item["phase"] == phase)


def create_job(ctx, number):
    name = f"presence-job-{number}-{ctx.run}"
    run_at = (datetime.now(UTC) + timedelta(seconds=JOB_LEAD_SECONDS)).strftime("%Y-%m-%dT%H:%M:%S+00:00")
    job = http_json(ctx.gateway(), "POST", f"/api/cron/jobs?profile={PROFILE}", {
        "name": name, "prompt": f"JOB-{number}-{ctx.run} write the report",
        "schedule": run_at, "deliver": "active"})
    ctx.state[f"job_{number}"] = {"name": name, "id": job.get("id"), "created_at": time.time()}
    print(f"created {name} id={job.get('id')} run_at={run_at}", flush=True)
    return name


def do_fire_job_1(ctx, _args):
    create_job(ctx, 1)
    return True


def do_fire_job_2(ctx, _args):
    away = command_desktop(ctx, "away", 90)
    ctx.check("offer-to-desktop", "the Desktop window moved away and reported background", bool(away and away.get("ok")), verdict=away)
    name = create_job(ctx, 2)
    verdict = command_desktop(ctx, "expect-offer", 400, title=name)
    ok = bool(verdict and verdict.get("ok"))
    ctx.check("offer-to-desktop", "the Desktop presented a proactive notification and reported shown", ok, verdict=verdict)
    ctx.state["desktop_offer_verdict"] = verdict
    return ok


def do_fire_job_3(ctx, _args):
    name = create_job(ctx, 3)
    row = wait_for(lambda: (r := ctx.offer_row(PROFILE, name)) and r["status"] != "routing" and r, 400)
    ctx.check("offer-nobody-attached", "the job was judged by the gateway", row is not None)
    return row is not None


def desktop_device_id(ctx):
    ready = json.loads((ctx.ctl / "desktop.ready").read_text()) if (ctx.ctl / "desktop.ready").exists() else {}
    return ready.get("device_id"), ready


def do_assert_row_1(ctx, _args):
    phase = "offer-to-foreground-ios"
    name = ctx.state["job_1"]["name"]
    row = wait_for(lambda: (r := ctx.offer_row(PROFILE, name)) and r["outcome"] == "acted" and r, 60)
    ctx.report["reach_offers"]["after_job_1"] = ctx.offer_rows(PROFILE)
    ctx.check(phase, "the offer row exists and was acted on", row is not None)
    if row is None:
        return False
    route = route_of(row)
    desktop_id, _ = desktop_device_id(ctx)
    ctx.check(phase, "alerted on an app device that is the iPhone and not the Desktop",
              row["status"] == "alerted" and route.get("kind") == "app" and route.get("device_id") != desktop_id
              and ("iPhone" in (route.get("label") or "") or "iOS" in (route.get("label") or "")),
              status=row["status"], route=route)
    ctx.check(phase, "the acted outcome came from the same device", row["outcome_device"] == route.get("device_id"),
              outcome_device=row["outcome_device"])
    ctx.state["ios_device_id"] = route.get("device_id")
    return all(item["ok"] for item in ctx.report["assertions"] if item["phase"] == phase)


def do_assert_row_2(ctx, _args):
    phase = "offer-to-desktop"
    name = ctx.state["job_2"]["name"]
    row = wait_for(lambda: (r := ctx.offer_row(PROFILE, name)) and r["status"] != "routing" and r, 60)
    ctx.report["reach_offers"]["after_job_2"] = ctx.offer_rows(PROFILE)
    ctx.check(phase, "the offer row settled", row is not None)
    if row is None:
        return False
    route = route_of(row)
    desktop_id, hello = desktop_device_id(ctx)
    ctx.check(phase, "alerted on the Desktop device", row["status"] == "alerted" and route.get("device_id") == desktop_id,
              status=row["status"], route=route, desktop_device_id=desktop_id)
    ctx.check(phase, "the Desktop declared itself as a desktop app", hello.get("kind") == "desktop", hello=hello)
    ctx.check(phase, "the Desktop reported shown", row["outcome"] == "shown" and row["outcome_device"] == desktop_id,
              outcome=row["outcome"], outcome_device=row["outcome_device"])
    attempts = json.loads(row["attempts_json"]) if row.get("attempts_json") else []
    ctx.report["notes"]["job_2_attempts"] = attempts
    return all(item["ok"] for item in ctx.report["assertions"] if item["phase"] == phase)


def do_quit_desktop(ctx, _args):
    verdict = command_desktop(ctx, "quit", 120)
    ok = bool(verdict and verdict.get("ok"))
    ctx.check("quit", "the Desktop quit", ok, verdict=verdict)
    return ok


def do_assert_row_3(ctx, _args):
    phase = "offer-nobody-attached"
    name = ctx.state["job_3"]["name"]
    row = ctx.offer_row(PROFILE, name)
    ctx.report["reach_offers"]["after_job_3"] = ctx.offer_rows(PROFILE)
    ctx.check(phase, "the offer row exists", row is not None)
    if row is None:
        return False
    ctx.check(phase, "landed silently with no route", row["status"] == "landed_silent" and not route_of(row),
              status=row["status"], reason=row["reason"], route=route_of(row))
    chat = bot_chat_session(ctx, PROFILE)
    lane = ctx.query(PROFILE, "SELECT content FROM messages WHERE session_id = ? AND role = 'user' AND content LIKE ?",
                     (chat["id"] if chat else "", f'%"{name}"%'))
    ctx.check(phase, "the job output landed in the Bot Chat lane", len(lane) >= 1, lane_rows=len(lane))
    return all(item["ok"] for item in ctx.report["assertions"] if item["phase"] == phase)


def do_assert_beta(ctx, _args):
    phase = "second-profile"
    marker = f"PRESENCE-BETA-{ctx.run}"
    client = TOOLS / "gateway-client" / "gateway_client.py"
    result = subprocess.run(
        [sys.executable, "-I", str(client), "submit", "--profile", OTHER_PROFILE, "--text", marker, "--hold", "60"],
        capture_output=True, text=True, timeout=120, env=os.environ, check=False)
    ctx.check(phase, "a plain client turn on the other profile completed", '"completed"' in result.stdout,
              stdout=result.stdout[-400:], stderr=result.stderr[-400:])
    beta = [r for r in ctx.stub_requests() if r.get("tools") and marker in last_user(r)]
    ctx.check(phase, "the other profile's request carries no origin note",
              len(beta) == 1 and not NOTE_RE.search(last_user(beta[0])), requests=len(beta))
    ctx.report["reach_offers"]["beta"] = ctx.offer_rows(OTHER_PROFILE)
    ctx.check(phase, "the other profile's database has no offers", ctx.offer_rows(OTHER_PROFILE) == [] and ctx.db(OTHER_PROFILE).exists())
    ctx.check(phase, "the host default profile has no offers", ctx.offer_rows(None) == [])
    ctx.check(phase, "alpha logged exactly the three jobs", len(ctx.offer_rows(PROFILE)) == 3)
    chat = bot_chat_session(ctx, PROFILE)
    if chat and ctx.state.get("system_prompt_hash") is not None:
        ctx.check(phase, "the Bot Chat system prompt is unchanged in state.db after all jobs and turns",
                  chat["system_prompt_hash"] == ctx.state["system_prompt_hash"])
    return all(item["ok"] for item in ctx.report["assertions"] if item["phase"] == phase)


def do_mint_token(ctx, _args):
    print(ctx.gateway().access_token(), flush=True)
    return True


def do_finalize(ctx, args):
    phase = "desktop-evidence"
    evidence_path = ctx.art / "desktop-evidence.json"
    evidence = json.loads(evidence_path.read_text()) if evidence_path.exists() else {}
    ctx.check(phase, "the Desktop wrote its evidence on quit", bool(evidence))
    notifications = [n for n in evidence.get("notifications", []) if n.get("kind") == "proactive"]
    ctx.check(phase, "exactly one proactive hermes:notify call was made", len(notifications) == 1, count=len(notifications))
    ctx.check(phase, "the Desktop never presented the iPhone's offer",
              len(evidence.get("offers", [])) == 1, offers=len(evidence.get("offers", [])))
    ctx.report["notes"]["desktop_evidence"] = evidence
    ctx.check("run", "the iOS UI test and the Desktop spec both finished green", args.ios_status == 0 and args.desktop_status == 0,
              ios_status=args.ios_status, desktop_status=args.desktop_status)
    return all(item["ok"] for item in ctx.report["assertions"])


COMMANDS = {
    "mint-token": do_mint_token,
    "desktop-turn-1": do_desktop_turn_1,
    "assert-notes": do_assert_notes,
    "fire-job-1": do_fire_job_1,
    "assert-row-1": do_assert_row_1,
    "fire-job-2": do_fire_job_2,
    "assert-row-2": do_assert_row_2,
    "quit-desktop": do_quit_desktop,
    "fire-job-3": do_fire_job_3,
    "assert-row-3": do_assert_row_3,
    "assert-beta": do_assert_beta,
    "finalize": do_finalize,
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=sorted(COMMANDS))
    parser.add_argument("--ios-status", type=int, default=0)
    parser.add_argument("--desktop-status", type=int, default=0)
    args = parser.parse_args()
    ctx = Context()
    try:
        ok = COMMANDS[args.command](ctx, args)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError, urllib.error.URLError) as exc:
        ctx.check(args.command, "the step ran without an error", False, error=f"{type(exc).__name__}: {exc}")
        ok = False
    finally:
        ctx.save()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

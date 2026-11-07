import asyncio
import hashlib
import importlib.util
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
import websockets

from agent.origin_note import OriginSignature, render_note
from tests.gateway.fixtures.local_recovery_probe import child_env, daemon, seed_offline_models_dev
from tests.waiting import async_wait_until, wait_until

ROOT = Path(__file__).resolve().parents[2]
IOS_TOOLS = ROOT / "apps" / "ios" / "Tools"
ARTIFACT_NAME = "reach-e2e-two-clients.json"
ARTIFACT_DIR_ENV = "HERMES_REACH_E2E_ARTIFACT_DIR"
PROFILE = "alpha"
OTHER_PROFILE = "beta"
HEARTBEAT_SECONDS = 5.0
CRON_FIRE_TIMEOUT = 240.0
IOS_SIGNATURE = OriginSignature("ios", "iPhone", False)
DESKTOP_SIGNATURE = OriginSignature("desktop", "Desktop (macOS)", False)
USERNAME = "tester"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gateway_client = load_module("reach_e2e_gateway_client", IOS_TOOLS / "gateway-client" / "gateway_client.py")


class Report:
    def __init__(self):
        self.steps: dict[str, dict] = {}
        self.requests: list[dict] = []
        self.offers: dict[str, list[dict]] = {}
        self.failures: list[str] = []

    def step(self, name: str) -> dict:
        return self.steps.setdefault(name, {"assertions": [], "data": {}})

    def check(self, step: str, name: str, condition: bool, **detail) -> bool:
        self.step(step)["assertions"].append({"name": name, "ok": bool(condition), **detail})
        if not condition:
            self.failures.append(f"{step}: {name} {detail}")
        return bool(condition)

    def data(self, step: str, **values) -> None:
        self.step(step)["data"].update(values)

    def write(self, directory: Path) -> Path:
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / ARTIFACT_NAME
        path.write_text(json.dumps({
            "ok": not self.failures, "failures": self.failures, "steps": self.steps,
            "system_prompt_sha256_per_request": self.requests, "reach_offers": self.offers,
        }, indent=2, sort_keys=True, default=str), encoding="utf-8")
        return path


class ReachStack:
    def __init__(self, base: Path):
        self.base = base
        self.home = base / "home"
        self.stub_log = base / "stub-requests.jsonl"
        self.password = uuid.uuid4().hex
        self.base_url = ""

    def db_path(self, profile: str | None) -> Path:
        return (self.home / "profiles" / profile if profile else self.home) / "state.db"

    def query(self, profile: str | None, sql: str, args=()) -> list[dict]:
        path = self.db_path(profile)
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

    def offer_rows(self, profile: str | None) -> list[dict]:
        return self.query(profile, "SELECT * FROM reach_offers ORDER BY created_at")

    def offer_row(self, profile: str | None, title: str) -> dict | None:
        rows = [row for row in self.offer_rows(profile) if row["title"] == title]
        return rows[-1] if rows else None

    def stub_requests(self) -> list[dict]:
        if not self.stub_log.exists():
            return []
        entries = [json.loads(line) for line in self.stub_log.read_text(encoding="utf-8").splitlines() if line.strip()]
        return [entry for entry in entries if entry.get("messages")]


def free_port() -> int:
    import socket
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def write_config(path: Path, stub_url: str, extra: str = "") -> None:
    path.write_text(
        f"model:\n  provider: custom\n  base_url: {stub_url}\n  api_key: stub-key\n  default: stub-model\n"
        "auxiliary:\n  title_generation:\n    enabled: false\n"
        f"proactive:\n  quiet_hours: null\n{extra}", encoding="utf-8")


def create_profile(home: Path, name: str, env: dict) -> Path:
    code = f"from hermes_cli.profiles import create_profile; print(create_profile({name!r}, no_alias=True))"
    subprocess.run([sys.executable, "-c", code], cwd=ROOT, env=env, check=True, capture_output=True, text=True, timeout=60)
    return home / "profiles" / name


@pytest.fixture
def stack(tmp_path):
    reach = ReachStack(tmp_path)
    reach.home.mkdir(mode=0o700)
    user = tmp_path / "user"
    user.mkdir()
    stub_out = tmp_path / "stub.out"
    with stub_out.open("w") as out:
        stub = subprocess.Popen(
            [sys.executable, "-I", str(IOS_TOOLS / "stub-llm" / "stub_llm.py"), "--log", str(reach.stub_log)],
            stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    try:
        listening = wait_until(lambda: next(
            (line.split()[1] for line in stub_out.read_text().splitlines() if line.startswith("listening ")), None),
            timeout=30, what="stub LLM listening")
        stub_url = f"http://127.0.0.1:{listening}/v1"
        port = free_port()
        reach.base_url = f"http://127.0.0.1:{port}"
        env = child_env()
        env.update(HOME=str(user), USERPROFILE=str(user), HERMES_HOME=str(reach.home), PYTHONPATH=str(ROOT),
                   OPENAI_API_KEY="loopback-only", OPENAI_BASE_URL=stub_url, PYTHONUNBUFFERED="1",
                   HERMES_DISABLE_LAZY_INSTALLS="1")
        for name in (PROFILE, OTHER_PROFILE):
            write_config(create_profile(reach.home, name, env) / "config.yaml", stub_url)
        write_config(reach.home / "config.yaml", stub_url, (
            f"webapp:\n  enabled: true\n  host: 127.0.0.1\n  port: {port}\n  public_url: https://reach-e2e.example.ts.net\n"
            f"dashboard:\n  basic_auth:\n    username: {USERNAME}\n    password: {reach.password}\n"
            f"    secret: {uuid.uuid4().hex * 2}\n"))
        seed_offline_models_dev(reach.home)
        with daemon(ROOT, reach.home, env, barrier=False) as (_proc, _descriptor):
            wait_until(lambda: _answers(reach.base_url + "/api/auth/providers"), timeout=120, what="webapp listener")
            yield reach
    finally:
        stub.terminate()
        stub.wait(timeout=10)


def _answers(url: str) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=3) as response:
            return response.status == 200
    except (urllib.error.URLError, OSError):
        return False


class Peer:
    def __init__(self, gateway, name: str, hello: dict | None):
        self.gateway, self.name, self.hello_params = gateway, name, hello
        self.events: list[dict] = []
        self.offers: list[dict] = []
        self.outcomes_sent: list[tuple[str, str]] = []
        self.socket = None
        self.rpc = None
        self.tasks: list[asyncio.Task] = []
        self.hello_result: dict | None = None
        self.stopping = asyncio.Event()

    async def open(self) -> "Peer":
        url, protocols = await asyncio.to_thread(self.gateway.socket_url_and_protocols)
        self.socket = await websockets.connect(url, subprotocols=protocols)
        queue: asyncio.Queue = asyncio.Queue()
        self.rpc = gateway_client.Rpc(self.socket, queue)
        self.tasks = [asyncio.create_task(self._pump()), asyncio.create_task(self._route(queue)),
                      asyncio.create_task(self._beat())]
        await async_wait_until(lambda: any(e.get("type") == "gateway.ready" for e in self.events),
                               timeout=30, what=f"{self.name} gateway.ready")
        capabilities = (await self.rpc.call("runtime.describe", {})).get("capabilities", [])
        assert "reach-v1" in capabilities, capabilities
        if self.hello_params is not None:
            await self.say_hello()
        return self

    async def say_hello(self, attention: str | None = None) -> None:
        params = dict(self.hello_params)
        if attention:
            params["attention"] = attention
        self.hello_result = await self.rpc.call("client.hello", params)

    async def _pump(self) -> None:
        try:
            await self.rpc.pump()
        except websockets.ConnectionClosed:
            pass

    async def _route(self, queue: asyncio.Queue) -> None:
        while True:
            event = await queue.get()
            self.events.append(event)
            if event.get("type") == "reach.offer":
                self.offers.append(event["payload"])

    async def _beat(self) -> None:
        while not self.stopping.is_set():
            try:
                await asyncio.wait_for(self.stopping.wait(), HEARTBEAT_SECONDS)
            except TimeoutError:
                try:
                    await self.rpc.call("gateway.ping", {})
                except (websockets.ConnectionClosed, RuntimeError, TimeoutError):
                    return

    async def attention(self, state: str) -> None:
        assert (await self.rpc.call("client.attention", {"state": state}))["recorded"] is True

    async def outcome(self, offer_id: str, outcome: str) -> dict:
        self.outcomes_sent.append((offer_id, outcome))
        return await self.rpc.call("reach.outcome", {"offer_id": offer_id, "outcome": outcome})

    async def create_session(self, profile: str, source: str, *, bot_chat: bool = False) -> str:
        params = {"profile": profile, "request_id": str(uuid.uuid4()), "source": source}
        if bot_chat:
            params.update(title=gateway_client.BOT_CHAT_TITLE, hidden=True)
        created = await self.rpc.call("session.create", params)
        return created["session_id"]

    async def resume(self, profile: str, session_id: str) -> None:
        await self.rpc.call("session.resume", {"profile": profile, "session_id": session_id})

    async def turn(self, profile: str, session_id: str, text: str) -> None:
        mark = len(self.events)
        await self.rpc.call("prompt.submit", {
            "profile": profile, "session_id": session_id, "text": text, "submission_id": str(uuid.uuid4())})
        await async_wait_until(
            lambda: any(e.get("type") == "message.complete" and e.get("session_id") == session_id
                        for e in self.events[mark:]),
            timeout=120, what=f"{self.name} turn {text}")

    async def close(self) -> None:
        self.stopping.set()
        for task in self.tasks:
            task.cancel()
        if self.socket is not None:
            await self.socket.close()
        await asyncio.gather(*self.tasks, return_exceptions=True)


def hello_for(kind: str, label: str, device_id: str, accepts_offers: bool = True) -> dict:
    return {"kind": kind, "device_id": device_id, "label": label, "app_version": "1.0",
            "accepts_offers": accepts_offers, "attention": "foreground"}


def http_json(gateway, method: str, path: str, body: dict | None = None) -> dict:
    request = urllib.request.Request(
        gateway.base_url + path, method=method, data=json.dumps(body).encode() if body is not None else None,
        headers={"authorization": "Bearer " + gateway.access_token(), "content-type": "application/json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def create_active_job(gateway, profile: str, name: str, prompt: str) -> dict:
    run_at = (datetime.now(UTC) + timedelta(seconds=2)).strftime("%Y-%m-%dT%H:%M:%S+00:00")
    return http_json(gateway, "POST", f"/api/cron/jobs?profile={profile}", {
        "name": name, "prompt": prompt, "schedule": run_at, "deliver": "active"})


def system_sha(request: dict) -> str | None:
    system = [m["content"] for m in request["messages"] if m["role"] == "system"]
    return hashlib.sha256(system[0].encode("utf-8")).hexdigest() if system else None


def last_user_content(request: dict) -> str:
    return next((m["content"] for m in reversed(request["messages"]) if m["role"] == "user"), "")


def turn_request(stack: ReachStack, marker: str) -> dict:
    found = [r for r in stack.stub_requests() if r["tools"] and marker in last_user_content(r)]
    assert len(found) == 1, (marker, len(found))
    return found[0]


async def settle_offer(report: Report, step: str, peer: Peer, title: str):
    await async_wait_until(lambda: any(o["title"] == title for o in peer.offers), timeout=CRON_FIRE_TIMEOUT,
                           what=f"{peer.name} receives the offer for {title}")
    offer = next(o for o in peer.offers if o["title"] == title)
    report.check(step, "offer frame carries notify/cron and the job title",
                 offer["kind"] == "notify" and offer["domain"] == "cron" and bool(offer["offer_id"]))
    return offer


async def await_row(stack: ReachStack, report: Report, step: str, title: str, accepts, timeout: float = 90.0) -> dict:
    try:
        return await async_wait_until(
            lambda: (row := stack.offer_row(PROFILE, title)) and accepts(row) and row, timeout=timeout,
            what=f"offer row for {title}")
    except AssertionError:
        report.data(step, rows_at_timeout=stack.offer_rows(PROFILE), default_home_rows=stack.offer_rows(None),
                    other_profile_rows=stack.offer_rows(OTHER_PROFILE))
        raise


def route_of(row: dict) -> dict:
    return json.loads(row["route_json"]) if row.get("route_json") else {}


async def scenario(stack: ReachStack, report: Report, nonce: str) -> None:
    gateway = gateway_client.Gateway(stack.base_url, USERNAME, stack.password)
    desktop_id, ios_id = "desktop-" + uuid.uuid4().hex[:12], "ios-" + uuid.uuid4().hex[:12]
    desktop = await Peer(gateway, "desktop", hello_for("desktop", "Desktop (macOS)", desktop_id)).open()
    ios = await Peer(gateway, "ios", hello_for("ios", "iPhone", ios_id, accepts_offers=False)).open()
    roster = await Peer(gateway, "ios-roster", hello_for("ios", "iPhone", ios_id)).open()
    await roster.rpc.call("session.active_list", {"profile": PROFILE})
    beta_ios = await Peer(gateway, "beta-ios", hello_for("ios", "iPhone", "beta-" + uuid.uuid4().hex[:12])).open()
    plain = await Peer(gateway, "plain", None).open()
    peers = [desktop, ios, roster, beta_ios, plain]
    marks = {n: f"REACH-T{n}-{nonce}" for n in range(1, 6)}
    try:
        report.check("hello", "both app clients are recorded",
                     desktop.hello_result["recorded"] and ios.hello_result["recorded"],
                     desktop=desktop.hello_result, ios=ios.hello_result)
        session_id = await desktop.create_session(PROFILE, "gui", bot_chat=True)
        await desktop.turn(PROFILE, session_id, marks[1])
        hash_after_first_turn = stored_prompt_hash(stack, session_id)
        await ios.resume(PROFILE, session_id)
        await ios.turn(PROFILE, session_id, marks[2])
        await ios.turn(PROFILE, session_id, marks[3])
        await desktop.turn(PROFILE, session_id, marks[4])
        await ios.turn(PROFILE, session_id, marks[5])
        check_origin_notes(stack, report, marks, session_id, hash_after_first_turn)

        job_one = f"reach-one-{nonce}"
        await ios.attention("foreground")
        await roster.attention("foreground")
        create_active_job(gateway, PROFILE, job_one, f"JOB-ONE-{nonce} write the report")
        offer = await settle_offer(report, "offer-to-foreground-ios", roster, job_one)
        await roster.outcome(offer["offer_id"], "shown")
        row = await await_row(stack, report, "offer-to-foreground-ios", job_one, lambda r: r["status"] == "alerted")
        report.check("offer-to-foreground-ios", "alerted on the iOS device",
                     route_of(row).get("device_id") == ios_id and route_of(row).get("label") == "iPhone", route=route_of(row))
        report.check("offer-to-foreground-ios", "desktop never saw it", not desktop.offers)
        await roster.outcome(offer["offer_id"], "acted")
        acted = await await_row(stack, report, "offer-to-foreground-ios", job_one, lambda r: r["outcome"] == "acted")
        report.check("offer-to-foreground-ios", "outcome acted by the iOS device", acted["outcome_device"] == ios_id,
                     outcome=acted["outcome"], outcome_device=acted["outcome_device"])
        report.offers["after_job_one"] = stack.offer_rows(PROFILE)

        await ios.attention("background")
        await roster.attention("background")
        await ios.close()
        await roster.close()
        await desktop.attention("background")
        job_two = f"reach-two-{nonce}"
        create_active_job(gateway, PROFILE, job_two, f"JOB-TWO-{nonce} write the report")
        offer_two = await settle_offer(report, "offer-to-attached-desktop", desktop, job_two)
        await desktop.outcome(offer_two["offer_id"], "shown")
        row_two = await await_row(stack, report, "offer-to-attached-desktop", job_two, lambda r: r["status"] == "alerted")
        report.check("offer-to-attached-desktop", "alerted on the desktop device",
                     route_of(row_two).get("device_id") == desktop_id, route=route_of(row_two))
        report.check("offer-to-attached-desktop", "disconnected iOS got only the first offer",
                     [o["title"] for o in roster.offers] == [job_one] and not ios.offers)
        report.offers["after_job_two"] = stack.offer_rows(PROFILE)

        await desktop.close()
        job_three = f"reach-three-{nonce}"
        create_active_job(gateway, PROFILE, job_three, f"JOB-THREE-{nonce} write the report")
        row_three = await await_row(stack, report, "offer-with-nobody-attached", job_three,
                                    lambda r: r["status"] != "routing", timeout=CRON_FIRE_TIMEOUT)
        report.check("offer-with-nobody-attached", "landed silently with no route",
                     row_three["status"] == "landed_silent" and not route_of(row_three),
                     status=row_three["status"], reason=row_three["reason"])
        lane_text = f"%{job_three}%"

        def lane_rows():
            return stack.query(PROFILE, "SELECT m.content FROM messages m JOIN sessions s ON s.id = m.session_id "
                                        "WHERE s.title = ? AND m.role = 'user' AND m.content LIKE ?",
                               (gateway_client.BOT_CHAT_TITLE, lane_text))

        try:
            lane = await async_wait_until(lane_rows, timeout=CRON_FIRE_TIMEOUT, what="job output in the lane")
        except AssertionError:
            lane = []
        report.check("offer-with-nobody-attached", "the job output landed in the durable lane", len(lane) >= 1,
                     lane_rows=len(lane))
        report.offers["after_job_three"] = stack.offer_rows(PROFILE)

        await check_second_profile(stack, report, nonce, plain, beta_ios, [desktop, ios, roster])
    finally:
        for peer in peers:
            await peer.close()


def stored_prompt_hash(stack: ReachStack, session_id: str) -> str | None:
    rows = stack.query(PROFILE, "SELECT system_prompt_hash FROM sessions WHERE id = ?", (session_id,))
    return rows[0]["system_prompt_hash"] if rows else None


def check_origin_notes(stack: ReachStack, report: Report, marks: dict, session_id: str, first_hash: str | None) -> None:
    step = "origin-notes"
    requests = {n: turn_request(stack, marker) for n, marker in marks.items()}
    shas = {n: system_sha(request) for n, request in requests.items()}
    report.requests.extend({"turn": n, "marker": marks[n], "system_sha256": sha} for n, sha in shas.items())
    report.check(step, "the system message is byte-identical on all five turns",
                 len(set(shas.values())) == 1 and None not in shas.values(), shas=shas)
    ios_note, desktop_note = render_note(IOS_SIGNATURE), render_note(DESKTOP_SIGNATURE)
    report.check(step, "the iPhone note rides turn 2 and turn 5 only",
                 [n for n, r in requests.items() if ios_note in last_user_content(r)] == [2, 5])
    report.check(step, "the desktop note rides turns 1 and 4 only (an unrelated host is never the baseline)",
                 [n for n, r in requests.items() if desktop_note in last_user_content(r)] == [1, 4])
    report.check(step, "turn 3 repeats nothing already announced",
                 "The user is now writing from" not in last_user_content(requests[3]))
    final_hash = stored_prompt_hash(stack, session_id)
    report.check(step, "state.db keeps the one frozen system prompt, and it is what the model was sent",
                 bool(first_hash) and final_hash == first_hash == next(iter(shas.values())),
                 first_hash=first_hash, final_hash=final_hash)
    persisted = stack.query(PROFILE, "SELECT content FROM messages WHERE session_id = ? AND role = 'user'", (session_id,))
    report.check(step, "persisted user rows are the typed words, never the note",
                 [row["content"] for row in persisted] == [marks[n] for n in sorted(marks)])


async def check_second_profile(stack, report, nonce, plain, beta_ios, alpha_peers) -> None:
    step = "second-profile-isolation"
    beta_session = await beta_ios.create_session(OTHER_PROFILE, "ios")
    await plain.resume(OTHER_PROFILE, beta_session)
    marker = f"REACH-BETA-{nonce}"
    await plain.turn(OTHER_PROFILE, beta_session, marker)
    request = turn_request(stack, marker)
    report.requests.append({"turn": "beta", "marker": marker, "system_sha256": system_sha(request)})
    report.check(step, "the other profile's request carries no origin note",
                 "The user is now writing from" not in last_user_content(request))
    beta_rows = stack.offer_rows(OTHER_PROFILE)
    report.offers["beta"] = beta_rows
    report.check(step, "the other profile logged no offers", beta_rows == [] and stack.db_path(OTHER_PROFILE).exists())
    report.check(step, "the host (default) profile logged no offers", stack.offer_rows(None) == [])
    report.check(step, "no socket of the other profile ever received reach.offer",
                 not beta_ios.offers and not plain.offers)
    report.check(step, "alpha jobs reached alpha's sockets only", len(stack.offer_rows(PROFILE)) == 3)


def test_two_clients_one_profile_and_a_second_profile(stack, tmp_path):
    report = Report()
    nonce = uuid.uuid4().hex[:8]
    try:
        asyncio.run(scenario(stack, report, nonce))
    finally:
        report.data("run", nonce=nonce, base_url=stack.base_url)
        directory = tmp_path / "artifacts"
        path = report.write(directory)
        for source in (stack.home / "restart.log", stack.stub_log):
            if source.exists():
                shutil.copy(source, directory / source.name)
        extra = os.environ.get(ARTIFACT_DIR_ENV)
        if extra:
            shutil.copytree(directory, extra, dirs_exist_ok=True)
        print(f"reach e2e artifact: {path}")
        if report.failures or sys.exc_info()[0] is not None:
            print(path.read_text(encoding="utf-8"))
            log = stack.home / "restart.log"
            lines = log.read_text(encoding="utf-8", errors="replace").splitlines() if log.exists() else []
            print("\n".join([line for line in lines if any(word in line for word in ("cron", "Bot Chat", "bot-chat", "reach", "Job "))][-40:]))
    assert not report.failures, report.failures

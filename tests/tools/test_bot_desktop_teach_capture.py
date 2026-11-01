"""The recorder follows the lease and the clock; with a real Chromium it records a demonstration end to end."""

from __future__ import annotations

import asyncio
import http.server
import json
import os
import shutil
import subprocess
import threading

import pytest

from hermes_constants import get_hermes_home
from tests.waiting import wait_until
from tools.bot_desktop import browser, lease, teach, teach_capture, teach_log
from tools.bot_desktop.teach_capture import TeachRecorder


@pytest.fixture(autouse=True)
def _fresh_lease():
    lease._reset_for_tests()
    yield
    lease._reset_for_tests()
    with teach_capture._registry_lock:
        teach_capture._recorders.clear()


class _Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


def _recorder(viewer="viewer-1", *, discover=lambda: None, clock=None, max_seconds=600):
    lease.acquire(viewer)
    log = teach_log.TeachLog("teach-aaaaaaaaaaaa")
    kwargs = {"clock": clock} if clock else {}
    return TeachRecorder(home=get_hermes_home(), viewer_id=viewer, log=log, discover=discover, poll_seconds=0.01,
                         max_seconds=max_seconds, **kwargs)


def test_without_a_browser_it_waits_and_stop_ends_it_cleanly():
    rec = _recorder()
    rec.start()
    wait_until(lambda: rec.snapshot()["capture"] == "waiting" and rec._stop is not None, what="recorder running")
    assert rec.snapshot()["recording"] is True
    final = rec.stop()
    assert final["recording"] is False and final["ended"] == "owner" and final["capture"] == "idle"
    assert rec.stop()["ended"] == "owner"


def test_a_stop_that_arrives_before_the_capture_loop_started_still_ends_the_recording():
    rec = _recorder()
    rec.stop()
    assert rec.snapshot()["ended"] == "owner"
    rec.start()
    wait_until(lambda: rec._finished.is_set(), what="capture thread exited")
    assert rec.snapshot()["ended"] == "owner"


def test_nothing_reaches_the_log_after_the_recording_was_stopped():
    rec = _recorder()
    rec.start()
    wait_until(lambda: rec._stop is not None, what="recorder running")
    rec.stop()
    assert not rec.log.add({"kind": "navigate", "url": "https://example.com/late"})


def test_a_recording_ends_at_the_time_limit():
    clock = _Clock()
    rec = _recorder(clock=clock, max_seconds=600)
    rec.start()
    wait_until(lambda: rec._stop is not None, what="recorder running")
    assert rec.snapshot()["recording"] is True
    clock.now += 601
    wait_until(lambda: rec.snapshot()["ended"] == "limit", what="limit reached")
    assert rec.stop()["ended"] == "limit"


def test_a_recording_ends_the_moment_control_is_handed_back():
    rec = _recorder()
    rec.start()
    wait_until(lambda: rec._stop is not None, what="recorder running")
    lease.release("viewer-1")
    wait_until(lambda: rec.snapshot()["ended"] == "control_returned", what="hand back noticed")
    assert rec.stop()["ended"] == "control_returned"


def test_a_recording_ends_when_another_viewer_takes_the_lease():
    rec = _recorder()
    rec.start()
    wait_until(lambda: rec._stop is not None, what="recorder running")
    lease.acquire("viewer-2")
    wait_until(lambda: rec.snapshot()["ended"] == "control_returned", what="eviction noticed")


def test_the_deadline_is_reported_in_the_snapshot():
    rec = _recorder(max_seconds=600)
    snap = rec.snapshot()
    assert snap["deadline_at"] - snap["started_at"] == 600


def test_one_recording_per_profile_until_it_is_taken():
    home = get_hermes_home()
    first, second = _recorder(), _recorder()
    assert teach_capture.begin(home, first) is True
    assert teach_capture.begin(home, second) is False
    assert teach_capture.active(home) is first
    assert teach_capture.take(home) is first
    assert teach_capture.take(home) is None
    assert teach_capture.active(home) is None


_PAGE = b"""<!doctype html><title>Demo</title>
<form action="/done" method="get">
<label for="email">Email address</label><input id="email" name="email" type="text">
<label for="pw">Password</label><input id="pw" name="pw" type="password">
<label for="otp">Code</label><input id="otp" name="otp" autocomplete="one-time-code">
<label for="cc">Card</label><input id="cc" name="cc" autocomplete="cc-number">
<label for="note">Note</label><input id="note" name="note">
<button type="submit" id="go">Sign in</button></form>
<a id="dl" href="/file.txt">Download report</a>
<button type="button" id="fake">Synthetic</button>
"""


class _Site(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.path.split("?")[0]
        body, headers = {"/": (_PAGE, {"Content-Type": "text/html"}),
                         "/done": (b"<h1>done</h1>", {"Content-Type": "text/html"}),
                         "/file.txt": (b"report", {"Content-Type": "text/plain",
                                                   "Content-Disposition": "attachment; filename=report.txt"})
                         }.get(path, (None, {}))
        if body is None:
            self.send_error(404)
            return
        self.send_response(200)
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)


def _chromium():
    exe = browser.executable() or next((p for p in (
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        shutil.which("google-chrome") or "", shutil.which("chromium") or "") if p and os.access(p, os.X_OK)), None)
    if exe is None:
        pytest.skip("no Chromium available for the end-to-end capture test")
    return exe


@pytest.fixture
def demo_browser(tmp_path, monkeypatch):
    exe = _chromium()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Site)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    udd = tmp_path / "chrome-profile"
    argv = [exe, "--headless=new", f"--user-data-dir={udd}", "--remote-debugging-port=0", "--no-first-run",
            "--no-default-browser-check", f"http://127.0.0.1:{server.server_address[1]}/?secret=1#frag"]
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        argv.insert(1, "--no-sandbox")
    proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    monkeypatch.setattr(browser, "profile_dir", lambda: udd)
    monkeypatch.setattr(teach, "unavailable_reason", lambda: None)
    wait_until(lambda: (udd / "DevToolsActivePort").exists(), timeout=30, what="browser DevTools endpoint")
    yield udd, f"http://127.0.0.1:{server.server_address[1]}"
    proc.terminate()
    proc.wait(10)
    server.shutdown()


async def _drive(udd, steps):
    import websockets
    port, path = (udd / "DevToolsActivePort").read_text().split("\n")[:2]
    async with websockets.connect(f"ws://127.0.0.1:{port}{path}", max_size=None) as ws:
        counter = 0

        async def call(method, params=None, sid=None):
            nonlocal counter
            counter += 1
            await ws.send(json.dumps({"id": counter, "method": method, "params": params or {},
                                      **({"sessionId": sid} if sid else {})}))
            while (msg := json.loads(await ws.recv())).get("id") != counter:
                pass
            return msg["result"]

        target = next(t for t in (await call("Target.getTargets"))["targetInfos"] if t["type"] == "page")
        sid = (await call("Target.attachToTarget", {"targetId": target["targetId"], "flatten": True}))["sessionId"]

        async def click(selector):
            point = (await call("Runtime.evaluate", {"returnByValue": True, "expression": (
                f"(() => {{ const r = document.querySelector('{selector}').getBoundingClientRect();"
                f" return [r.x + r.width / 2, r.y + r.height / 2]; }})()")}, sid))["result"]["value"]
            for kind in ("mousePressed", "mouseReleased"):
                await call("Input.dispatchMouseEvent", {"type": kind, "x": point[0], "y": point[1],
                                                        "button": "left", "clickCount": 1}, sid)

        async def type_into(selector, text):
            await click(selector)
            await call("Input.insertText", {"text": text}, sid)

        async def evaluate(expression):
            return (await call("Runtime.evaluate", {"expression": expression, "returnByValue": True}, sid))["result"]["value"]

        async def press(key, code):
            for kind in ("keyDown", "keyUp"):
                await call("Input.dispatchKeyEvent", {"type": kind, "key": key, "code": code,
                                                      "windowsVirtualKeyCode": 13,
                                                      **({"text": "\r"} if kind == "keyDown" else {})}, sid)

        await steps(click, type_into, press, evaluate)


def test_a_real_demonstration_is_recorded_without_secrets(demo_browser):
    udd, site = demo_browser
    viewer = "viewer-e2e"
    lease.acquire(viewer)
    started = teach.start(viewer)
    assert started["recording"] is True
    wait_until(lambda: teach.status()["capture"] == "attached", timeout=30, what="capture attached")

    async def steps(click, type_into, press, evaluate):
        leaked = await evaluate("Object.keys(window).filter(k => /hermesTeach/i.test(k))")
        assert leaked == [], "the page can see the recorder"
        await evaluate("(document.getElementById('fake').click(), true)")
        await type_into("#email", "ada@example.com")
        await type_into("#pw", "hunter2-SECRET")
        await type_into("#otp", "123456")
        await type_into("#cc", "4111111111111111")
        await type_into("#note", "weekly report")
        await click("#dl")
        wait_until(lambda: any(e["kind"] == "download" for e in _events()), timeout=15, what="download seen")
        await click("#note")
        await press("Enter", "Enter")
        wait_until(lambda: any(e["kind"] == "navigate" for e in _events()), timeout=15, what="submit navigation seen")

    def _events():
        return teach_log.read_events(teach_log.teach_dir(started["teach_id"]))

    asyncio.run(_drive(udd, steps))
    stopped = teach.stop()
    events = _events()
    assert stopped["empty"] is False and stopped["reason"] == "owner"
    kinds = [e["kind"] for e in events]
    assert {"type", "click", "download", "key", "navigate"} <= set(kinds)
    typed = {e["target"]["selector"]: e["value"] for e in events if e["kind"] == "type"}
    assert typed == {"#email": "ada@example.com", "#pw": "<typed secret>", "#otp": "<typed secret>",
                     "#cc": "<typed secret>", "#note": "weekly report"}
    assert any(e["kind"] == "click" and e["target"]["name"] == "Download report" for e in events)
    assert not any(e["kind"] == "click" and e["target"].get("selector") == "#fake" for e in events), "script-made clicks are not the owner's"
    raw = (teach_log.teach_dir(started["teach_id"]) / "events.jsonl").read_text(encoding="utf-8")
    for leak in ("hunter2", "123456", "4111", "secret=1", "frag"):
        assert leak not in raw
    assert all(e["url"].startswith(site) and "?" not in e["url"] for e in events if "url" in e)
    assert "hunter2" not in stopped["prompt"] and "<typed secret>" in stopped["prompt"]


def test_a_value_typed_but_never_committed_is_logged_when_the_owner_stops(demo_browser):
    udd, _site = demo_browser
    viewer = "viewer-flush"
    lease.acquire(viewer)
    started = teach.start(viewer)
    wait_until(lambda: teach.status()["capture"] == "attached", timeout=30, what="capture attached")

    async def steps(_click, type_into, _press, _evaluate):
        await type_into("#note", "still typing")

    asyncio.run(_drive(udd, steps))
    assert teach.stop()["empty"] is False
    typed = [e for e in teach_log.read_events(teach_log.teach_dir(started["teach_id"])) if e["kind"] == "type"]
    assert [e["value"] for e in typed] == ["still typing"]

"""Capture a demonstration in the bot's own browser through CDP, for ``teach_log``.

While the owner holds the Bot Desktop lease, :class:`TeachRecorder` attaches to the bot's persistent Chromium
(the same user-data-dir the dock's Browser icon and the agent use), injects ``teach_page_script`` into every
page and frame in an isolated world, and turns top-level navigations, trusted clicks, committed field values,
Enter/Escape presses and downloads into log events. It never records pixels, the clipboard or raw key streams.

A recording ends on the owner's Stop, at ``MAX_SECONDS``, or the moment the lease leaves the viewer who
started it (the person handed the screen back or lost it). It attaches whenever the browser is up and
re-attaches when it restarts, so the owner may open the browser after pressing Teach.
"""

from __future__ import annotations

import asyncio
import json
import logging
import secrets
import threading
import time
from pathlib import Path
from typing import Any, Awaitable, Callable, Optional

from agent.memory_provider import spawn_context_thread
from hermes_constants import hermes_home_key
from tools.bot_desktop import lease as _lease
from tools.bot_desktop import teach_page_script
from tools.bot_desktop.teach_log import TeachLog

logger = logging.getLogger(__name__)

MAX_SECONDS = 600
POLL_SECONDS = 1.0
CALL_TIMEOUT_SECONDS = 5.0
FLUSH_SETTLE_SECONDS = 0.4
FLUSH_TOTAL_SECONDS = 4.0
STOP_JOIN_SECONDS = 15.0
MAX_BINDING_BYTES = 16 * 1024
WORLD = "hermes-teach"
RECORDED_TARGETS = frozenset({"page", "iframe"})

ENDED_OWNER = "owner"
ENDED_LIMIT = "limit"
ENDED_CONTROL_RETURNED = "control_returned"

Discover = Callable[[], Optional[tuple[int, str]]]


class CdpError(RuntimeError):
    pass


class _Cdp:
    """Just enough CDP over one flat browser-level WebSocket: request/response by id, events to a callback."""

    def __init__(self, ws, on_event: Callable[[dict[str, Any]], None]):
        self._ws = ws
        self._on_event = on_event
        self._next = 0
        self._pending: dict[int, asyncio.Future] = {}

    async def pump(self) -> None:
        try:
            async for raw in self._ws:
                msg = json.loads(raw)
                if "id" in msg:
                    fut = self._pending.pop(msg["id"], None)
                    if fut is None or fut.done():
                        continue
                    if "error" in msg:
                        fut.set_exception(CdpError(str(msg["error"])))
                    else:
                        fut.set_result(msg.get("result") or {})
                else:
                    self._on_event(msg)
        finally:
            for fut in self._pending.values():
                if not fut.done():
                    fut.set_exception(CdpError("connection closed"))
            self._pending.clear()

    async def call(self, method: str, params: Optional[dict[str, Any]] = None, session_id: Optional[str] = None) -> dict[str, Any]:
        self._next += 1
        call_id = self._next
        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        self._pending[call_id] = fut
        await self._ws.send(json.dumps({"id": call_id, "method": method, "params": params or {},
                                        **({"sessionId": session_id} if session_id else {})}))
        try:
            return await asyncio.wait_for(fut, CALL_TIMEOUT_SECONDS)
        finally:
            self._pending.pop(call_id, None)


def default_discover(user_data_dir: str) -> Discover:
    def _discover() -> Optional[tuple[int, str]]:
        from tools.browser_launcher import running_instance
        found = running_instance(user_data_dir)
        return (found[0], found[1]) if found else None
    return _discover


class TeachRecorder:
    """One recording. ``start`` returns at once; the capture runs on its own thread and loop."""

    def __init__(self, *, home: Path, viewer_id: str, log: TeachLog, discover: Discover,
                 max_seconds: float = MAX_SECONDS, poll_seconds: float = POLL_SECONDS, clock=time.monotonic):
        self.home = home
        self.log = log
        self._viewer_id = viewer_id
        self._discover = discover
        self._max_seconds = max_seconds
        self._poll = poll_seconds
        self._clock = clock
        self._binding = "hermesTeach" + secrets.token_hex(6)
        self._source = teach_page_script.source(self._binding)
        self.started_at = time.time()
        self._deadline = clock() + max_seconds
        self._thread: Optional[threading.Thread] = None
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._stop: Optional[asyncio.Event] = None
        self._stop_requested = threading.Event()
        self._finished = threading.Event()
        self._state_lock = threading.Lock()
        self._capture = "waiting"
        self._ended: Optional[str] = None
        self._stop_reason = ENDED_OWNER
        self._sessions: dict[str, dict[str, Any]] = {}
        self._tasks: set[asyncio.Task] = set()

    @property
    def teach_id(self) -> str:
        return self.log.teach_id

    def start(self) -> None:
        self._thread = spawn_context_thread(self._thread_main, name=f"bot-teach:{self.teach_id}")
        self._thread.start()

    def snapshot(self) -> dict[str, Any]:
        with self._state_lock:
            return {"teach_id": self.teach_id, "recording": self._ended is None, "capture": self._capture,
                    "ended": self._ended, "started_at": self.started_at,
                    "deadline_at": self.started_at + self._max_seconds,
                    "event_count": self.log.count, "truncated": self.log.truncated}

    def stop(self, reason: str = ENDED_OWNER) -> dict[str, Any]:
        """End the recording and wait until the capture flushed. Idempotent: a recording that already ended
        (time limit, control returned) keeps its own reason. The log is closed afterwards even if the capture
        thread is still winding down, so nothing it reports later can reach the log."""
        self._stop_reason = reason
        self._stop_requested.set()
        loop, stop = self._loop, self._stop
        if loop is not None and stop is not None and not self._finished.is_set():
            try:
                loop.call_soon_threadsafe(stop.set)
            except RuntimeError:
                pass
        if self._thread is not None:
            self._thread.join(STOP_JOIN_SECONDS)
        self.log.close()
        if not self._finished.is_set():
            self._mark_ended(reason)
        return self.snapshot()

    def _mark_ended(self, reason: str) -> None:
        with self._state_lock:
            if self._ended is None:
                self._ended, self._capture = reason, "idle"

    def _set_capture(self, value: str) -> None:
        with self._state_lock:
            if self._ended is None:
                self._capture = value

    def _thread_main(self) -> None:
        try:
            asyncio.run(self._main())
        except Exception:  # health: allow BLE001 -- the capture thread must always mark the recording ended
            logger.exception("bot teach capture crashed")
        finally:
            self._mark_ended(self._stop_reason)
            self.log.close()
            self._finished.set()

    def _end_reason(self) -> Optional[str]:
        if self._stop_requested.is_set():
            return self._stop_reason
        if self._clock() >= self._deadline:
            return ENDED_LIMIT
        held = _lease.get(hermes_home_key(self.home))
        if held.holder != _lease.HUMAN or held.viewer_id != self._viewer_id:
            return ENDED_CONTROL_RETURNED
        return None

    async def _main(self) -> None:
        self._loop, self._stop = asyncio.get_running_loop(), asyncio.Event()
        if self._stop_requested.is_set():
            self._stop.set()
        while (reason := self._end_reason()) is None:
            found = await asyncio.to_thread(self._discover)
            if found is not None:
                await self._attached(*found)
            if self._end_reason() is None:
                await self._sleep()
        self._stop_reason = reason

    async def _sleep(self) -> None:
        try:
            await asyncio.wait_for(self._stop.wait(), self._poll)
        except TimeoutError:
            pass

    async def _attached(self, port: int, path: str) -> None:
        import websockets
        from agent.proxy_bypass import loopback_connect_kwargs
        url = f"ws://127.0.0.1:{port}{path}"
        try:
            async with websockets.connect(url, max_size=None, open_timeout=CALL_TIMEOUT_SECONDS, close_timeout=2,
                                          ping_interval=None, **loopback_connect_kwargs(url)) as ws:
                cdp = _Cdp(ws, lambda msg: self._on_event(cdp, msg))
                pump = asyncio.create_task(cdp.pump())
                try:
                    await self._browser_setup(cdp)
                    while not pump.done() and self._end_reason() is None:
                        await self._sleep()
                    if not pump.done():
                        await self._flush_bounded(cdp)
                finally:
                    self._set_capture("waiting")
                    await self._cancel_tasks()
                    self._sessions.clear()
                    pump.cancel()
        except (OSError, CdpError, TimeoutError, websockets.WebSocketException) as exc:
            logger.info("bot teach: browser connection ended: %s", exc)

    async def _browser_setup(self, cdp: _Cdp) -> None:
        await cdp.call("Browser.setDownloadBehavior", {"behavior": "default", "eventsEnabled": True})
        await cdp.call("Target.setDiscoverTargets", {"discover": True})

    def _spawn(self, coro: Awaitable[None]) -> None:
        task = asyncio.ensure_future(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _cancel_tasks(self) -> None:
        pending = [t for t in self._tasks if not t.done()]
        for task in pending:
            task.cancel()
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)

    def _on_event(self, cdp: _Cdp, msg: dict[str, Any]) -> None:
        method, params, session = msg.get("method", ""), msg.get("params") or {}, msg.get("sessionId")
        handler = self._HANDLERS.get(method)
        if handler is not None:
            handler(self, cdp, params, session)

    def _on_target_created(self, cdp: _Cdp, params: dict[str, Any], _session: Optional[str]) -> None:
        info = params.get("targetInfo") or {}
        if info.get("type") == "page" and not str(info.get("url", "")).startswith("devtools://"):
            self._spawn(self._guarded(cdp.call("Target.attachToTarget", {"targetId": info.get("targetId"), "flatten": True})))

    def _on_attached(self, cdp: _Cdp, params: dict[str, Any], _session: Optional[str]) -> None:
        session_id, info = params.get("sessionId"), params.get("targetInfo") or {}
        if session_id and info.get("type") in RECORDED_TARGETS and session_id not in self._sessions:
            self._sessions[session_id] = {"main_frame": None}
            self._spawn(self._guarded(self._setup_session(cdp, session_id)))

    def _on_detached(self, _cdp: _Cdp, params: dict[str, Any], _session: Optional[str]) -> None:
        self._sessions.pop(params.get("sessionId"), None)

    def _on_binding(self, _cdp: _Cdp, params: dict[str, Any], _session: Optional[str]) -> None:
        payload = params.get("payload")
        if params.get("name") != self._binding or not isinstance(payload, str) or len(payload) > MAX_BINDING_BYTES:
            return
        try:
            self.log.add(json.loads(payload))
        except ValueError:
            pass

    def _on_navigated(self, _cdp: _Cdp, params: dict[str, Any], session: Optional[str]) -> None:
        frame = params.get("frame") or {}
        if session in self._sessions and not frame.get("parentId"):
            self._sessions[session]["main_frame"] = frame.get("id")
            self.log.add({"kind": "navigate", "url": frame.get("url")})

    def _on_same_document(self, _cdp: _Cdp, params: dict[str, Any], session: Optional[str]) -> None:
        state = self._sessions.get(session)
        if state is not None and params.get("frameId") == state["main_frame"]:
            self.log.add({"kind": "navigate", "url": params.get("url")})

    def _on_download(self, _cdp: _Cdp, params: dict[str, Any], _session: Optional[str]) -> None:
        self.log.add({"kind": "download", "filename": params.get("suggestedFilename"), "url": params.get("url")})

    _HANDLERS = {
        "Target.targetCreated": _on_target_created, "Target.attachedToTarget": _on_attached,
        "Target.detachedFromTarget": _on_detached, "Runtime.bindingCalled": _on_binding,
        "Page.frameNavigated": _on_navigated, "Page.navigatedWithinDocument": _on_same_document,
        "Browser.downloadWillBegin": _on_download,
    }

    @staticmethod
    async def _guarded(coro: Awaitable[Any]) -> None:
        try:
            await coro
        except (CdpError, TimeoutError) as exc:
            logger.debug("bot teach: target setup skipped: %s", exc)

    async def _setup_session(self, cdp: _Cdp, session_id: str) -> None:
        async def call(method: str, params: Optional[dict[str, Any]] = None) -> dict[str, Any]:
            return await cdp.call(method, params, session_id)

        await call("Runtime.enable")
        await call("Runtime.addBinding", {"name": self._binding, "executionContextName": WORLD})
        await call("Page.enable")
        await call("Page.addScriptToEvaluateOnNewDocument", {"source": self._source, "worldName": WORLD})
        await call("Target.setAutoAttach", {"autoAttach": True, "waitForDebuggerOnStart": False, "flatten": True})
        tree = (await call("Page.getFrameTree")).get("frameTree") or {}
        if session_id in self._sessions:
            self._sessions[session_id]["main_frame"] = (tree.get("frame") or {}).get("id")
        for frame_id in _frame_ids(tree):
            world = await call("Page.createIsolatedWorld", {"frameId": frame_id, "worldName": WORLD})
            await call("Runtime.evaluate", {"expression": self._source, "contextId": world["executionContextId"]})
        self._set_capture("attached")

    async def _flush_bounded(self, cdp: _Cdp) -> None:
        try:
            await asyncio.wait_for(self._flush(cdp), FLUSH_TOTAL_SECONDS)
        except TimeoutError:
            logger.info("bot teach: flush timed out; closing the recording as is")

    async def _flush(self, cdp: _Cdp) -> None:
        """Blur the focused field in every page so a value the owner typed but never committed is logged."""
        expression = "(document.activeElement && document.activeElement.blur && document.activeElement.blur(), 0)"
        for session_id in list(self._sessions):
            await self._guarded(cdp.call("Runtime.evaluate", {"expression": expression}, session_id))
        await asyncio.sleep(FLUSH_SETTLE_SECONDS)


def _frame_ids(tree: dict[str, Any]) -> list[str]:
    ids = [tree["frame"]["id"]] if (tree.get("frame") or {}).get("id") else []
    for child in tree.get("childFrames") or []:
        ids.extend(_frame_ids(child))
    return ids


_recorders: dict[str, TeachRecorder] = {}
_registry_lock = threading.Lock()


def active(home: Path) -> Optional[TeachRecorder]:
    with _registry_lock:
        return _recorders.get(hermes_home_key(home))


def take(home: Path) -> Optional[TeachRecorder]:
    """Remove and return the profile's recorder in one step, so two concurrent Stops cannot both finish it."""
    with _registry_lock:
        return _recorders.pop(hermes_home_key(home), None)


def begin(home: Path, recorder: TeachRecorder) -> bool:
    """Register ``recorder`` as the profile's recording; False while another one has not been collected."""
    with _registry_lock:
        key = hermes_home_key(home)
        if key in _recorders:
            return False
        _recorders[key] = recorder
    return True

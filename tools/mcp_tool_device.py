from __future__ import annotations

import asyncio
import json
import logging
import re
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from tools.mcp_tool_common import _core
from tools.mcp_tool_errors import InvalidMcpUrlError

logger = logging.getLogger("tools.mcp_tool")

MAX_MESSAGE_BYTES = 4 * 1024 * 1024
INBOX_DEPTH = 256
RECENT_FAILURE_SECONDS = 60.0
CLOSE_FRAME_SECONDS = 5.0
DEVICE_TRANSPORT = "device"
DEVICE_ID = re.compile(r"^[A-Za-z0-9-]{8,64}$")


class DeviceRelayError(ConnectionError):
    pass


class DeviceUnreachableError(DeviceRelayError):
    pass


class DeviceDisconnectedError(DeviceRelayError):
    pass


class DeviceRelayClosedError(DeviceRelayError):
    pass


class DeviceMessageTooLargeError(DeviceRelayError):
    pass


class DeviceAuthRequiredError(DeviceRelayError):
    pass


class InvalidDeviceServerError(InvalidMcpUrlError):
    pass


def is_device_config(config: object) -> bool:
    return isinstance(config, dict) and config.get("transport") == DEVICE_TRANSPORT and "url" not in config


def validated_device_config(name: str, config: dict) -> tuple[str, str]:
    from tui_gateway.contracts.canonical_device import DeviceMcpServer
    if not is_device_config(config):
        raise InvalidDeviceServerError(f"MCP server '{name}' is no longer a device server")
    device_id, server = config.get("device_id"), config.get("server")
    if not isinstance(device_id, str) or not DEVICE_ID.fullmatch(device_id):
        raise InvalidDeviceServerError(f"MCP server '{name}' has no valid device_id")
    if server not in {member.value for member in DeviceMcpServer}:
        raise InvalidDeviceServerError(f"MCP server '{name}' names a device server that does not exist")
    return device_id, server


def encoded_size(message: Any) -> int:
    return len(json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


_auth_lock = threading.Lock()
_auth: dict[tuple[str, str], list] = {}


def _auth_key(home: Path | str, name: str) -> tuple[str, str]:
    return str(Path(home).resolve()), name


class DeviceAuth:
    def __init__(self, home: Path | str, name: str) -> None:
        self._key = _auth_key(home, name)

    def reauth_required(self) -> bool:
        with _auth_lock:
            return bool(_auth.get(self._key, [None])[0])

    def credential_stamp(self) -> tuple:
        with _auth_lock:
            return (_auth.get(self._key, [None, 0])[1],)


def mark_auth_required(home: Path | str, name: str, reason: str) -> None:
    with _auth_lock:
        entry = _auth.setdefault(_auth_key(home, name), [None, 0])
        entry[0], entry[1] = reason, entry[1] + 1


def clear_auth_required(home: Path | str, name: str) -> bool:
    with _auth_lock:
        entry = _auth.get(_auth_key(home, name))
        if entry is None or entry[0] is None:
            return False
        entry[0], entry[1] = None, entry[1] + 1
        return True


def forget_auth(home: Path | str, name: str) -> None:
    with _auth_lock:
        _auth.pop(_auth_key(home, name), None)


def pending_auth_reason(home: Path | str, name: str) -> str | None:
    with _auth_lock:
        return _auth.get(_auth_key(home, name), [None])[0]


def auth_required_error(server_name: str) -> str | None:
    from hermes_constants import get_hermes_home
    from tools.auth_required import auth_required_result
    reason = pending_auth_reason(get_hermes_home(), server_name)
    if reason is None:
        return None
    return auth_required_result(f"mcp:{server_name}", reason, flow="oauth")


_failure_lock = threading.Lock()
_failures: dict[tuple[str, str], tuple[str, float]] = {}


def note_failure(home: Path | str, name: str, error: BaseException | str) -> None:
    with _failure_lock:
        _failures[_auth_key(home, name)] = (str(error), time.monotonic())


def clear_failure(home: Path | str, name: str) -> None:
    with _failure_lock:
        _failures.pop(_auth_key(home, name), None)


def recent_failure_note(server_name: str) -> str:
    from hermes_constants import get_hermes_home
    with _failure_lock:
        entry = _failures.get(_auth_key(get_hermes_home(), server_name))
    if entry is None or time.monotonic() - entry[1] > RECENT_FAILURE_SECONDS:
        return ""
    return f" ({entry[0]})"


class DeviceChannel:
    def __init__(self, loop: asyncio.AbstractEventLoop, inbox) -> None:
        self._loop = loop
        self._inbox = inbox
        self._failed = asyncio.Event()
        self._failure: BaseException | None = None

    def post_message(self, message: dict) -> bool:
        return self._post(self._receive, message)

    def post_failure(self, error: BaseException) -> bool:
        return self._post(self.fail, error)

    def _post(self, callback, value) -> bool:
        try:
            self._loop.call_soon_threadsafe(callback, value)
        except RuntimeError:
            return False
        return True

    def fail(self, error: BaseException) -> None:
        if self._failure is None:
            self._failure = error
            self._failed.set()

    async def watch(self) -> None:
        await self._failed.wait()
        raise self._failure

    def _receive(self, message: dict) -> None:
        import anyio
        from mcp import types
        from mcp.shared.message import SessionMessage
        try:
            item: Any = SessionMessage(types.jsonrpc_message_adapter.validate_python(message, by_name=False))
        except ValueError as exc:
            item = exc
        try:
            self._inbox.send_nowait(item)
        except anyio.WouldBlock:
            self.fail(DeviceRelayError("The Mac sent messages faster than the bot could read them."))
        except (anyio.ClosedResourceError, anyio.BrokenResourceError):
            pass


async def _pump_out(relay, write_stream_reader, inbox) -> None:
    from gateway import device_mcp_relay
    async for session_message in write_stream_reader:
        message = session_message.message.model_dump(by_alias=True, mode="json", exclude_unset=True)
        size = await asyncio.to_thread(encoded_size, message)
        if size <= MAX_MESSAGE_BYTES:
            await device_mcp_relay.send(relay, message)
        elif not _refuse_oversized_request(session_message, inbox):
            raise DeviceMessageTooLargeError(
                f"An MCP message of {size} bytes is over the {MAX_MESSAGE_BYTES} byte limit and was not sent.")


def _refuse_oversized_request(session_message, inbox) -> bool:
    import anyio
    from mcp import types
    from mcp.shared.message import SessionMessage
    request = session_message.message
    if not isinstance(request, types.JSONRPCRequest):
        return False
    error = types.ErrorData(code=types.INVALID_REQUEST,
                            message=f"The request is too large to send to the Mac (over {MAX_MESSAGE_BYTES} bytes).")
    try:
        inbox.send_nowait(SessionMessage(types.JSONRPCError(jsonrpc="2.0", id=request.id, error=error)))
    except anyio.WouldBlock:
        return False
    except (anyio.ClosedResourceError, anyio.BrokenResourceError):
        pass
    return True


def _close_reason(error: BaseException | None):
    from tui_gateway.contracts.canonical_device import DeviceMcpCloseReason
    timed_out = error is not None and (
        isinstance(error, TimeoutError)
        or isinstance(error, BaseExceptionGroup) and error.split(TimeoutError)[0] is not None)
    return DeviceMcpCloseReason.TIMEOUT if timed_out else DeviceMcpCloseReason.CLIENT_CLOSED


@asynccontextmanager
async def device_transport(home: Path, name: str, device_id: str, server: str):
    import anyio
    from gateway import device_mcp_relay
    from mcp.shared.message import SessionMessage
    reason = pending_auth_reason(home, name)
    if reason is not None:
        raise DeviceAuthRequiredError(f"MCP server '{name}' needs the owner to sign in again on the Mac.")
    inbox_send, inbox = anyio.create_memory_object_stream[SessionMessage | Exception](INBOX_DEPTH)
    outbox, outbox_reader = anyio.create_memory_object_stream[SessionMessage](0)
    channel = DeviceChannel(asyncio.get_running_loop(), inbox_send)
    relay = await device_mcp_relay.open_relay(home, name, device_id, server, channel)
    error: BaseException | None = None
    try:
        async with inbox_send, inbox, outbox, outbox_reader, anyio.create_task_group() as group:
            group.start_soon(_pump_out, relay, outbox_reader, inbox_send)
            group.start_soon(channel.watch)
            try:
                yield inbox, outbox
            finally:
                group.cancel_scope.cancel()
    except BaseException as exc:
        error = exc
        raise
    finally:
        with anyio.CancelScope(shield=True), anyio.move_on_after(CLOSE_FRAME_SECONDS):
            await device_mcp_relay.close_relay(relay, _close_reason(error))


class MCPServerDeviceMixin:
    __slots__ = ()

    def _is_device(self) -> bool:
        return is_device_config(self._config)

    def _transport_kind(self) -> str:
        return "http" if self._is_http() else DEVICE_TRANSPORT if self._is_device() else "stdio"

    def _transport_runner(self):
        return {"http": self._run_http, DEVICE_TRANSPORT: self._run_device, "stdio": self._run_stdio}[
            self._transport_kind()]

    def _current_device_definition(self) -> dict:
        from tools import mcp_tool_config
        current = mcp_tool_config._load_mcp_config(interpolate=False).get(self.name)
        if current is None:
            raise DeviceRelayClosedError(f"MCP server '{self.name}' is no longer offered by a Mac.")
        return current

    async def _run_device(self, config: dict) -> str:
        from hermes_constants import get_hermes_home
        definition = await asyncio.to_thread(self._current_device_definition)
        device_id, server = validated_device_config(self.name, definition)
        connect_timeout = float(config.get("connect_timeout", _core._DEFAULT_CONNECT_TIMEOUT))
        transport = device_transport(get_hermes_home(), self.name, device_id, server)
        return await self._serve_transport(transport, "device", connect_timeout)


def _server_named(name: str):
    from tools.mcp_tool_scope import _resolve_server_key
    with _core._lock:
        return _core._servers.get(_resolve_server_key(name))


def revive_server(name: str) -> bool:
    from tools import mcp_tool_loop as loop
    server = _server_named(name)
    return server is not None and server.session is None and loop._signal_reconnect(server)

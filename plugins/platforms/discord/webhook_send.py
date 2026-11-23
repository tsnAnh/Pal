from __future__ import annotations

import asyncio
import json
import logging
import re
from collections.abc import Awaitable, Callable
from typing import Any, Protocol

import httpx

logger = logging.getLogger(__name__)

DISCORD_API = "https://discord.com/api/v10"
WEBHOOK_URL = re.compile(r"https://(?:discord|discordapp)\.com/api(?:/v\d+)?/webhooks/(\d{1,20})/([A-Za-z0-9_\-]{1,100})")
WEBHOOK_PATH = re.compile(r"(/webhooks/\d{1,20}/)[A-Za-z0-9_\-]{8,}")
ALLOWED_MENTIONS = {"parse": ["users"]}
MAX_RATE_LIMIT_RETRIES = 1
MAX_RETRY_AFTER_S = 5.0
UNKNOWN_MESSAGE = 10008
UNKNOWN_WEBHOOK = 10015
INVALID_WEBHOOK_TOKEN = 50027
FORWARDED_SEND_KWARGS = frozenset({"file", "files", "reference", "allowed_mentions", "mention_author"})


class Persona(Protocol):
    bot: str
    channel_id: str
    webhook_id: str
    url: str
    username: str | None
    avatar_url: str | None


class WebhookError(Exception):
    def __init__(self, reason: str, *, status: int | None = None, code: int | None = None):
        super().__init__(f"discord webhook failed: {reason}" + (f" (http {status})" if status else ""))
        self.reason, self.status, self.code = reason, status, code


class WebhookGone(WebhookError):
    pass


class WebhookRateLimited(WebhookError):
    pass


class WebhookMessageMissing(WebhookError):
    pass


class _RedactWebhookToken(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        try:
            text = record.getMessage()
        except Exception:  # health: allow BLE001 -- a record that cannot format is left for logging to report
            return True
        redacted = WEBHOOK_PATH.sub(r"\1<redacted>", text)
        if redacted != text:
            record.msg, record.args = redacted, ()
        return True


_HTTPX_FILTER = _RedactWebhookToken()


def _guard_http_logs() -> None:
    http_logger = logging.getLogger("httpx")
    if _HTTPX_FILTER not in http_logger.filters:
        http_logger.addFilter(_HTTPX_FILTER)


def _retry_after(response: httpx.Response, body: Any) -> float:
    raw = body.get("retry_after") if isinstance(body, dict) else None
    if raw is None:
        raw = response.headers.get("Retry-After", "1")
    try:
        return min(max(float(raw), 0.0), MAX_RETRY_AFTER_S)
    except (TypeError, ValueError):
        return 1.0


def _body(response: httpx.Response) -> Any:
    try:
        return response.json()
    except ValueError:
        return None


def _classify(response: httpx.Response, body: Any) -> WebhookError:
    code = body.get("code") if isinstance(body, dict) and isinstance(body.get("code"), int) else None
    status = response.status_code
    if code == UNKNOWN_MESSAGE:
        return WebhookMessageMissing("message_missing", status=status, code=code)
    if code in (UNKNOWN_WEBHOOK, INVALID_WEBHOOK_TOKEN) or status == 404 or (status == 401 and code is None):
        return WebhookGone("webhook_gone", status=status, code=code)
    return WebhookError("rejected", status=status, code=code)


class WebhookClient:
    def __init__(self, transport: httpx.AsyncBaseTransport | None = None, *,
                 sleep: Callable[[float], Awaitable[None]] = asyncio.sleep, timeout: float = 15.0):
        _guard_http_logs()
        self._transport, self._sleep, self._timeout = transport, sleep, timeout
        self._http: httpx.AsyncClient | None = None

    def _client(self) -> httpx.AsyncClient:
        if self._http is None:
            self._http = httpx.AsyncClient(transport=self._transport, follow_redirects=False,
                                           timeout=httpx.Timeout(self._timeout, connect=5.0))
        return self._http

    async def aclose(self) -> None:
        http, self._http = self._http, None
        if http is not None:
            await http.aclose()

    @staticmethod
    def _base(persona: Persona) -> str:
        match = WEBHOOK_URL.fullmatch(persona.url)
        if match is None:
            raise WebhookGone("webhook_url_invalid")
        return f"{DISCORD_API}/webhooks/{match.group(1)}/{match.group(2)}"

    async def execute(self, persona: Persona, *, content: str | None, thread_id: str | None = None,
                      files: list[tuple[str, bytes]] | None = None) -> dict[str, Any]:
        payload: dict[str, Any] = {"allowed_mentions": ALLOWED_MENTIONS}
        if content:
            payload["content"] = content
        if persona.username:
            payload["username"] = persona.username
        if persona.avatar_url:
            payload["avatar_url"] = persona.avatar_url
        params = {"wait": "true", **({"thread_id": thread_id} if thread_id else {})}
        if files:
            payload["attachments"] = [{"id": index, "filename": name} for index, (name, _) in enumerate(files)]
            request = {"data": {"payload_json": json.dumps(payload)},
                       "files": {f"files[{index}]": (name, data) for index, (name, data) in enumerate(files)}}
        else:
            request = {"json": payload}
        body = await self._call("POST", self._base(persona), params, **request)
        return body if isinstance(body, dict) else {}

    async def edit(self, persona: Persona, message_id: str, *, content: str, thread_id: str | None = None) -> dict[str, Any]:
        body = await self._call("PATCH", f"{self._base(persona)}/messages/{message_id}",
                                {"thread_id": thread_id} if thread_id else {},
                                json={"content": content, "allowed_mentions": ALLOWED_MENTIONS})
        return body if isinstance(body, dict) else {}

    async def delete(self, persona: Persona, message_id: str, *, thread_id: str | None = None) -> None:
        await self._call("DELETE", f"{self._base(persona)}/messages/{message_id}",
                         {"thread_id": thread_id} if thread_id else {})

    async def _call(self, method: str, url: str, params: dict[str, str], **request: Any) -> Any:
        for attempt in range(MAX_RATE_LIMIT_RETRIES + 1):
            try:
                response = await self._client().request(method, url, params=params, **request)
            except httpx.HTTPError:
                raise WebhookError("unreachable") from None
            body = _body(response)
            if response.status_code != 429:
                if response.is_success:
                    return body
                raise _classify(response, body)
            if attempt == MAX_RATE_LIMIT_RETRIES:
                raise WebhookRateLimited("rate_limited", status=429)
            await self._sleep(_retry_after(response, body))
        raise AssertionError("unreachable")


class PersonaMessage:
    def __init__(self, data: dict[str, Any]):
        self.id = int(data["id"])
        self.content = data.get("content") or ""
        self.attachments = list(data.get("attachments") or [])


class PersonaPartial:
    def __init__(self, channel: PersonaChannel, message_id: int):
        self._channel, self.id = channel, message_id

    async def edit(self, *, content: str | None = None, **unsupported: Any) -> Any:
        channel = self._channel
        if not unsupported:
            try:
                data = await channel.client.edit(channel.persona, str(self.id), content=content or "",
                                                 thread_id=channel.thread_id)
                return PersonaMessage({"id": self.id, **data})
            except WebhookError as exc:
                channel.degrade(exc)
        return await channel.real.get_partial_message(self.id).edit(content=content, **unsupported)

    async def delete(self) -> None:
        channel = self._channel
        try:
            await channel.client.delete(channel.persona, str(self.id), thread_id=channel.thread_id)
            return
        except WebhookError as exc:
            channel.degrade(exc)
        await channel.real.get_partial_message(self.id).delete()


def _read_file(file: Any) -> tuple[str, bytes]:
    file.fp.seek(0)
    return str(file.filename), file.fp.read()


def _rewind(files: list[Any]) -> None:
    for file in files:
        reset = getattr(file, "reset", None)
        if callable(reset):
            reset()


class PersonaChannel:
    def __init__(self, channel: Any, persona: Persona, client: WebhookClient, thread_id: str | None,
                 on_gone: Callable[[Persona], None]):
        self.real, self.persona, self.client, self.thread_id, self._on_gone = channel, persona, client, thread_id, on_gone

    def __getattr__(self, name: str) -> Any:
        return getattr(self.real, name)

    def degrade(self, exc: WebhookError) -> None:
        logger.warning("discord webhook for bot %s not used (%s); using the Pal app", self.persona.bot, exc.reason)
        if isinstance(exc, WebhookGone):
            self._on_gone(self.persona)

    def get_partial_message(self, message_id: int) -> PersonaPartial:
        return PersonaPartial(self, int(message_id))

    async def send(self, content: str | None = None, **kwargs: Any) -> Any:
        if set(kwargs) - FORWARDED_SEND_KWARGS:
            return await self.real.send(content, **kwargs)
        files = list(kwargs.get("files") or ([kwargs["file"]] if kwargs.get("file") is not None else []))
        try:
            payload_files = [_read_file(file) for file in files]
        except (AttributeError, OSError, ValueError):
            return await self.real.send(content, **kwargs)
        try:
            return PersonaMessage(await self.client.execute(self.persona, content=content, thread_id=self.thread_id,
                                                            files=payload_files))
        except WebhookError as exc:
            self.degrade(exc)
        _rewind(files)
        return await self.real.send(content, **kwargs)

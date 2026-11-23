from __future__ import annotations

import io
import logging

import httpx
import pytest

from tests.gateway.chat_discord.fake_webhook import (
    CHANNEL_ID, THREAD_ID, TOKEN, WEBHOOK_ID, Endpoint, FakeWebhookApi, error,
)
from plugins.platforms.discord.webhook_send import (
    ALLOWED_MENTIONS, PersonaChannel, WebhookClient, WebhookError, WebhookGone, WebhookRateLimited,
)


@pytest.fixture
def api():
    return FakeWebhookApi()


@pytest.fixture
def sleeps():
    return []


@pytest.fixture
def client(api, sleeps):
    async def sleep(seconds: float) -> None:
        sleeps.append(seconds)
    return WebhookClient(api.transport, sleep=sleep)


@pytest.mark.asyncio
async def test_post_carries_the_bot_name_avatar_and_safe_mentions(client, api):
    message = await client.execute(Endpoint(), content="hello <@123> @everyone")

    request = api.requests[0]
    assert request.method == "POST"
    assert request.url.path == f"/api/v10/webhooks/{WEBHOOK_ID}/{TOKEN}"
    assert dict(request.url.params) == {"wait": "true"}
    sent = api.json_body()
    assert sent["content"] == "hello <@123> @everyone"
    assert sent["username"] == "Pal Helper"
    assert sent["avatar_url"].endswith("/a1b2c3.png")
    assert sent["allowed_mentions"] == ALLOWED_MENTIONS == {"parse": ["users"]}
    assert "everyone" not in sent["allowed_mentions"]["parse"] and "roles" not in sent["allowed_mentions"]["parse"]
    assert message["id"]


@pytest.mark.asyncio
async def test_a_thread_post_names_the_thread(client, api):
    await client.execute(Endpoint(), content="in a thread", thread_id=THREAD_ID)

    assert dict(api.requests[0].url.params) == {"wait": "true", "thread_id": THREAD_ID}


@pytest.mark.asyncio
async def test_an_attachment_goes_up_as_multipart(client, api):
    await client.execute(Endpoint(), content="here", files=[("report.txt", b"file-bytes")])

    request = api.requests[0]
    assert request.headers["content-type"].startswith("multipart/form-data")
    body = request.content
    assert b"file-bytes" in body and b'filename="report.txt"' in body and b"payload_json" in body
    assert b"Pal Helper" in body


@pytest.mark.asyncio
async def test_an_edit_patches_the_webhook_message(client, api):
    await client.edit(Endpoint(), "600000000000000007", content="edited", thread_id=THREAD_ID)

    request = api.requests[0]
    assert request.method == "PATCH"
    assert request.url.path == f"/api/v10/webhooks/{WEBHOOK_ID}/{TOKEN}/messages/600000000000000007"
    assert dict(request.url.params) == {"thread_id": THREAD_ID}
    assert api.json_body() == {"content": "edited", "allowed_mentions": ALLOWED_MENTIONS}


@pytest.mark.asyncio
async def test_a_delete_removes_the_webhook_message(client, api):
    await client.delete(Endpoint(), "600000000000000007")

    assert api.requests[0].method == "DELETE"
    assert api.requests[0].url.path.endswith("/messages/600000000000000007")


@pytest.mark.asyncio
async def test_one_rate_limit_waits_once_then_succeeds(client, api, sleeps):
    api.script = [error(429, None, retry_after=0.25, **{"global": False})]

    message = await client.execute(Endpoint(), content="hi")

    assert message["id"]
    assert sleeps == [0.25]
    assert len(api.requests) == 2


@pytest.mark.asyncio
async def test_an_exhausted_rate_limit_fails_clearly_without_looping(client, api, sleeps):
    api.script = [error(429, None, retry_after=0.25), error(429, None, retry_after=0.25), error(429, None, retry_after=0.25)]

    with pytest.raises(WebhookRateLimited):
        await client.execute(Endpoint(), content="hi")

    assert len(api.requests) == 2
    assert sleeps == [0.25]


@pytest.mark.asyncio
async def test_the_retry_wait_is_capped(client, api, sleeps):
    api.script = [error(429, None, retry_after=9999)]

    await client.execute(Endpoint(), content="hi")

    assert sleeps and sleeps[0] <= 5.0


@pytest.mark.parametrize("status,code", [(404, 10015), (401, 50027), (404, None)])
@pytest.mark.asyncio
async def test_a_missing_webhook_is_reported_as_gone(client, api, status, code):
    api.script = [error(status, code)]

    with pytest.raises(WebhookGone):
        await client.execute(Endpoint(), content="hi")


@pytest.mark.asyncio
async def test_a_url_that_is_not_a_discord_webhook_is_never_called(client, api):
    with pytest.raises(WebhookGone):
        await client.execute(Endpoint(url="https://evil.example/api/webhooks/1/abc"), content="hi")

    assert api.requests == []


@pytest.mark.asyncio
async def test_the_webhook_url_is_in_no_log_record_or_exception(client, api, caplog):
    caplog.set_level(logging.DEBUG)
    api.script = [error(404, 10015)]
    with pytest.raises(WebhookGone) as gone:
        await client.execute(Endpoint(), content="hi")

    def unreachable(request):
        raise httpx.ConnectError(f"cannot reach {request.url}", request=request)

    down = WebhookClient(httpx.MockTransport(unreachable))
    with pytest.raises(WebhookError) as network:
        await down.execute(Endpoint(), content="hi")
    await client.execute(Endpoint(), content="ok")

    everything = caplog.text + str(gone.value) + repr(gone.value) + str(network.value) + repr(network.value)
    assert TOKEN not in everything
    assert network.value.__cause__ is None and network.value.__suppress_context__
    assert repr(Endpoint()).count(TOKEN) == 0


class RecordingChannel:
    id = int(CHANNEL_ID)

    def __init__(self):
        self.sent: list[tuple] = []
        self.edited: list[tuple] = []
        self.guild = object()

    async def send(self, content=None, **kwargs):
        self.sent.append((content, kwargs))
        return type("Msg", (), {"id": 777, "attachments": []})()

    def get_partial_message(self, message_id):
        channel = self

        class Partial:
            id = message_id

            async def edit(self, **kwargs):
                channel.edited.append((message_id, kwargs))

            async def delete(self):
                channel.edited.append((message_id, "deleted"))
        return Partial()


@pytest.fixture
def gone_calls():
    return []


@pytest.fixture
def wrapped(client, gone_calls):
    real = RecordingChannel()
    return real, PersonaChannel(real, Endpoint(), client, None, lambda persona: gone_calls.append(persona.bot))


@pytest.mark.asyncio
async def test_the_wrapper_posts_through_the_webhook_and_not_the_pal_app(wrapped, api):
    real, channel = wrapped

    message = await channel.send(content="hi", reference=object())

    assert real.sent == []
    assert message.id and api.json_body()["username"] == "Pal Helper"
    assert channel.id == RecordingChannel.id
    assert channel.guild is real.guild


@pytest.mark.asyncio
async def test_a_file_upload_reads_the_discord_file_and_returns_its_attachments(wrapped, api):
    _, channel = wrapped
    discord_file = type("File", (), {"fp": io.BytesIO(b"abc"), "filename": "report.txt", "reset": lambda self, seek=True: None})()

    message = await channel.send(content=None, files=[discord_file])

    assert b"abc" in api.requests[0].content
    assert message.attachments


@pytest.mark.asyncio
async def test_a_gone_webhook_falls_back_to_the_pal_app_and_flags_repair(wrapped, api, gone_calls):
    real, channel = wrapped
    api.script = [error(404, 10015)]

    message = await channel.send(content="still delivered")

    assert real.sent == [("still delivered", {})]
    assert message.id == 777
    assert gone_calls == ["pal"]


@pytest.mark.asyncio
async def test_a_rate_limited_webhook_still_delivers_through_the_pal_app_without_flagging_repair(wrapped, api, gone_calls):
    real, channel = wrapped
    api.script = [error(429, None, retry_after=0.1), error(429, None, retry_after=0.1)]

    await channel.send(content="still delivered")

    assert real.sent == [("still delivered", {})]
    assert gone_calls == []


@pytest.mark.asyncio
async def test_a_send_with_a_view_stays_on_the_pal_app(wrapped, api):
    real, channel = wrapped
    view = object()

    await channel.send(content="approve?", view=view)

    assert api.requests == []
    assert real.sent == [("approve?", {"view": view})]


@pytest.mark.asyncio
async def test_an_edit_goes_through_the_webhook(wrapped, api):
    real, channel = wrapped

    await channel.get_partial_message(55).edit(content="streamed")

    assert api.requests[0].method == "PATCH" and real.edited == []


@pytest.mark.asyncio
async def test_an_edit_of_a_pal_app_message_falls_back_to_the_pal_app(wrapped, api):
    real, channel = wrapped
    api.script = [error(403, 50005)]

    await channel.get_partial_message(55).edit(content="streamed")

    assert real.edited == [(55, {"content": "streamed"})]


@pytest.mark.asyncio
async def test_a_delete_goes_through_the_webhook_then_the_pal_app(wrapped, api):
    real, channel = wrapped

    await channel.get_partial_message(55).delete()
    api.script = [error(404, 10008)]
    await channel.get_partial_message(56).delete()

    assert [r.method for r in api.requests] == ["DELETE", "DELETE"]
    assert real.edited == [(56, "deleted")]

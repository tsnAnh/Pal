"""Socket Mode lifecycle pieces of ``SlackAdapter``: watchdog cancel, the drain-time inbound stop and the connect hint."""

import asyncio
import logging

logger = logging.getLogger("plugins.platforms.slack.adapter")


class SlackSocketLifecycleMixin:
    async def _cancel_socket_watchdog(self, failure_msg: str) -> None:
        """Cancel and await the watchdog task (if any); exceptions are debug-logged."""
        watchdog_task = self._socket_watchdog_task
        self._socket_watchdog_task = None
        if watchdog_task is None or watchdog_task.done():
            return
        watchdog_task.cancel()
        try:
            await watchdog_task
        except asyncio.CancelledError:
            pass
        except Exception:  # pragma: no cover - defensive logging
            logger.debug(failure_msg, exc_info=True)

    async def stop_inbound(self) -> None:
        """Gateway drain: close Socket Mode while the message handler is still installed (#143122).

        Bolt acks an envelope before the listener runs, so one received after the handler
        withdrawal is dropped and never redelivered. ``_running=False`` first keeps the watchdog and
        the task-done callback from reconnecting; the reconnect lock waits out a restart already past
        its ``_running`` check, so its replacement socket is the one closed here. Web API clients
        (egress) stay open.
        """
        self._running = False
        await self._cancel_socket_watchdog("[Slack] Watchdog task raised during stop_inbound")
        async with self._socket_reconnect_lock:
            await self._stop_socket_mode_handler()

    def _hint_allow_bots(self) -> None:
        """INFO hint: bot events can be swallowed upstream of allow_bots (manifest, allowlist)."""
        # Bot-event interop diagnostic. When the user has opted into bot messages via ``slack.allow_bots`` /
        # ``SLACK_ALLOW_BOTS``, surface the additional plumbing they almost certainly also need so
        # bot-to-bot interop doesn't silently fail. See #30091: a user reported that with ``allow_bots:
        # all`` configured, bot messages in shared threads were still dropped. Two things upstream of this
        # code can swallow them: 1. The Slack app's event subscriptions in the manifest — Socket Mode does
        # not deliver events the app hasn't subscribed to (``message.channels`` for public channels,
        # ``message.groups`` for private channels, ``message.im`` for DMs). 2. The SLACK_ALLOWED_USERS /
        # GATEWAY_ALLOWED_USERS per-user allowlists — the other bot's user id must be present (or
        # GATEWAY_ALLOW_ALL_USERS=true). Logging once at INFO keeps the startup line discoverable without
        # requiring DEBUG to enable.
        _allow_bots_cfg = self._slack_allow_bots()
        if _allow_bots_cfg != "none":
            logger.info(
                "[Slack] allow_bots=%s — for bot-to-bot interop also ensure: (a) the Slack "
                "app manifest subscribes to message.channels / message.groups / message.im as "
                "appropriate (run 'hermes slack manifest' if unsure), and (b) the other bot's "
                "Slack user id is in SLACK_ALLOWED_USERS or GATEWAY_ALLOW_ALL_USERS=true. "
                "Without these, bot events are silently dropped upstream of the allow_bots "
                "gate.", _allow_bots_cfg)

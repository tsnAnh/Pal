from __future__ import annotations

import asyncio
import logging
from typing import Any, Optional

logger = logging.getLogger(__name__)


class DeskSendError(RuntimeError):
    """The platform answered that a desk send was not delivered. Anything else raised means unknown."""


class OwnerDeskMixin:
    """The platform seams the owner desk drives. The defaults report "unsupported"; a platform plugin
    that can show the owner a card and post on the owner's behalf overrides them."""

    _desk_tasks: set

    async def send_owner_card(self, contact: Any, card: Any) -> Optional[dict]:
        return None

    async def close_owner_card(self, ref: dict, text: str) -> None:
        return None

    async def desk_send(self, to: Any, text: str) -> dict:
        raise DeskSendError("this platform cannot send on the owner's behalf")

    async def desk_missed_reply(self, item: Any) -> Optional[dict]:
        return None

    async def desk_acknowledge_reply(self, event: Any) -> None:
        return None

    async def desk_say(self, event: Any, text: str) -> None:
        return None

    async def desk_owner_name(self, contact: Any) -> str:
        return ""

    async def desk_owner_channel(self, contact: Any) -> Optional[str]:
        return None

    async def decide_owner_card(self, item_id: str, actor_id: str, choice: str) -> Any:
        from gateway.desk.runtime import decide_from_card
        return await decide_from_card(self.gateway_runner, self, item_id, actor_id, choice)  # type: ignore[attr-defined]

    def schedule_desk_recovery(self) -> None:
        if getattr(self, "gateway_runner", None) is None:
            return
        tasks = self.__dict__.setdefault("_desk_tasks", set())
        task = asyncio.ensure_future(self._recover_desk_replies())
        tasks.add(task)
        task.add_done_callback(tasks.discard)

    async def _recover_desk_replies(self) -> None:
        from gateway.desk.runtime import recover_missed_replies
        try:
            await recover_missed_replies(self.gateway_runner, self, self.platform.value)  # type: ignore[attr-defined]
        except Exception:
            logger.warning("Recovering replies missed while the gateway was down failed", exc_info=True)

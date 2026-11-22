from __future__ import annotations

import logging
from typing import Any, Callable, Optional

from gateway.audience.model import Admission, AdmissionKind, SenderFacts

logger = logging.getLogger(__name__)

AuthorizationCheck = Callable[..., bool]
AdmissionCheck = Callable[..., Admission]


class SenderAdmissionMixin:
    _authorization_check: Optional[AuthorizationCheck] = None
    _admission_check: Optional[AdmissionCheck] = None

    def set_authorization_check(
        self, callback: Optional[Callable[[str, Optional[str], Optional[str]], bool]]) -> None:
        """Register ``(user_id, chat_type, chat_id) -> bool``; adapters pulling external context
        (Slack thread replies) use it to flag non-allowlisted senders as unverified background."""
        self._authorization_check = callback

    def set_admission_check(self, callback: Optional[AdmissionCheck]) -> None:
        self._admission_check = callback

    def _is_sender_authorized(self, user_id: Optional[str], chat_type: Optional[str] = None,
                              chat_id: Optional[str] = None, *, is_bot: bool = False,
                              thread_id: Optional[str] = None) -> Optional[bool]:
        """True/False from the registered check, or None when no check exists ("trust unknown",
        legacy). ``is_bot``/``thread_id`` are forwarded as keywords only when set so legacy
        three-positional callbacks keep working. Only literal booleans propagate: a truthy
        non-boolean is "unknown", never an authorization that gates a credentialed side effect."""
        if not user_id or self._authorization_check is None:
            return None
        extra: dict[str, Any] = {}
        if is_bot:
            extra["is_bot"] = True
        if thread_id is not None:
            extra["thread_id"] = thread_id
        try:
            result = self._authorization_check(user_id, chat_type, chat_id, **extra)
        except Exception:
            logger.warning("[%s] Authorization check raised for user %s; treating as unknown",
                           self.name, user_id, exc_info=True)
            return None
        if result is True or result is False:
            return result
        logger.warning("[%s] Authorization check returned %s for user %s; treating as unknown",
                       self.name, type(result).__name__, user_id)
        return None

    def _sender_admission(self, user_id: Optional[str], chat_type: Optional[str] = None,
                          chat_id: Optional[str] = None, *, is_bot: bool = False,
                          thread_id: Optional[str] = None, facts: Optional[SenderFacts] = None) -> Admission:
        if user_id and self._admission_check is not None:
            try:
                verdict = self._admission_check(
                    user_id, chat_type, chat_id, is_bot=is_bot, thread_id=thread_id, facts=facts)
            except Exception:
                logger.warning("[%s] Admission check raised for user %s; falling back to the owner check",
                               self.name, user_id, exc_info=True)
            else:
                if isinstance(verdict, Admission):
                    return verdict
                logger.warning("[%s] Admission check returned %s for user %s; falling back to the owner check",
                               self.name, type(verdict).__name__, user_id)
        owner = self._is_sender_authorized(user_id, chat_type, chat_id, is_bot=is_bot, thread_id=thread_id)
        return Admission(AdmissionKind.REFUSED if owner is False else AdmissionKind.OWNER)

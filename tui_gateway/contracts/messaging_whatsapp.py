from __future__ import annotations

from .base import Params, Result, WireEnum
from .common import OkResult, ProfileParams
from .registry import method


class WhatsAppPairingStatus(WireEnum):
    starting = "starting"
    waiting = "waiting"
    connected = "connected"
    error = "error"
    expired = "expired"
    cancelled = "cancelled"


class MessagingWhatsAppStatus(Result):
    """One bot's WhatsApp link. ``paired`` means a linked phone identity is on the gateway host. ``mode`` is
    ``bot`` (a separate number) or ``self-chat`` (the owner's own number); ``allowed_users`` is the comma
    separated phone-number allowlist (not a secret). ``state``/``error_*`` are the gateway's verdict for the adapter."""

    profile: str
    enabled: bool
    paired: bool
    mode: str
    allowed_users: str
    account_name: str | None = None
    account_phone: str | None = None
    gateway_running: bool
    state: str | None = None
    error_code: str | None = None
    error_message: str | None = None


method("messaging.whatsapp.status", params=ProfileParams, result=MessagingWhatsAppStatus,
       doc="WhatsApp link state of one bot (never carries a QR payload or credentials).")


class MessagingWhatsAppPairStartParams(ProfileParams):
    """``reset_session`` backs up the existing link first. ``allowed_users`` blank keeps the stored list."""

    mode: str | None = None
    allowed_users: str | None = None
    reset_session: bool | None = None


class MessagingWhatsAppPairing(Result):
    """One pairing attempt. ``qr_payload`` is the short-lived string the phone scans (render it as a QR code); it
    is present only while ``status`` is ``waiting`` and must never be stored, logged or kept after a terminal status."""

    pairing_id: str
    status: WhatsAppPairingStatus
    qr_payload: str | None = None
    expires_at: str
    mode: str
    allowed_users: str
    account_name: str | None = None
    account_phone: str | None = None
    error: str | None = None


method("messaging.whatsapp.pair.start", params=MessagingWhatsAppPairStartParams, result=MessagingWhatsAppPairing,
       doc="Start the WhatsApp bridge pairing for one bot; poll messaging.whatsapp.pair.status for the QR payload.")


class MessagingWhatsAppPairingParams(ProfileParams):
    pairing_id: str


method("messaging.whatsapp.pair.status", params=MessagingWhatsAppPairingParams, result=MessagingWhatsAppPairing,
       doc="Current state of a pairing attempt owned by the same bot; another bot's pairing id is not found.")
method("messaging.whatsapp.pair.cancel", params=MessagingWhatsAppPairingParams, result=OkResult,
       doc="Stop a pairing attempt owned by the same bot.")


class MessagingWhatsAppReload(Result):
    """What became of the gateway after a write: a restart (``restart_started``; refused while a chat is live:
    ``restart_busy``) or a hot reload by a running multiplexer (``hot_served``)."""

    hot_served: bool | None = None
    restart_started: bool
    restart_busy: bool | None = None
    restart_error: str | None = None


class MessagingWhatsAppPairApplyParams(MessagingWhatsAppPairingParams):
    mode: str | None = None
    allowed_users: str | None = None


class MessagingWhatsAppPairApplyResult(MessagingWhatsAppReload):
    ok: bool


method("messaging.whatsapp.pair.apply", params=MessagingWhatsAppPairApplyParams, result=MessagingWhatsAppPairApplyResult,
       doc="Save mode and allowlist, enable WhatsApp and reload the gateway once a pairing is connected.")


class MessagingWhatsAppConfigureParams(ProfileParams):
    """A blank ``allowed_users`` keeps the stored list."""

    mode: str
    allowed_users: str | None = None


class MessagingWhatsAppChange(MessagingWhatsAppStatus, MessagingWhatsAppReload):
    pass


method("messaging.whatsapp.configure", params=MessagingWhatsAppConfigureParams, result=MessagingWhatsAppChange,
       doc="Change a paired bot's WhatsApp mode and allowlist and reload the gateway.")
method("messaging.whatsapp.unpair", params=ProfileParams, result=MessagingWhatsAppChange,
       doc="Disable WhatsApp for a bot and move its linked session aside (never deleted); pair again afterwards.")


class MessagingWhatsAppCloudConnectParams(ProfileParams):
    """Meta Cloud API credentials, written to the bot's own .env only. ``access_token`` and ``app_secret`` are secrets."""

    phone_number_id: str
    access_token: str
    app_secret: str | None = None
    allowed_users: str | None = None


class MessagingWhatsAppCloudStatus(MessagingWhatsAppReload):
    profile: str
    enabled: bool
    configured: bool
    phone_number_id_set: bool
    access_token_set: bool
    app_secret_set: bool
    allowed_users_set: bool


method("messaging.whatsapp_cloud.connect", params=MessagingWhatsAppCloudConnectParams,
       result=MessagingWhatsAppCloudStatus,
       doc="Validate and save a bot's WhatsApp Cloud API credentials, enable the adapter and reload it (credentials are never echoed).")

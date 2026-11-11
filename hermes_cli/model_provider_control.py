from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any, Optional
from urllib.parse import urlparse

logger = logging.getLogger(__name__)

ACCOUNT_WIDE = frozenset({"nous", "xai-oauth"})
DEVICE_CODE_BUILTIN = frozenset({"nous", "openai-codex", "minimax-oauth", "xai-oauth"})
UNSUPPORTED_REASONS = {
    "aws_sdk": "Uses the AWS credentials of the computer running Hermes. Set them up there.",
    "vertex": "Uses the Google Cloud credentials of the computer running Hermes. Set them up there.",
    "external_process": "Needs a command-line tool installed on the computer running Hermes.",
    "oauth_external": "Sign in with that provider's own command-line tool on the computer running Hermes.",
}
DEFAULT_UNSUPPORTED_REASON = "This provider needs setup on the computer running Hermes."
MAX_BASE_URL_CHARS = 2048


@dataclass(frozen=True, slots=True)
class ProviderRow:
    id: str
    name: str
    kind: str
    state: str
    scope: str
    base_url_editable: bool
    base_url: Optional[str]
    default_base_url: Optional[str]
    reason: Optional[str]
    can_remove: bool

    def wire(self) -> dict[str, Any]:
        return {f: getattr(self, f) for f in self.__slots__}


def _catalog() -> dict:
    from hermes_cli.provider_catalog import provider_catalog_by_slug
    return {slug: d for slug, d in provider_catalog_by_slug().items() if d.auth_type != "virtual"}


def lookup(provider_id: str):
    return _catalog().get(provider_id)


def _default_base_url(slug: str) -> Optional[str]:
    from hermes_cli.auth import PROVIDER_REGISTRY
    registered = PROVIDER_REGISTRY.get(slug)
    return (registered.inference_base_url or None) if registered else None


def has_device_profile(provider_id: str) -> bool:
    from hermes_cli.web_routers.oauth import _device_login_profile
    return _device_login_profile(provider_id) is not None


def kind_of(pconfig) -> tuple[str, Optional[str]]:
    if pconfig.slug in DEVICE_CODE_BUILTIN or has_device_profile(pconfig.slug):
        return "device_code", None
    if pconfig.auth_type == "api_key" and pconfig.api_key_env_vars:
        return "api_key", None
    if pconfig.slug == "custom":
        return "unsupported", "Custom endpoints are added in the bot's model settings."
    return "unsupported", UNSUPPORTED_REASONS.get(pconfig.auth_type, DEFAULT_UNSUPPORTED_REASON)


def _state_of(pconfig, kind: str) -> str:
    if kind == "unsupported":
        return "unsupported"
    from hermes_cli.auth import get_auth_status, get_provider_auth_state
    try:
        raw = get_auth_status(pconfig.slug)
        if raw.get("logged_in") or raw.get("configured"):
            return "set"
        if kind == "device_code" and (raw.get("relogin_required") or raw.get("expired")
                                      or get_provider_auth_state(pconfig.slug)):
            return "expired"
    except Exception:
        logger.warning("model provider status for %s could not be read", pconfig.slug, exc_info=True)
    return "not_set"


def _base_url_override(pconfig) -> Optional[str]:
    if not pconfig.base_url_env_var:
        return None
    from hermes_cli.config import get_env_value
    return (get_env_value(pconfig.base_url_env_var) or "").strip() or None


def row_for(pconfig) -> ProviderRow:
    kind, reason = kind_of(pconfig)
    state = _state_of(pconfig, kind)
    return ProviderRow(
        id=pconfig.slug, name=pconfig.label, kind=kind, state=state,
        scope="account" if pconfig.slug in ACCOUNT_WIDE else "profile",
        base_url_editable=kind == "api_key" and bool(pconfig.base_url_env_var),
        base_url=_base_url_override(pconfig) if kind == "api_key" else None,
        default_base_url=_default_base_url(pconfig.slug) if kind == "api_key" else None,
        reason=reason, can_remove=state in ("set", "expired"))


def list_rows() -> list[ProviderRow]:
    return [row_for(p) for p in _catalog().values()]


def primary_env_var(pconfig) -> str:
    return pconfig.api_key_env_vars[0]


def store_api_key(provider_id: str, text: str) -> None:
    from hermes_cli.config import save_env_value_secure
    pconfig = lookup(provider_id)
    if pconfig is None or kind_of(pconfig)[0] != "api_key":
        raise ValueError("not an API-key provider")
    save_env_value_secure(primary_env_var(pconfig), text)


def _exclusive_env_vars(pconfig) -> list[str]:
    shared = {var for other in _catalog().values() if other.slug != pconfig.slug for var in other.api_key_env_vars}
    return [var for var in pconfig.api_key_env_vars if var not in shared]


def remove_credential(provider_id: str) -> None:
    from hermes_cli.auth import clear_provider_auth
    pconfig = lookup(provider_id)
    if pconfig is None:
        raise ValueError("unknown provider")
    kind, _ = kind_of(pconfig)
    if kind == "api_key":
        from hermes_cli.credential_lifecycle import remove_provider_env_credential
        for var in _exclusive_env_vars(pconfig):
            remove_provider_env_credential(var)
        clear_provider_auth(provider_id)
    elif kind == "device_code":
        _logout(provider_id, clear_provider_auth)
    else:
        raise ValueError("not removable here")


def _logout(provider_id: str, clear) -> None:
    from hermes_cli.auth import _reset_config_provider, _should_reset_config_provider_on_logout
    reset = _should_reset_config_provider_on_logout(provider_id)
    clear(provider_id)
    if provider_id == "nous":
        from hermes_cli.auth_nous import _clear_shared_nous_state
        _clear_shared_nous_state("logout")
    if reset:
        _reset_config_provider()


def valid_base_url(value: str) -> Optional[str]:
    text = value.strip()
    if not text or len(text) > MAX_BASE_URL_CHARS or not text.isascii() or not text.isprintable():
        return None
    parsed = urlparse(text)
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password:
        return None
    return text.rstrip("/")


def set_base_url(provider_id: str, value: Optional[str]) -> None:
    from hermes_cli.config import remove_env_value, save_env_value
    pconfig = lookup(provider_id)
    if pconfig is None or not row_for(pconfig).base_url_editable:
        raise ValueError("this provider has no editable address")
    if value is None:
        remove_env_value(pconfig.base_url_env_var)
        return
    url = valid_base_url(value)
    if url is None:
        raise ValueError("invalid address")
    save_env_value(pconfig.base_url_env_var, url)

from __future__ import annotations

import logging

from gateway import connector_setup_checks as checks
from gateway import oauth_client_setup as setup_mod
from hermes_cli.pal_connectors import ConnectionMethod, PalConnector, SetupStep
from tui_gateway.contracts.connectors import (
    ConnectorErrorReason,
    ConnectorSetupCheckResult,
    SetupCopyRow,
    SetupFieldRow,
    SetupGuide,
    SetupLinkRow,
    SetupProgress,
    SetupStepRow,
)

logger = logging.getLogger(__name__)


class SetupCheckRpcError(Exception):
    def __init__(self, code: int, reason: ConnectorErrorReason, message: str):
        super().__init__(reason.value)
        self.code, self.reason, self.message = code, reason, message


def _home():
    from hermes_constants import get_hermes_home
    return get_hermes_home()


def _public_url() -> str | None:
    from gateway.chat_install_runtime import public_url_for
    return public_url_for(_home())


def _templates(entry: PalConnector) -> dict[str, str | None]:
    if entry.method is ConnectionMethod.OAUTH_CLIENT and entry.id == setup_mod.GOOGLE_PROVIDER:
        return {"redirect_url": setup_mod.google_redirect_url(_public_url())}
    if entry.method is ConnectionMethod.OAUTH_CLIENT and entry.mcp_url:
        return {"redirect_url": setup_mod.MCP_REDIRECT_URL}
    return {}


def _resolve(value: str, templates: dict[str, str | None]) -> str | None:
    for name, resolved in templates.items():
        token = "{" + name + "}"
        if token in value:
            if resolved is None:
                return None
            value = value.replace(token, resolved)
    return value


def _step_row(step: SetupStep, templates: dict[str, str | None]) -> SetupStepRow:
    copies = [(c.label, _resolve(c.value, templates)) for c in step.copies]
    return SetupStepRow(
        id=step.id, kind=step.kind, title=step.title, body=step.body,
        links=[SetupLinkRow(label=l.label, url=l.url) for l in step.links],
        copies=[SetupCopyRow(label=label, value=value) for label, value in copies if value is not None],
        fields=[SetupFieldRow(id=f.id, label=f.label, secret=f.secret, prefixes=list(f.prefixes), suffix=f.suffix)
                for f in step.fields],
        check=step.check)


def build_guide(entry: PalConnector) -> SetupGuide | None:
    if entry.setup is None:
        return None
    templates = _templates(entry)
    return SetupGuide(steps=[_step_row(step, templates) for step in entry.setup.steps])


def _credentials_saved(entry: PalConnector) -> bool:
    if entry.method is ConnectionMethod.OAUTH_CLIENT:
        return setup_mod.build_store().client(entry.id) is not None
    from hermes_cli import mcp_catalog
    return mcp_catalog.is_enabled(entry.id)


def derive_progress(entry: PalConnector) -> SetupProgress | None:
    if entry.setup is None:
        return None
    steps = entry.setup.steps
    credentials = _credentials_saved(entry)
    address_set = setup_mod.google_redirect_url(_public_url()) is not None
    saved = [f.id for step in steps if step.kind == "paste" and credentials for f in step.fields]
    if not address_set and any(s.kind == "public_url" for s in steps):
        resume = next(s.id for s in steps if s.kind == "public_url")
    elif credentials:
        resume = next(s.id for s in reversed(steps) if s.kind == "paste")
    else:
        resume = next(s.id for s in steps if s.kind != "public_url")
    return SetupProgress(step_id=resume, saved=saved)


def _paste_step(entry: PalConnector):
    guide = entry.setup
    return next((s for s in guide.steps if s.kind == "paste" and s.check), None) if guide else None


def _secret(vault, item_id: str) -> str:
    from agent.vault_store import VaultError
    try:
        value = str(vault.resolve_secret(item_id).get("api_key") or "").strip()
    except VaultError:
        value = ""
    if not value:
        raise SetupCheckRpcError(4000, ConnectorErrorReason.client_unreadable,
                                 "Couldn't read what you pasted. Paste it again.")
    return value


def run_setup_check(request) -> ConnectorSetupCheckResult:
    from hermes_cli.pal_connectors import load_pal_connectors
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    entry = next((e for e in load_pal_connectors() if e.id == request.slug), None)
    step = _paste_step(entry) if entry else None
    if step is None:
        raise SetupCheckRpcError(4041, ConnectorErrorReason.connector_not_found, "Connector not found.")
    if connection_profile_home() is not None:
        raise SetupCheckRpcError(4030, ConnectorErrorReason.not_owner, "Only the owner can set up this app.")
    expected = checks.FIELDS[step.check]
    if set(request.values) != set(expected):
        raise SetupCheckRpcError(4000, ConnectorErrorReason.invalid_params, "Some pasted values are missing.")
    vault = setup_mod.vault_for(_home())
    values = {name: _secret(vault, request.values[name]) for name in expected}
    redirect = _templates(entry).get("redirect_url")
    outcome = checks.run_check(step.check, values, redirect_url=redirect)
    return ConnectorSetupCheckResult(
        slug=entry.id, ok=outcome.ok, reason=ConnectorErrorReason[outcome.reason] if outcome.reason else None,
        message=outcome.message, account=outcome.account)


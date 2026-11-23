"""Subscription providers that run through a command-line tool on the Hermes host (``cli_plan`` rows).

The provider only enters the provider registry once its plugin is installed, so the app lists it from
this table first, checks the host's CLI and sign-in, and installs the plugin through the catalog path."""

from __future__ import annotations

import logging
import threading
from dataclasses import dataclass
from typing import Any, Optional

logger = logging.getLogger(__name__)

NO_CLI_HINT = "Install Claude Code on the computer running Hermes, then sign in by running claude there."
NO_PLUGIN_HINT = "Install the Claude Direct SDK plugin."
SIGNED_OUT_HINT = "Sign in to Claude Code on the computer running Hermes."
NO_HOST_CHECK_HINT = "This provider has no host check."
MANAGED_HOST_REASON = "This installation is managed, so plugins cannot be installed from here."
INSTALL_FAILED_REASON = "Could not install the Claude Direct SDK plugin. Try again in a moment."
DISCLOSURE_MARKER = "Disclosure — "


@dataclass(frozen=True, slots=True)
class CliPlanProvider:
    id: str
    name: str
    catalog_plugin: str
    command: str


CLI_PLAN_PROVIDERS: dict[str, CliPlanProvider] = {
    "claude-subscription-directsdk-experimental": CliPlanProvider(
        id="claude-subscription-directsdk-experimental", name="Claude Direct SDK",
        catalog_plugin="claude-subscription-directsdk", command="claude"),
}

_install_lock = threading.Lock()


@dataclass(frozen=True, slots=True)
class HostCheck:
    cli_found: bool
    signed_in: bool
    plugin_installed: bool
    cli_version: Optional[str] = None
    plan: Optional[str] = None
    plugin_version: Optional[str] = None
    install_hint: Optional[str] = None
    disclosure: Optional[str] = None

    @property
    def ready(self) -> bool:
        return self.cli_found and self.plugin_installed and self.signed_in

    def wire(self) -> dict[str, Any]:
        required = {"cli_found": self.cli_found, "signed_in": self.signed_in, "plugin_installed": self.plugin_installed}
        optional = {name: getattr(self, name) for name in
                    ("cli_version", "plan", "plugin_version", "install_hint", "disclosure")}
        return {**required, **{name: value for name, value in optional.items() if value is not None}}


NO_HOST_CHECK = HostCheck(cli_found=False, signed_in=False, plugin_installed=False, install_hint=NO_HOST_CHECK_HINT)


def _hint(cli_found: bool, plugin_installed: bool, signed_in: bool) -> Optional[str]:
    if not cli_found:
        return NO_CLI_HINT
    if not plugin_installed:
        return NO_PLUGIN_HINT
    return None if signed_in else SIGNED_OUT_HINT


def _signed_in(provider_id: str) -> bool:
    from hermes_cli.auth import get_external_process_provider_status
    try:
        return bool(get_external_process_provider_status(provider_id).get("auth_verified"))
    except Exception as exc:  # health: allow BLE001 -- plugin-owned evidence reader; unreadable means not verifiable
        logger.warning("sign-in evidence for %s could not be read (%s)", provider_id, type(exc).__name__)
        return False


def _pinned_version(plugin_dir, entry) -> Optional[str]:
    from hermes_cli import plugins_cmd_catalog
    sidecar = plugins_cmd_catalog.read_catalog_sidecar(plugin_dir)
    if sidecar and plugins_cmd_catalog.at_catalog_pin(sidecar, entry.sha):
        return entry.version or None
    return None


def _disclosure(entry) -> Optional[str]:
    return " ".join(entry.description.split()).partition(DISCLOSURE_MARKER)[2] or None


def host_check(provider: CliPlanProvider, *, detail: bool = True) -> HostCheck:
    """What this host has for ``provider``. ``detail`` also reads the catalog entry (disclosure, plugin
    version), which a provider list does not need."""
    from hermes_cli import plugins_cmd
    from hermes_cli.auth_external_process import external_process_command, resolve_external_process_command
    from providers import get_provider_profile

    profile = get_provider_profile(provider.id)
    cli_found = resolve_external_process_command(external_process_command(profile) or provider.command) is not None
    plugin_dir = plugins_cmd._catalog_installed_dir(provider.catalog_plugin)
    plugin_installed = plugin_dir is not None or profile is not None
    signed_in = profile is not None and _signed_in(provider.id)
    fields: dict[str, Any] = {"install_hint": _hint(cli_found, plugin_installed, signed_in)}
    if detail:
        from hermes_cli.plugin_catalog import get_catalog_entry
        entry = get_catalog_entry(provider.catalog_plugin)
        if entry is not None:
            fields["disclosure"] = _disclosure(entry)
            if plugin_dir is not None:
                fields["plugin_version"] = _pinned_version(plugin_dir, entry)
    return HostCheck(cli_found=cli_found, signed_in=signed_in, plugin_installed=plugin_installed, **fields)


def install_plugin(provider: CliPlanProvider) -> tuple[str, Optional[str]]:
    """``(outcome, reason)`` of installing the provider's catalog plugin through the installer the plugins
    screen uses. Serialized so two taps cannot race the same install."""
    from hermes_cli import config, plugins_cmd
    if config.is_managed():
        return "refused", MANAGED_HOST_REASON
    with _install_lock:
        check = host_check(provider, detail=False)
        if check.plugin_installed:
            return "already_installed", None
        if not check.cli_found:
            return "refused", NO_CLI_HINT
        try:
            result = plugins_cmd.dashboard_install_plugin(
                "", force=False, enable=True, catalog_name=provider.catalog_plugin)
        except Exception as exc:
            logger.warning("plugin install for %s raised %s", provider.id, type(exc).__name__, exc_info=True)
            return "failed", INSTALL_FAILED_REASON
        if not result.get("ok"):
            logger.warning("plugin install for %s was refused: %s", provider.id, result.get("error"))
            return "failed", INSTALL_FAILED_REASON
        import providers
        providers.refresh_bound_home()
        return "installed", None

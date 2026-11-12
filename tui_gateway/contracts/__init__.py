"""Wire contracts (see ``base.py``). Importing this package fills the registry tables; every topic
module is listed here so the generator and the runtime see the same catalog."""

from . import (
    billing_delegation_pets,
    bot_settings,
    bot_teach,
    capabilities,
    common,
    config_free_tier_control,
    connectors,
    connectors_operation,
    display,
    events,
    gateway_service,
    github_token,
    webhook_routes,
    groups_bot_relay,
    i18n,
    liveness,
    library,
    machine,
    model_providers,
    permissions,
    profile_templates,
    profiles_vault_complete_foreign_subagents,
    projects_pets,
    prompt_voice,
    server_requests,
    sessions,
    speech_memory,
    tools_commands,
    tools_mcp_plugins,
    account,
)
from . import canonical, canonical_bot_threads, canonical_bridge, canonical_auth, canonical_device, canonical_devices, canonical_mcp_actions, canonical_reach, canonical_search
from .base import JsonValue, Params, Payload, Result, WireEnum
from .registry import CANONICAL_METHODS, CANONICAL_NAMESPACES, EVENTS, METHODS, SERVER_REQUESTS

__all__ = ["CANONICAL_METHODS", "CANONICAL_NAMESPACES", "EVENTS", "METHODS", "SERVER_REQUESTS", "JsonValue", "Params", "Payload", "Result", "WireEnum"]

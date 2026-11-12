from __future__ import annotations

from dataclasses import dataclass

from tui_gateway.contracts.bot_keys import BotKeyGroup, BotKeyRow


@dataclass(frozen=True)
class _Group:
    id: str
    label: str
    keys: tuple[tuple[str, str], ...]


GROUPS = (
    _Group("tools", "Tools", (
        ("PARALLEL_API_KEY", "Parallel search"),
        ("KEENABLE_API_KEY", "Keenable search"),
        ("FAL_KEY", "Image generation (fal)"),
        ("KREA_API_KEY", "Image generation (Krea)"),
        ("PORCUPINE_ACCESS_KEY", "Voice wake word"),
    )),
    _Group("memory", "Memory", (
        ("HONCHO_API_KEY", "Honcho"),
        ("HINDSIGHT_API_KEY", "Hindsight"),
        ("SUPERMEMORY_API_KEY", "Supermemory"),
        ("MEM0_API_KEY", "Mem0"),
        ("OPENVIKING_API_KEY", "OpenViking"),
    )),
    _Group("apps", "Apps", (
        ("NOTION_API_KEY", "Notion"),
        ("LINEAR_API_KEY", "Linear"),
        ("TENOR_API_KEY", "Tenor GIFs"),
    )),
    _Group("messaging", "Other messaging apps", (
        ("DISCORD_BOT_TOKEN", "Discord bot token"),
        ("MATTERMOST_TOKEN", "Mattermost token"),
        ("MATRIX_ACCESS_TOKEN", "Matrix access token"),
        ("MATRIX_RECOVERY_KEY", "Matrix recovery key"),
        ("BLUEBUBBLES_PASSWORD", "BlueBubbles password"),
        ("QQ_CLIENT_SECRET", "QQ client secret"),
        ("IRC_SERVER_PASSWORD", "IRC server password"),
        ("IRC_NICKSERV_PASSWORD", "IRC NickServ password"),
    )),
)

SETTABLE_KEYS = frozenset(name for group in GROUPS for name, _label in group.keys)


def _is_set(name: str) -> bool:
    from hermes_cli.config import get_env_value
    return bool((get_env_value(name) or "").strip())


def key_groups() -> list[BotKeyGroup]:
    return [BotKeyGroup(id=g.id, label=g.label,
                        keys=[BotKeyRow(name=name, label=label, is_set=_is_set(name)) for name, label in g.keys])
            for g in GROUPS]

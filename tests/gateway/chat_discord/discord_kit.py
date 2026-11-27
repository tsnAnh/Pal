from __future__ import annotations

import contextlib
import functools
import json
from datetime import UTC, datetime
from pathlib import Path

import hermes_yaml as yaml
from PIL import Image

from agent.vault_store import VaultStore
from gateway.chat_install_service import ChatInstallService
from gateway.chat_install_store import ChatInstallStore
from gateway.chat_discord.api import DiscordApi
from gateway.chat_discord.default_profile import OwnerAllowlist, ProfileRoutes
from gateway.chat_discord.provider import DiscordProvider, profile_has_home_channel
from gateway.chat_discord.records import DiscordRecords
from gateway.chat_discord.shared_adapter import Reading, SharedAdapter
from tests.gateway.chat_install_harness import RecordingControl
from tests.gateway.chat_discord.fake_discord import GUILD_ID, OWNER_ID, TOKEN, FakeDiscord
from tui_gateway import chat_install as ci
from tui_gateway.contracts import chat_provider as wire

BOT = "pal"
DISPLAY_NAME = "Pal Helper"


def route_for(bot: str, channel_id: str) -> dict[str, str]:
    return {"name": f"pal-discord-{bot}-{channel_id}", "platform": "discord", "chat_id": channel_id, "profile": bot}


class SeedingControl(RecordingControl):
    def __init__(self) -> None:
        super().__init__()
        self.seeded: list[tuple[str, dict]] = []

    def seed_config(self, profile, defaults) -> None:
        from gateway.chat_audience import seed_missing
        self.seeded.append((profile, defaults))
        seed_missing(defaults)


class FakeGatewayRuntime:
    def __init__(self) -> None:
        self.answers = True
        self.after_reload: tuple[str, str | None] = ("connected", None)
        self.reading = Reading("not_configured", False, None, None)
        self.stamp: str | None = None
        self.reloads = 0
        self.seconds = 0.0

    def read(self) -> Reading:
        return self.reading

    def reload(self) -> bool:
        self.reloads += 1
        if not self.answers:
            return False
        state, code = self.after_reload
        written = self.stamp or datetime.now(UTC).isoformat()
        self.reading = Reading(state, True, code, written)
        return True

    def clock(self) -> float:
        return self.seconds

    def pause(self, seconds: float) -> None:
        self.seconds += seconds


class Kit:
    def __init__(self, tmp_path: Path, monkeypatch, *, with_avatar: bool = False):
        self.home = tmp_path / ".hermes"
        self.home.mkdir()
        monkeypatch.setenv("HERMES_HOME", str(self.home))
        monkeypatch.setenv("DISCORD_ALLOWED_USERS", "")
        monkeypatch.delenv("DISCORD_ALLOWED_USERS")
        self.fake = FakeDiscord()
        self.sleeps: list[float] = []
        self.token: str | None = TOKEN
        self.names: dict[str, str] = {}
        self.avatar = self._make_avatar(tmp_path) if with_avatar else None
        self.vault = VaultStore(tmp_path / "vault")
        self.records_path = tmp_path / "records.json"
        self.route_reloads: list[Path] = []
        self.runtime = FakeGatewayRuntime()
        adapter = SharedAdapter(scope=contextlib.nullcontext, read=self.runtime.read, reload=self.runtime.reload,
                                clock=self.runtime.clock, pause=self.runtime.pause)
        self.provider = DiscordProvider(
            adapter=adapter, vault=self.vault, api=DiscordApi(self.fake.transport, sleep=self.sleeps.append),
            records=DiscordRecords(self.records_path), routes=ProfileRoutes(scope=contextlib.nullcontext),
            allowlist=OwnerAllowlist(scope=contextlib.nullcontext), identity=self.identity,
            token_source=lambda: self.token, clock=lambda: 1_700_000_000.0,
            has_home_channel=functools.partial(profile_has_home_channel, scope=lambda _bot: contextlib.nullcontext()))
        self.restarts: list[str] = []
        self.control = SeedingControl()
        self._patch_live(monkeypatch)

    @staticmethod
    def _make_avatar(tmp_path: Path) -> Path:
        path = tmp_path / "avatar.png"
        Image.new("RGBA", (64, 48), (10, 200, 30, 255)).save(path)
        return path

    def _patch_live(self, monkeypatch) -> None:
        def reload_routes(home, **_):
            self.route_reloads.append(Path(home))
            return {"reloaded": True}

        def restart(*args, **kwargs):
            self.restarts.append("restart")
            return {"restart_started": True}

        monkeypatch.setattr("hermes_cli.web_routers.messaging._restart_gateway_after", restart)
        monkeypatch.setattr("tui_gateway.methods_messaging_slack._slack_reload", restart)
        monkeypatch.setattr("gateway.control_socket.reload_gateway_routes", reload_routes)

    def service(self) -> ChatInstallService:
        return ChatInstallService(
            store=ChatInstallStore(self.home), provider_for=lambda _provider_id: self.provider, control=self.control,
            public_url=lambda: None, bot_scope=lambda _bot: contextlib.nullcontext())

    def identity(self, bot: str) -> ci.BotIdentitySource:
        return ci.BotIdentitySource(bot, self.names.get(bot, DISPLAY_NAME), str(self.avatar) if self.avatar else None)

    def allow_owner(self, owner: str = OWNER_ID) -> None:
        self.provider.allowlist.ensure(owner)

    def state(self, bot: str = BOT, workspace: str = GUILD_ID) -> wire.SetupState:
        return ci.initial_state(bot, "discord", workspace, 1_700_000_000.0)

    def install(self, bot: str = BOT, workspace: str = GUILD_ID) -> wire.Installation:
        return self.provider.install_in_place(self.state(bot, workspace))

    def config(self) -> dict:
        path = self.home / "config.yaml"
        return yaml.safe_load(path.read_text(encoding="utf-8")) if path.exists() else {}

    def config_text(self) -> str:
        path = self.home / "config.yaml"
        return path.read_text(encoding="utf-8") if path.exists() else ""

    def routes(self) -> list[dict]:
        return self.config().get("profile_routes", [])

    def record(self, bot: str = BOT, guild: str = GUILD_ID) -> dict:
        return DiscordRecords(self.records_path).app(bot, guild)

    def set_routes(self, routes: list[dict]) -> None:
        from hermes_cli.config import load_config, save_config
        config = load_config()
        config["profile_routes"] = routes
        save_config(config)

    def records_text(self) -> str:
        return self.records_path.read_text(encoding="utf-8")

    def webhook_secret(self, installation: wire.Installation) -> str:
        return self.vault.resolve_secret(installation.vault_item_ids[0])["api_key"]

    def webhook_ids(self) -> list[str]:
        return list(self.fake.webhooks)

    def home_channel(self, bot: str = BOT) -> str:
        return self.record(bot)["channel_id"]


def webhook_url_of(fake: FakeDiscord, webhook_id: str) -> str:
    return f"https://discord.com/api/webhooks/{webhook_id}/{fake.webhooks[webhook_id]['token']}"


def dumps(value) -> str:
    return json.dumps(value, sort_keys=True, default=str)


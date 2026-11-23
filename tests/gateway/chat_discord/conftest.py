from __future__ import annotations

import pytest

from tests.gateway.chat_discord.discord_kit import Kit


@pytest.fixture
def kit(tmp_path, monkeypatch):
    return Kit(tmp_path, monkeypatch)


@pytest.fixture
def avatar_kit(tmp_path, monkeypatch):
    return Kit(tmp_path, monkeypatch, with_avatar=True)

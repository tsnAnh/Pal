"""Telegram + Discord adapters read their chat copy from the i18n catalog at call time.

Pins the wave-4 contract: nothing user-facing is bound at import, Discord slash-command text is cut at the 100-char app-command cap
and both command-menu fingerprints change with the language.
"""

from __future__ import annotations

import pytest

from agent import i18n
from agent.i18n import t
from gateway.platforms.base import utf16_len

import plugins.platforms.discord.adapter as discord_adapter
import plugins.platforms.telegram.adapter as telegram_adapter
from plugins.platforms.discord.adapter import (
    _DISCORD_APP_COMMAND_TEXT_LIMIT,
    _NATIVE_SLASH_COMMAND_SPECS,
    DiscordAdapter,
    _native_slash_commands,
)
from plugins.platforms.telegram.adapter import TelegramAdapter, _TOAST_LIMIT


@pytest.fixture
def fake_locale(tmp_path, monkeypatch):
    """Point the catalog loader at a throwaway locales dir with an ``xx`` catalog whose values carry
    HTML metacharacters and exceed every platform cap; ``activate()`` switches the language to it."""
    import hermes_yaml as yaml

    locales = tmp_path / "locales"
    locales.mkdir()
    long_text = "L" * 300
    catalog = {
        "platform": {
            "telegram": {"approval": {"toast_already_resolved": long_text}},
            "discord": {
                "command": {
                    "new": {"description": long_text, "followup": "done"},
                    "reasoning": {"choice_none": long_text},
                },
            },
        },
    }
    (locales / "xx.yaml").write_text(yaml.safe_dump(catalog, allow_unicode=True), encoding="utf-8")
    real_dir = i18n._locales_dir()
    (locales / "en.yaml").write_text((real_dir / "en.yaml").read_text(encoding="utf-8"), encoding="utf-8")
    monkeypatch.setattr(i18n, "_locales_dir", lambda: locales)
    monkeypatch.setattr(i18n, "_normalize_lang", lambda lang, home=None: str(lang).lower())
    i18n.reset_language_cache()

    def activate(lang: str = "xx"):
        monkeypatch.setenv("HERMES_LANGUAGE", lang)
        i18n.reset_language_cache()

    yield activate
    monkeypatch.delenv("HERMES_LANGUAGE", raising=False)
    i18n.reset_language_cache()


# ── shared contract ──────────────────────────────────────────────────────────


@pytest.mark.parametrize("module", [telegram_adapter, discord_adapter])
def test_unauthorized_notice_is_resolved_per_call_not_at_import(module):
    assert not hasattr(module, "_UNAUTHORIZED"), "import-bound notice would freeze the language"
    assert callable(module._unauthorized)
    assert "allowed list" in module._unauthorized()


# ── Telegram ─────────────────────────────────────────────────────────────────


def test_telegram_toasts_are_cut_at_200(fake_locale):
    fake_locale()
    toast = telegram_adapter._toast("platform.telegram.approval.toast_already_resolved")
    assert len(toast) == _TOAST_LIMIT == 200
    assert len(telegram_adapter._unauthorized()) <= _TOAST_LIMIT


def test_telegram_menu_fingerprint_includes_language(fake_locale):
    rows = [("help", "Show help"), ("status", "Status")]
    english = TelegramAdapter._menu_fingerprint(rows)
    fake_locale()
    assert TelegramAdapter._menu_fingerprint(rows) != english
    fake_locale("en")
    assert TelegramAdapter._menu_fingerprint(rows) == english


def test_telegram_bot_command_descriptions_cut_at_256(monkeypatch):
    import sys
    from types import SimpleNamespace

    telegram_mod = sys.modules["telegram"]  # the shared conftest stub (or the real package)
    monkeypatch.setattr(telegram_mod, "BotCommand", lambda name, desc: SimpleNamespace(command=name, description=desc))
    rows = TelegramAdapter._bot_commands([("help", "x" * 400), ("status", None)])
    assert [len(c.description) for c in rows] == [256, 0]


# ── Discord ──────────────────────────────────────────────────────────────────

def test_discord_native_slash_specs_hold_catalog_keys_only():
    for name, description_key, args, _template, followup_key in _NATIVE_SLASH_COMMAND_SPECS:
        assert description_key.startswith(("platform.discord.command.", "slash.")), name
        assert t(description_key) != description_key, (name, description_key)
        if followup_key:
            assert t(followup_key) != followup_key, (name, followup_key)
        for arg_name, _type, _default, desc_key, choices in args:
            assert t(desc_key) != desc_key, (name, arg_name)
            for label, value in choices or ():
                # Bare level names ("low") are identifiers; anything with a dot must resolve.
                assert "." not in label or t(label) != label, (name, label, value)


def test_discord_native_slash_text_respects_100_char_cap(fake_locale):
    fake_locale()
    by_name = {row[0]: row for row in _native_slash_commands()}
    assert utf16_len(by_name["new"][1]) == _DISCORD_APP_COMMAND_TEXT_LIMIT == 100
    reasoning_choices = dict((v, k) for k, v in by_name["reasoning"][2][0][4])
    assert utf16_len(reasoning_choices["none"]) == 100
    assert reasoning_choices["low"] == "low"
    # Follow-ups stay keys until the command runs.
    assert by_name["new"][4] == "platform.discord.command.new.followup"
    for row in _native_slash_commands():
        assert utf16_len(row[1]) <= 100
        for arg in row[2]:
            assert utf16_len(arg[3]) <= 100



def test_discord_command_sync_fingerprint_includes_language(fake_locale, monkeypatch):
    adapter = DiscordAdapter.__new__(DiscordAdapter)
    adapter._client = None
    english = adapter._desired_command_sync_fingerprint()
    fake_locale()
    assert adapter._desired_command_sync_fingerprint() != english
    fake_locale("en")
    assert adapter._desired_command_sync_fingerprint() == english

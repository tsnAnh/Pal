from __future__ import annotations

import pytest

from tools.approval_detection_human import creates_bot_or_profile


@pytest.mark.parametrize("command", [
    "hermes bot create --help",
    "hermes bot create evo -h",
    "hermes profile create shop --help",
    "hermes profile import --help",
])
def test_a_command_that_only_prints_help_creates_nothing(command):
    assert creates_bot_or_profile(command) is False


@pytest.mark.parametrize("command", [
    "hermes bot create --help; hermes bot create evil",
    "hermes bot create --help && hermes profile create victim",
    "hermes bot create evil --description=--help",
    "hermes bot create evil -- --help",
    "hermes bot create evil --hel",
    "hermes profile import ./evil.tar.gz",
])
def test_a_command_that_can_still_create_is_refused(command):
    assert creates_bot_or_profile(command) is True

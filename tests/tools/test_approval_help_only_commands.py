from __future__ import annotations

import pytest

from tools.approval_detection_human import detect_human_required_command


@pytest.mark.parametrize("command", [
    "hermes bot create --help",
    "hermes bot create evo -h",
    "hermes profile create shop --help",
    "hermes -p work profile delete old --help",
])
def test_a_command_that_only_prints_help_needs_no_human(command):
    assert detect_human_required_command(command) == (False, None)


@pytest.mark.parametrize("command", [
    "hermes bot create --help; hermes bot create evil",
    "hermes bot create --help && hermes profile delete victim --yes",
    "hermes bot create evil --description=--help",
    "hermes bot create evil -- --help",
    "hermes bot create evil --hel",
    "hermes profile delete victim --yes",
    "hermes mcp add docs --command /bin/evil --replace-shared --args -h",
    "hermes mcp add docs --command /bin/evil --replace-shared --args --help",
])
def test_a_command_that_can_still_act_needs_a_human(command):
    found, description = detect_human_required_command(command)
    assert found and description

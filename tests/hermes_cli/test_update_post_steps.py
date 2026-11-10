"""Behaviour contract of ``updates.post_update_steps``: operator-declared commands an update runs after
the code and dependencies are current, in the ROOT home's scope. A step can never fail the committed
update; a failure is a receipt follow-up. Real subprocesses, real receipts, no mocks of the runner."""
from __future__ import annotations

import json
import os
import stat
import textwrap
from pathlib import Path

import pytest
import hermes_yaml

from hermes_cli import update_receipt

pytestmark = pytest.mark.platforms("linux", "macos")


def _script(directory: Path, name: str, body: str) -> str:
    path = directory / name
    path.write_text("#!/bin/sh\n" + textwrap.dedent(body), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return str(path)


def _declare(home: Path, **steps) -> None:
    (home / "config.yaml").write_text(
        hermes_yaml.safe_dump({"updates": {"post_update_steps": steps}}), encoding="utf-8")


@pytest.fixture()
def root(tmp_path, monkeypatch):
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    return home


def _run(capsys):
    from hermes_cli.update_cmd_post_steps import run_post_update_steps

    update_receipt.begin_update_receipt()
    run_post_update_steps()
    update_receipt.finalize_update_receipt("success")
    out = capsys.readouterr().out
    return out, update_receipt.read_latest_receipt()


def _followups(receipt) -> dict[str, str]:
    return {f["step"]: f["reason"] for f in receipt.get("followups") or []}


def test_no_declared_step_prints_nothing_and_records_nothing(root, capsys):
    (root / "config.yaml").write_text("model: {}\n", encoding="utf-8")
    out, receipt = _run(capsys)
    assert out == ""
    assert receipt["outcome"] == "success" and not receipt.get("followups")


def test_a_step_prints_its_line_and_leaves_the_run_a_clean_success(root, tmp_path, capsys):
    command = _script(tmp_path, "kit", 'echo "kit moved aaaaaaaaaaaa -> bbbbbbbbbbbb"\n')
    _declare(root, kit={"command": [command, "refresh"]})
    out, receipt = _run(capsys)
    assert "kit moved aaaaaaaaaaaa -> bbbbbbbbbbbb" in out
    assert receipt["outcome"] == "success" and not receipt.get("followups")
    assert [s["name"] for s in receipt["steps"]] == ["post_update:kit"]


def test_a_failing_step_is_a_followup_and_never_fails_the_update(root, tmp_path, capsys):
    command = _script(tmp_path, "kit", 'echo "partial noise"\necho "faker-kit: refused: source unreachable" >&2\nexit 1\n')
    _declare(root, kit={"command": [command]})
    out, receipt = _run(capsys)
    assert "Update follow-up 'post_update:kit' did not finish" in out
    assert "source unreachable" in _followups(receipt)["post_update:kit"]
    assert receipt["outcome"] == "success"


def test_one_failing_step_does_not_stop_the_next(root, tmp_path, capsys):
    bad = _script(tmp_path, "bad", "exit 3\n")
    good = _script(tmp_path, "good", 'echo second ran\n')
    _declare(root, a_bad={"command": [bad]}, b_good={"command": [good]})
    out, receipt = _run(capsys)
    assert "second ran" in out
    assert list(_followups(receipt)) == ["post_update:a_bad"]


def test_a_missing_command_is_a_followup_not_a_crash(root, tmp_path, capsys):
    _declare(root, kit={"command": [str(tmp_path / "nowhere" / "faker-kit")]})
    _, receipt = _run(capsys)
    assert "post_update:kit" in _followups(receipt)


def test_a_step_that_outlives_its_timeout_is_killed_with_its_children(root, tmp_path, capsys):
    marker = tmp_path / "grandchild.pid"
    command = _script(tmp_path, "slow", f'sleep 60 &\necho $! > {marker}\nwait\n')
    _declare(root, kit={"command": [command], "timeout": 1})
    _, receipt = _run(capsys)
    assert "timed out after 1s" in _followups(receipt)["post_update:kit"]
    pid = int(marker.read_text())
    from tests.waiting import wait_until

    def gone() -> bool:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        return False

    assert wait_until(gone, timeout=10)


@pytest.mark.parametrize("entry", [
    "not-a-mapping",
    {},
    {"command": "faker-kit refresh"},
    {"command": []},
    {"command": ["relative/faker-kit"]},
    {"command": ["/bin/true", 7]},
    {"command": ["/bin/true"], "timeout": 0},
    {"command": ["/bin/true"], "timeout": "soon"},
])
def test_an_invalid_declaration_is_reported_and_skipped(root, capsys, entry):
    _declare(root, kit=entry)
    _, receipt = _run(capsys)
    assert "post_update:kit" in _followups(receipt)
    assert receipt["outcome"] == "success"


def test_an_invalid_declaration_does_not_block_a_valid_one(root, tmp_path, capsys):
    good = _script(tmp_path, "good", "echo ran\n")
    _declare(root, broken={"command": "nope"}, good={"command": [good]})
    out, receipt = _run(capsys)
    assert "ran" in out
    assert list(_followups(receipt)) == ["post_update:broken"]


def test_steps_come_from_the_root_home_and_run_scoped_to_it(root, tmp_path, monkeypatch, capsys):
    seen = tmp_path / "seen-home"
    command = _script(tmp_path, "kit", f'echo "$HERMES_HOME" > {seen}\n')
    _declare(root, kit={"command": [command]})
    profile = root / "profiles" / "work"
    profile.mkdir(parents=True)
    (profile / "config.yaml").write_text(hermes_yaml.safe_dump({"updates": {"post_update_steps": {
        "intruder": {"command": ["/bin/false"]}}}}), encoding="utf-8")
    monkeypatch.setenv("HERMES_HOME", str(profile))
    _, receipt = _run(capsys)
    assert seen.read_text().strip() == str(root)
    assert not receipt.get("followups")


def test_the_plan_lists_declared_steps_and_omits_the_line_when_there_are_none(root, tmp_path, capsys):
    import hermes_cli.update_inventory as inventory

    plan = inventory.collect_runtime_inventory()
    assert plan.post_update_steps == []
    inventory.print_update_plan(plan)
    assert "Post-update steps" not in capsys.readouterr().out

    command = _script(tmp_path, "kit", "true\n")
    _declare(root, kit={"command": [command, "refresh"]})
    plan = inventory.collect_runtime_inventory()
    assert [step["name"] for step in plan.post_update_steps] == ["kit"]
    inventory.print_update_plan(plan)
    out = capsys.readouterr().out
    assert "Post-update steps" in out and "kit" in out and "refresh" in out
    restored = inventory.UpdatePlan.from_dict(json.loads(json.dumps(plan.to_dict())))
    assert restored.post_update_steps == plan.post_update_steps


def test_the_update_tail_runs_declared_steps_before_the_completion_line(root, tmp_path, monkeypatch, capsys):
    from hermes_cli.source_completion import complete_source_checkout

    command = _script(tmp_path, "kit", 'echo "kit moved aaaaaaaaaaaa -> bbbbbbbbbbbb"\n')
    _declare(root, kit={"command": [command, "refresh"]})
    monkeypatch.setattr("hermes_cli.venv_sync.publish_launchers", lambda checkout: None)
    monkeypatch.setattr("hermes_cli.source_build.build_update_products",
                        lambda checkout, *, desktop, after_dependencies=None: None)
    checkout = tmp_path / "checkout"
    checkout.mkdir()
    update_receipt.begin_update_receipt()
    complete_source_checkout(checkout, desktop=False, assume_yes=True)
    update_receipt.finalize_update_receipt("success")
    out = capsys.readouterr().out
    assert out.index("kit moved aaaaaaaaaaaa -> bbbbbbbbbbbb") < out.index("Update complete")
    assert not update_receipt.read_latest_receipt().get("followups")


@pytest.mark.parametrize("key", [
    "updates.post_update_steps.faker-kit.command",
    "updates.post_update_steps.faker-kit.timeout",
])
def test_config_set_recognizes_the_declaration_keys(key):
    from hermes_cli.config import _validate_config_key

    assert _validate_config_key(key) == (True, None)


def test_a_failing_steps_output_is_redacted_before_it_reaches_the_receipt(root, tmp_path, capsys):
    secret = "ghp_" + "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8"
    command = _script(tmp_path, "kit", f'echo "token {secret} rejected" >&2\nexit 1\n')
    _declare(root, kit={"command": [command]})
    out, receipt = _run(capsys)
    assert secret not in out and secret not in _followups(receipt)["post_update:kit"]

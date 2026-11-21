"""Behavioral tests for the Pal connector boundary guard."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "ci" / "check_pal_nous_boundary.py"
ROOT_MODULE = "tui_gateway/methods_connectors.py"


@pytest.fixture(scope="module")
def guard():
    spec = importlib.util.spec_from_file_location("check_pal_nous_boundary", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _write(root: Path, files: dict[str, str]) -> None:
    for rel, text in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")


def _reaches(guard, root: Path) -> list[tuple[str, str]]:
    reaches = guard.find_reaches(root)[0]
    return [(target, " -> ".join(chain)) for _importer, target, _line, chain in reaches]


def test_a_pal_root_that_imports_nothing_forbidden_is_clean(guard, tmp_path):
    _write(tmp_path, {ROOT_MODULE: "import json\n", "hermes_cli/nous_account.py": ""})

    assert _reaches(guard, tmp_path) == []


@pytest.mark.parametrize("source", [
    "from hermes_cli import nous_account\n",
    "from hermes_cli.nous_account import status\n",
    "import hermes_cli.anon_auth\n",
    "def later():\n    from tools.managed_tool_gateway import resolve\n",
    "import importlib\nmodule = importlib.import_module('tools.connectors.portal.client')\n",
])
def test_a_pal_root_that_imports_nous_code_is_reported(guard, tmp_path, source):
    _write(tmp_path, {ROOT_MODULE: source})

    reaches = _reaches(guard, tmp_path)

    assert reaches and reaches[0][1] == "tui_gateway.methods_connectors"


def test_a_forbidden_import_two_modules_down_the_connector_layer_is_reported_with_its_chain(guard, tmp_path):
    _write(tmp_path, {
        ROOT_MODULE: "from tools.connectors import run\n",
        "tools/connectors/__init__.py": "",
        "tools/connectors/run.py": "from tools.connectors import account\n",
        "tools/connectors/account.py": "from hermes_cli.nous_account import status\n",
    })

    reaches = _reaches(guard, tmp_path)

    assert [chain for _target, chain in reaches] == [
        "tui_gateway.methods_connectors -> tools.connectors.run -> tools.connectors.account"]
    assert reaches[0][0].startswith("hermes_cli.nous_account")


@pytest.mark.parametrize("module", ["hosted_surface", "hosted_install", "hosted_signin"])
def test_the_hosted_connector_registry_is_a_reach_even_though_it_holds_no_nous_import(guard, tmp_path, module):
    _write(tmp_path, {
        ROOT_MODULE: "def gate():\n    from tools.connectors import hosted_surface\n    return hosted_surface.available()\n",
        "tools/connectors/__init__.py": "",
        "tools/connectors/hosted_surface.py": "_installed = None\n",
        "tools/connectors/hosted_install.py": "",
        "tools/connectors/hosted_signin.py": "",
    })
    if module != "hosted_surface":
        (tmp_path / ROOT_MODULE).write_text(f"from tools.connectors import {module}\n")

    reaches = _reaches(guard, tmp_path)

    assert reaches and reaches[0][0] == f"tools.connectors.{module}"


def test_the_registry_reached_two_modules_down_is_reported_with_its_chain(guard, tmp_path):
    _write(tmp_path, {
        ROOT_MODULE: "from tools.connectors import run\n",
        "tools/connectors/__init__.py": "",
        "tools/connectors/run.py": "from tools.connectors import hosted_surface\n",
        "tools/connectors/hosted_surface.py": "",
    })

    assert _reaches(guard, tmp_path) == [
        ("tools.connectors.hosted_surface", "tui_gateway.methods_connectors -> tools.connectors.run")]


def test_a_session_authority_operation_module_is_a_pal_root(guard):
    assert "gateway/session_connections.py" in guard.root_paths()


def test_an_import_under_type_checking_is_not_a_reach(guard, tmp_path):
    _write(tmp_path, {ROOT_MODULE: (
        "from typing import TYPE_CHECKING\n"
        "if TYPE_CHECKING:\n    from hermes_cli.nous_account import status\n")})

    assert _reaches(guard, tmp_path) == []


def test_a_module_outside_the_connector_layer_is_not_walked(guard, tmp_path):
    _write(tmp_path, {
        ROOT_MODULE: "import hermes_cli.config\n",
        "hermes_cli/config.py": "from hermes_cli.nous_account import status\n",
    })

    assert _reaches(guard, tmp_path) == []


def test_a_nous_host_in_a_pal_swift_file_is_reported(guard, tmp_path):
    _write(tmp_path, {guard.SWIFT_ROOT + "/Thing.swift": 'let label = "Nous Portal"\n'})

    findings = guard.swift_literals(tmp_path)

    assert findings and findings[0][0].endswith("Thing.swift")


def _literals(guard, root: Path) -> list[tuple[str, int, str]]:
    walked = guard.find_reaches(root)[3]
    return guard.python_literals(root, walked)[0]


def test_a_nous_host_literal_two_modules_down_the_connector_layer_is_reported(guard, tmp_path):
    _write(tmp_path, {
        ROOT_MODULE: "from tools.connectors import run\n",
        "tools/connectors/__init__.py": "",
        "tools/connectors/run.py": "URL = 'https://hermes-agent.nousresearch.com/docs'\n",
    })

    assert _literals(guard, tmp_path) == [("tools/connectors/run.py", 1, "nousresearch")]


def test_a_host_literal_in_a_module_nothing_reaches_is_not_reported(guard, tmp_path):
    _write(tmp_path, {
        ROOT_MODULE: "import json\n",
        "tools/connectors/__init__.py": "",
        "tools/connectors/unused.py": "URL = 'https://composio.dev'\n",
    })

    assert _literals(guard, tmp_path) == []


def test_an_allowed_literal_passes_and_is_stale_once_the_literal_is_gone(guard, tmp_path, monkeypatch):
    monkeypatch.setattr(guard, "ALLOWED_LITERALS", {("tools/connectors/run.py", "nousresearch.com/docs"): "docs link"})
    _write(tmp_path, {
        ROOT_MODULE: "from tools.connectors import run\n",
        "tools/connectors/__init__.py": "",
        "tools/connectors/run.py": "URL = 'https://hermes-agent.nousresearch.com/docs'\n",
    })
    walked = guard.find_reaches(tmp_path)[3]

    findings, used = guard.python_literals(tmp_path, walked)

    assert findings == [] and used == {("tools/connectors/run.py", "nousresearch.com/docs")}

    (tmp_path / "tools/connectors/run.py").write_text("URL = 'https://example.com'\n")
    _findings, used = guard.python_literals(tmp_path, walked)

    assert used == set()


def test_an_allowance_without_a_reason_fails_the_run(guard, tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(guard, "ALLOWED_LITERALS", {("tools/connectors/run.py", "nousresearch"): " "})
    monkeypatch.setattr(guard, "CONNECTOR_LAYER", ("tools.connectors",))
    _write(tmp_path, {
        ROOT_MODULE: "from tools.connectors import run\n",
        "tools/connectors/__init__.py": "",
        "tools/connectors/run.py": "URL = 'https://hermes-agent.nousresearch.com/docs'\n",
    })

    assert guard.main(["--root", str(tmp_path)]) == 1
    assert "has no reason" in capsys.readouterr().out


def test_a_tree_without_any_pal_root_has_nothing_to_guard(guard, tmp_path, capsys):
    assert guard.main(["--root", str(tmp_path)]) == 0
    assert "No Pal connector roots" in capsys.readouterr().out


def test_a_vanished_root_fails_the_run(guard, tmp_path, capsys):
    _write(tmp_path, {ROOT_MODULE: "import json\n"})

    assert guard.main(["--root", str(tmp_path)]) == 1
    assert "is gone" in capsys.readouterr().out

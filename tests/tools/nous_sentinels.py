from __future__ import annotations

import importlib
import sys
import types

NOUS_MODULES = (
    "tools.connectors.gateway.config",
    "hermes_cli.nous_account",
    "hermes_cli.anon_auth",
    "tools.connectors.managed",
)

BOUND_ALIASES = (
    ("tools.connectors.hosted_install", "gateway_config", "tools.connectors.gateway.config"),
    ("tools.connectors.tool", "gateway_config", "tools.connectors.gateway.config"),
)


class Sentinel(types.ModuleType):
    def __init__(self, name: str, touched: list[str]) -> None:
        super().__init__(name)
        self._touched = touched

    def __getattr__(self, attr: str):
        if attr.startswith("__"):
            raise AttributeError(attr)
        self._touched.append(f"{self.__name__}.{attr}")
        raise AssertionError(f"{self.__name__}.{attr} was read")


def install_sentinels(monkeypatch) -> list[str]:
    touched: list[str] = []
    made = {name: Sentinel(name, touched) for name in NOUS_MODULES}
    for name, sentinel in made.items():
        parent, _, leaf = name.rpartition(".")
        importlib.import_module(parent)
        monkeypatch.setitem(sys.modules, name, sentinel)
        monkeypatch.setattr(sys.modules[parent], leaf, sentinel, raising=False)
    for holder, alias, target in BOUND_ALIASES:
        if holder in sys.modules:
            monkeypatch.setattr(sys.modules[holder], alias, made[target], raising=False)
    return touched

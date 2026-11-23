#!/usr/bin/env python3
"""Fail when a catalog connector's display name is missing, duplicated, or just its id title-cased.

``hermes_cli/data/pal_connectors.yaml`` is the only source of a connector's name in the Connect Apps
list. An id such as ``circleci`` title-cases to "Circleci", which is not how the brand writes itself.
Every entry therefore carries an explicit ``name``, and a ``name`` equal to the title-cased id fails
unless the id is a line of ``scripts/ci/connector_names_allowlist.txt`` (``<id>  <reason>``, two
spaces before the reason) for a brand that really is spelled that way. A stale allowlist line fails too.

Run: python scripts/ci/check_connector_names.py [catalog.yaml] [allowlist.txt]
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.append(str(ROOT))
import hermes_yaml as yaml

CATALOG = ROOT / "hermes_cli" / "data" / "pal_connectors.yaml"
ALLOWLIST = Path(__file__).with_name("connector_names_allowlist.txt")


def title_cased(connector_id: str) -> str:
    return connector_id.replace("-", " ").replace("_", " ").title()


def _allowlist(path: Path, problems: list[str]) -> set[str]:
    ids = set()
    for number, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        connector_id, separator, reason = line.partition("  ")
        if not separator or not reason.strip():
            problems.append(f"{path.name}:{number}: write '<id>  <reason>' with two spaces before a short reason")
        ids.add(connector_id)
    return ids


def check(catalog: Path, allowlist: Path) -> list[str]:
    problems: list[str] = []
    allowed = _allowlist(allowlist, problems)
    entries = yaml.safe_load(catalog.read_text(encoding="utf-8-sig"))["connectors"]
    by_id = {entry["id"]: entry.get("name") for entry in entries}
    seen: dict[str, str] = {}
    for connector_id, name in by_id.items():
        if not isinstance(name, str) or not name.strip():
            problems.append(f"{connector_id}: no explicit name. Set `name:` to the brand's own spelling in {catalog.name}.")
            continue
        if (other := seen.setdefault(name.casefold(), connector_id)) != connector_id:
            problems.append(f"{connector_id}: name {name!r} duplicates {other}. Give each connector a distinct name.")
        if name == title_cased(connector_id) and connector_id not in allowed:
            problems.append(
                f"{connector_id}: name {name!r} is just the id title-cased. Set `name:` to the brand's own spelling in "
                f"{catalog.name}, or, if that is how the brand writes it, add '{connector_id}  <reason>' to {allowlist.name}.")
    for connector_id in sorted(allowed):
        name = by_id.get(connector_id)
        if name != title_cased(connector_id):
            problems.append(f"{allowlist.name}: {connector_id} no longer needs its line (name is {name!r}). Remove it.")
    return problems


def main(argv: list[str]) -> int:
    catalog = Path(argv[1]) if len(argv) > 1 else CATALOG
    allowlist = Path(argv[2]) if len(argv) > 2 else ALLOWLIST
    problems = check(catalog, allowlist)
    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

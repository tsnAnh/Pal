#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ast
import re
from collections import deque
from pathlib import Path

FORBIDDEN = (
    "hermes_cli.nous_account",
    "hermes_cli.anon_auth",
    "hermes_cli.auth_nous",
    "tools.managed_tool_gateway",
    "tools.managed_gateway_auth",
    "tools.connectors.portal",
    "tools.connectors.managed",
    "tools.connectors.hosted_surface",
    "tools.connectors.hosted_install",
    "tools.connectors.hosted_signin",
)

_ACCOUNT = "tui_gateway/methods_connectors_account.py"
_OPERATION = "tui_gateway/methods_connectors.py"
_GOOGLE = "tui_gateway/methods_google_workspace.py"
_AUTH = "gateway/session_auth_controls.py"
_SESSION_OPERATION = "gateway/session_connections.py"

PAL_RPC_MODULES = {
    "connectors.catalog": (_ACCOUNT,),
    "connectors.setup.check": (_ACCOUNT,),
    "connectors.setup.progress.get": (_ACCOUNT,),
    "connectors.setup.progress.set": (_ACCOUNT,),
    "connectors.oauth_client.setup": (_ACCOUNT,),
    "connectors.oauth_client.save": (_ACCOUNT,),
    "connectors.oauth_client.connect": (_ACCOUNT,),
    "connectors.oauth_client.remove": (_ACCOUNT,),
    "connectors.google_ads.status": (_ACCOUNT,),
    "connectors.google_ads.save": (_ACCOUNT,),
    "connectors.google_ads.verify": (_ACCOUNT,),
    "connectors.discord.guilds": (_ACCOUNT,),
    "connectors.discord.token": (_ACCOUNT,),
    "connectors.discord.save": (_ACCOUNT,),
    "connectors.operation.status": (_OPERATION, _SESSION_OPERATION),
    "connectors.operation.wake": (_OPERATION, _SESSION_OPERATION),
    "connection.respond": (_OPERATION, _SESSION_OPERATION),
    "google_workspace.status": (_GOOGLE,),
    "google_workspace.signin.start": (_GOOGLE,),
    "google_workspace.signin.finish": (_GOOGLE,),
    "google_workspace.signin.cancel": (_GOOGLE,),
    "google_workspace.verify": (_GOOGLE,),
    "google_workspace.signout": (_GOOGLE,),
    "google_workspace.client.set": (_GOOGLE,),
    "auth.submit_oauth_tokens": (_AUTH,),
    "auth.submit_credential": (_AUTH,),
}

FIXED_ROOTS = (
    "hermes_cli/pal_connectors.py",
    "tools/connectors/mcp.py",
    "tools/connectors/mcp_launch.py",
    "tools/connectors/mcp_oauth.py",
    "tools/connectors/mcp_oauth_redirect.py",
    "gateway/oauth_client_setup.py",
)

SWIFT_ROOT = "apps/ios/Packages/PalKit/Sources/PalConnect"

ALLOWED: dict[tuple[str, str], str] = {}

ALLOWED_LITERALS: dict[tuple[str, str], str] = {
    ("tools/mcp_oauth.py", "https://nousresearch.github.io/hermes-agent/docs/oauth/client-metadata.json"):
        "CLI default Client ID Metadata Document; connector sign-ins set oauth.cimd to false "
        "(tools/connectors/mcp_oauth.py _without_cimd) so Pal never presents it",
    ("tools/mcp_oauth.py", "https://hermes-agent.nousresearch.com/docs/guides/oauth-over-ssh"):
        "docs link printed by the CLI only; connector sign-ins use _SSH_HINT_LOOPBACK, which omits it",
}

CONNECTOR_LAYER = (
    "tools.connectors",
    "tools.mcp_oauth",
    "tools.mcp_dashboard_oauth",
    "tools.auth_required",
    "hermes_cli.pal_connectors",
    "hermes_cli.mcp_catalog",
    "hermes_cli.mcp_config",
    "hermes_cli.oauth_paste",
    "tui_gateway.connector_",
    "tui_gateway.discord_connector",
    "tui_gateway.google_",
    "tui_gateway.mcp_",
    "tui_gateway.methods_connectors",
    "tui_gateway.methods_google_workspace",
    "tui_gateway.oauth_client_rpc",
    "gateway.auth_flows",
    "gateway.auth_prompts",
    "gateway.oauth_client_setup",
    "gateway.session_auth_controls",
)

_LITERAL = re.compile(r"nousresearch|composio", re.IGNORECASE)
_SWIFT_LITERAL = re.compile(r"nousresearch|composio|nous portal", re.IGNORECASE)

DESCRIPTION = (
    "Fail when a Pal connector path reaches Nous Research. Starting at the Pal roots (the modules behind "
    "the connector RPCs PalKit calls, the MCP sign-in modules and the owner OAuth client setup), follow "
    "every import, function-local ones included, through the connector layer (CONNECTOR_LAYER) and fail "
    "when a module in FORBIDDEN is imported. Imports under TYPE_CHECKING are skipped. Followed: import a.b; "
    "from a.b import c (a submodule, or a name a package facade lists in _LAZY_EXPORTS); relative imports; "
    "parent packages; literal importlib.import_module and __import__ names. A module outside the connector "
    "layer is a host hub (agent runtime, gateway runner, config store, dashboard) and is not walked. A "
    "string literal naming nousresearch or composio in any module the walk reaches, or in PalConnect Swift, "
    "fails too unless ALLOWED_LITERALS names that exact literal with a reason. "
    "ALLOWED, ALLOWED_LITERALS and CONNECTOR_LAYER entries that nothing uses, or that carry no reason, are stale "
    "and fail."
)


def module_file(root: Path, name: str) -> Path | None:
    base = root.joinpath(*name.split("."))
    for candidate in (base.with_suffix(".py"), base / "__init__.py"):
        if candidate.is_file():
            return candidate
    return None


def module_name(root: Path, path: Path) -> str:
    parts = list(path.relative_to(root).with_suffix("").parts)
    if parts[-1] == "__init__":
        parts.pop()
    return ".".join(parts)


def forbidden_of(name: str) -> str | None:
    return next((item for item in FORBIDDEN if name == item or name.startswith(item + ".")), None)


def layer_of(name: str) -> str | None:
    return next((prefix for prefix in CONNECTOR_LAYER if name.startswith(prefix)), None)


def is_type_checking(test: ast.expr) -> bool:
    return (isinstance(test, ast.Name) and test.id == "TYPE_CHECKING") or (
        isinstance(test, ast.Attribute) and test.attr == "TYPE_CHECKING")


def runtime_nodes(tree: ast.AST):
    stack = [tree]
    while stack:
        node = stack.pop()
        yield node
        for child in ast.iter_child_nodes(node):
            if not (isinstance(node, ast.If) and is_type_checking(node.test) and child in node.body):
                stack.append(child)


def lazy_exports(tree: ast.Module) -> dict[str, str]:
    for node in tree.body:
        targets = node.targets if isinstance(node, ast.Assign) else [node.target] if isinstance(node, ast.AnnAssign) else []
        if any(isinstance(target, ast.Name) and target.id == "_LAZY_EXPORTS" for target in targets) \
                and isinstance(node.value, ast.Dict):
            return {key.value: item.value for key, item in zip(node.value.keys, node.value.values)
                    if isinstance(key, ast.Constant) and isinstance(item, ast.Constant)
                    and isinstance(key.value, str) and isinstance(item.value, str)}
    return {}


def with_parents(name: str, line: int) -> list[tuple[str, int]]:
    parts = name.split(".")
    return [(".".join(parts[:index]), line) for index in range(1, len(parts) + 1)]


class Index:
    def __init__(self, root: Path):
        self.root = root
        self.trees: dict[str, ast.Module | None] = {}
        self.cached_edges: dict[str, list[tuple[str, int]]] = {}

    def tree(self, module: str) -> ast.Module | None:
        if module not in self.trees:
            path = module_file(self.root, module)
            try:
                self.trees[module] = ast.parse(path.read_text(encoding="utf-8-sig")) if path else None
            except (OSError, UnicodeDecodeError, SyntaxError):
                self.trees[module] = None
        return self.trees[module]

    def from_targets(self, module: str, node: ast.ImportFrom) -> list[tuple[str, int]]:
        if node.level:
            package = module.split(".")
            path = module_file(self.root, module)
            if path is not None and path.name != "__init__.py":
                package = package[:-1]
            package = package[: len(package) - (node.level - 1)]
            base = ".".join([*package, *([node.module] if node.module else [])])
        else:
            base = node.module or ""
        found = with_parents(base, node.lineno) if base else []
        facade = self.tree(base) if base else None
        lazy = lazy_exports(facade) if facade is not None else {}
        for alias in node.names:
            child = f"{base}.{alias.name}" if base else alias.name
            if alias.name != "*" and (forbidden_of(child) or module_file(self.root, child)):
                found.extend(with_parents(child, node.lineno))
            if alias.name in lazy:
                found.extend(with_parents(lazy[alias.name], node.lineno))
        return found

    def edges(self, module: str) -> list[tuple[str, int]]:
        if module in self.cached_edges:
            return self.cached_edges[module]
        tree = self.tree(module)
        found: list[tuple[str, int]] = []
        for node in runtime_nodes(tree) if tree is not None else ():
            if isinstance(node, ast.Import):
                for alias in node.names:
                    found.extend(with_parents(alias.name, node.lineno))
            elif isinstance(node, ast.ImportFrom):
                found.extend(self.from_targets(module, node))
            elif isinstance(node, ast.Call) and node.args:
                func = node.func
                called = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", None)
                first = node.args[0]
                if called in ("import_module", "__import__") and isinstance(first, ast.Constant) \
                        and isinstance(first.value, str):
                    found.extend(with_parents(first.value, node.lineno))
        self.cached_edges[module] = found
        return found


def root_paths() -> list[str]:
    return sorted({*FIXED_ROOTS, *(path for modules in PAL_RPC_MODULES.values() for path in modules)})


def root_modules(root: Path) -> list[str]:
    return [module_name(root, root / rel) for rel in root_paths() if (root / rel).is_file()]


def root_layers(root: Path) -> set[str]:
    return {layer for module in root_modules(root) if (layer := layer_of(module))}


def find_reaches(root: Path):
    index = Index(root)
    parent: dict[str, str | None] = {name: None for name in root_modules(root)}
    queue = deque(parent)
    reaches: list[tuple[str, str, int, list[str]]] = []
    allowed_used: set[tuple[str, str]] = set()
    layers_met: set[str] = set()
    while queue:
        module = queue.popleft()
        edges = index.edges(module)
        deepest: dict[tuple[str, int], str] = {}
        for target, line in edges:
            if (hit := forbidden_of(target)) and len(target) > len(deepest.get((hit, line), "")):
                deepest[(hit, line)] = target
        for target, line in edges:
            if hit := forbidden_of(target):
                if (module, hit) in ALLOWED:
                    allowed_used.add((module, hit))
                elif deepest.get((hit, line)) == target:
                    chain = [module]
                    while parent[chain[-1]] is not None:
                        chain.append(parent[chain[-1]])
                    reaches.append((module, target, line, chain[::-1]))
            elif (layer := layer_of(target)) and target not in parent and module_file(root, target):
                layers_met.add(layer)
                parent[target] = module
                queue.append(target)
    return reaches, allowed_used, layers_met, list(parent)


def python_literals(root: Path, modules: list[str]) -> tuple[list[tuple[str, int, str]], set[tuple[str, str]]]:
    findings = []
    allowed_used: set[tuple[str, str]] = set()
    for module in modules:
        path = module_file(root, module)
        rel = path.relative_to(root).as_posix()
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8-sig"))):
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and (match := _LITERAL.search(node.value)):
                allowed = [key for key in ALLOWED_LITERALS if key[0] == rel and key[1] in node.value]
                if allowed:
                    allowed_used.update(allowed)
                else:
                    findings.append((rel, node.lineno, match.group(0)))
    return findings, allowed_used


def swift_literals(root: Path) -> list[tuple[str, int, str]]:
    base = root / SWIFT_ROOT
    findings = []
    for path in sorted(base.rglob("*.swift")) if base.is_dir() else []:
        for number, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
            if match := _SWIFT_LITERAL.search(line):
                findings.append((path.relative_to(root).as_posix(), number, match.group(0)))
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=DESCRIPTION)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2],
                        help="repository root to inspect (default: this checkout)")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    if not root.is_dir():
        parser.error(f"repository root is not a directory: {root}")
    missing = [rel for rel in root_paths() if not (root / rel).is_file()]
    if len(missing) == len(root_paths()):
        print("No Pal connector roots in this tree.")
        return 0
    for rel in missing:
        print(f"::error::Pal root {rel} is gone; update PAL_RPC_MODULES or FIXED_ROOTS in scripts/ci/check_pal_nous_boundary.py")
    reaches, allowed_used, layers_met, walked = find_reaches(root)
    python_findings, literals_used = python_literals(root, walked)
    literals = [*python_findings, *swift_literals(root)]
    stale = [*sorted(set(ALLOWED) - allowed_used), *sorted(set(ALLOWED_LITERALS) - literals_used),
             *sorted(set(CONNECTOR_LAYER) - layers_met - root_layers(root))]
    for entry in stale:
        print(f"::error::stale entry {entry}; drop it from scripts/ci/check_pal_nous_boundary.py")
    unexplained = [entry for table in (ALLOWED, ALLOWED_LITERALS) for entry, reason in table.items() if not reason.strip()]
    for entry in unexplained:
        print(f"::error::entry {entry} has no reason; state why it is safe")
    if reaches:
        print("::error::a Pal connector path reaches Nous Research code")
        for importer, target, line, chain in reaches:
            print(f"  {module_file(root, importer).relative_to(root).as_posix()}:{line} imports {target}")
            print(f"    via {' -> '.join(chain)}")
        print("Move the shared name below the portal module, or split the Pal-called handler out of the "
              "module that imports it.")
    if literals:
        print("::error::a file on a Pal connector path names a Nous Research or Composio host")
        for rel, line, word in literals:
            print(f"  {rel}:{line} contains {word!r}")
    if reaches or literals or stale or unexplained or missing:
        return 1
    print("No Pal connector path reaches Nous Research.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

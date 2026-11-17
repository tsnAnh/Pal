"""Token size of the model-facing tools[] array (schemas + tool_search description) per session kind.

    HERMES_HOME=$(mktemp -d) python evals/tool_search/measure_tool_array.py [--json]

Approximation: the repo's chars/4 rule (tools.tool_search.estimate_tokens_from_schemas) over the
compact JSON of every schema the model receives. Session kinds: a Pal bot chat runs the
``hermes-cli`` bundle, an iPhone chat adds the ``iphone`` toolset to it, with and without a
registered device connector. Every other service-gated tool (kanban, slack, connections) is
treated as available: the numbers are a fully configured bot.
"""

from __future__ import annotations

import json
import sys

from gateway import device_connectors
import model_tools
from model_tools import get_tool_definitions
from tools.registry import registry
from tools.tool_search import estimate_tokens_from_schemas

DEVICE_TOOLSET = "iphone"
SESSION_KINDS = {
    "pal_bot_chat": (["hermes-cli"], False),
    "iphone_chat_no_device": (["hermes-cli", DEVICE_TOOLSET], False),
    "iphone_chat_with_device": (["hermes-cli", DEVICE_TOOLSET], True),
}


def assume_services_available_except_devices() -> None:
    for entry in registry._tools.values():
        if entry.toolset != DEVICE_TOOLSET:
            entry.check_fn = None
    registry._toolset_checks.clear()


def measure(toolsets: list[str], device_registered: bool) -> dict:
    device_connectors.any_enabled = lambda _home: device_registered
    model_tools._tool_defs_cache.clear()
    defs = get_tool_definitions(enabled_toolsets=toolsets, quiet_mode=True)
    names = [d["function"]["name"] for d in defs]
    return {"tokens": estimate_tokens_from_schemas(defs), "tool_count": len(defs), "tools": sorted(names)}


def main() -> int:
    assume_services_available_except_devices()
    report = {kind: measure(*spec) for kind, spec in SESSION_KINDS.items()}
    if "--json" in sys.argv:
        print(json.dumps(report, indent=2))
        return 0
    for kind, row in report.items():
        print(f"{kind}: {row['tokens']} tokens, {row['tool_count']} tools")
        print("  " + ", ".join(row["tools"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

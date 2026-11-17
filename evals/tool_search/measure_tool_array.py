"""Token size of the model-facing tools[] array (schemas + tool_search description) per session kind.

    HERMES_HOME=$(mktemp -d) python evals/tool_search/measure_tool_array.py [--json]

Approximation: the repo's chars/4 rule (tools.tool_search.estimate_tokens_from_schemas) over the
compact JSON of every schema the model receives. Session kinds: a Pal bot chat runs the
``hermes-cli`` bundle, an iPhone chat adds the ``iphone`` toolset to it. Every service-gated tool
(kanban, slack, connections, iphone) is treated as available: the number is a fully configured bot.
"""

from __future__ import annotations

import json
import sys

from model_tools import get_tool_definitions
from tools.registry import registry
from tools.tool_search import estimate_tokens_from_schemas

SESSION_KINDS = {
    "pal_bot_chat": ["hermes-cli"],
    "iphone_chat": ["hermes-cli", "iphone"],
}


def assume_every_service_available() -> None:
    for entry in registry._tools.values():
        entry.check_fn = None
    registry._toolset_checks.clear()


def measure(toolsets: list[str]) -> dict:
    defs = get_tool_definitions(enabled_toolsets=toolsets, quiet_mode=True)
    names = [d["function"]["name"] for d in defs]
    return {"tokens": estimate_tokens_from_schemas(defs), "tool_count": len(defs), "tools": sorted(names)}


def main() -> int:
    assume_every_service_available()
    report = {kind: measure(toolsets) for kind, toolsets in SESSION_KINDS.items()}
    if "--json" in sys.argv:
        print(json.dumps(report, indent=2))
        return 0
    for kind, row in report.items():
        print(f"{kind}: {row['tokens']} tokens, {row['tool_count']} tools")
        print("  " + ", ".join(row["tools"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

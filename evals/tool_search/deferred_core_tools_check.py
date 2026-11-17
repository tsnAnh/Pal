"""Scripted-model end-to-end check: a formerly eager core tool is reached through the bridge.

    HERMES_HOME=$(mktemp -d) python evals/tool_search/deferred_core_tools_check.py

No model call. A scripted turn plays what a model does with the 15-tool array: tool_search by
keyword, tool_describe the match, tool_call it through ``model_tools.handle_function_call`` (the
production dispatcher), one case per category. A case passes when the real handler answers, so a
bridge refusal (not available, not deferred, not found) fails it. Exit code 1 on any failure.
"""

from __future__ import annotations

import json
import sys

import measure_tool_array
from model_tools import _dispatch_bridge_tool, get_tool_definitions, handle_function_call

TOOLSETS = ["hermes-cli"]
BRIDGE_REFUSALS = ("not available", "directly-listed", "not_found", "must be a deferred")

CASES = (
    ("kanban", "kanban tasks list board", "kanban_list", {}),
    ("browser", "browser python cdp navigate", "browser_exec", {"code": "print(1)"}),
    ("delegation", "delegate subagent task", "delegate_task", {"goal": "say hi"}),
    ("cron", "cronjob schedule manage", "cronjob_manage", {"action": "list"}),
)


def run_case(category: str, query: str, tool: str, arguments: dict) -> str | None:
    found = json.loads(handle_function_call("tool_search", {"queries": [query]}, enabled_toolsets=TOOLSETS))
    if tool not in found["results"][0]["matches"]:
        return f"{category}: tool_search {query!r} did not return {tool}"
    described = json.loads(handle_function_call("tool_describe", {"names": [tool]}, enabled_toolsets=TOOLSETS))
    if tool not in described.get("tools", {}):
        return f"{category}: tool_describe did not load {tool}"
    call = {"calls": [{"name": tool, "arguments": arguments}]}
    result, redispatch = _dispatch_bridge_tool("tool_call", call, TOOLSETS, None)
    if redispatch is None:
        return f"{category}: tool_call refused: {result}"
    answer = handle_function_call("tool_call", call, enabled_toolsets=TOOLSETS)
    if any(marker in str(answer).lower() for marker in BRIDGE_REFUSALS):
        return f"{category}: bridge refusal: {str(answer)[:200]}"
    print(f"ok {category}: {tool} -> {str(answer)[:90]}")
    return None


def main() -> int:
    measure_tool_array.assume_services_available_except_devices()
    eager = {d["function"]["name"] for d in get_tool_definitions(enabled_toolsets=TOOLSETS, quiet_mode=True)}
    failures = [f"{tool} is still eager" for _, _, tool, _ in CASES if tool in eager]
    failures += [error for case in CASES if (error := run_case(*case))]
    for failure in failures:
        print(f"FAIL {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

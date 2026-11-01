import json
from pathlib import Path

from hermes_constants import get_hermes_home
from tools.bot_desktop import lease
from tools.bot_mode_probe import _is_bot_managed
from tools.registry import registry, tool_error


def request_handback_tool(reason: str) -> str:
    cleaned = " ".join(str(reason or "").split())
    if not cleaned:
        return tool_error("reason is required: say in one short sentence what the person needs to do.")
    pending = lease.request_handback(cleaned)
    return json.dumps({
        "success": True,
        "status": "waiting_for_person",
        "reason": pending.ask,
        "requested_at": pending.ask_at,
        "person_in_control": pending.holder == lease.HUMAN,
        "next": (
            "End your turn now with one short line telling the person what you need. Do not touch the "
            "screen or retry the step. They will message you when they are done."
        ),
    }, ensure_ascii=False)


def check_request_handback() -> bool:
    return _is_bot_managed(Path(get_hermes_home()))


REQUEST_HANDBACK_SCHEMA = {
    "name": "request_handback",
    "description": (
        "Hand your computer to the person for a step only a human can do: signing in (password, SSO, "
        "passkey), a CAPTCHA or bot check, a code sent to another device, or a site that blocks "
        "automation. Never try to bypass, solve or work around such a step. Call this instead, then end "
        "your turn with one short line. The chat shows the person an Open computer button; while they "
        "have control your screen actions are refused, and when they finish they message you to "
        "continue from where you stopped."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "reason": {
                "type": "string",
                "description": (
                    "One short sentence naming the step, shown to the person, e.g. "
                    "'Sign in to Example to continue'."
                ),
            },
        },
        "required": ["reason"],
    },
}


registry.register(
    name="request_handback", toolset="desktop_ui", schema=REQUEST_HANDBACK_SCHEMA,
    handler=lambda args, **kw: request_handback_tool(reason=args.get("reason", "")),
    check_fn=check_request_handback, emoji="🖐️",
)

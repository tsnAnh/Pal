from __future__ import annotations


def _cmd_bot(args) -> None:
    from hermes_cli.bot_cmd import cmd_bot
    cmd_bot(args)


def build_bot_parser(subparsers) -> None:
    bot_parser = subparsers.add_parser(
        "bot", help="Create bots (isolated profiles with their own model, skills and memory)")
    bot_subparsers = bot_parser.add_subparsers(dest="bot_action")

    bot_create = bot_subparsers.add_parser(
        "create", help="Create a blank bot that keeps only the current model",
        description="Create a new profile as a one-time snapshot of the current model. It starts with "
            "every currently visible skill disabled, no MCP servers, no connectors and empty memory, "
            "and is never linked to this profile afterwards. Needs the owner's approval in an "
            "interactive session when run by an agent.")
    bot_create.add_argument("bot_name", help="Bot name (lowercase, alphanumeric)")
    bot_create.add_argument("--display-name", default=None, help="Name shown in the UI (max 64 characters)")
    bot_create.add_argument("--description", default=None, help="One- or two-sentence description of the bot")
    bot_create.add_argument("--json", action="store_true", help="Print {\"name\", \"home\"} as JSON")

    bot_parser.set_defaults(func=_cmd_bot)

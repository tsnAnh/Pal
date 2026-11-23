from __future__ import annotations

import argparse

from hermes_cli.subcommands._shared import add_json_flag


def _cmd_tailnet(args: argparse.Namespace) -> int:
    from hermes_cli.tailnet_access import tailnet_command
    return tailnet_command(args)


def build_tailnet_parser(subparsers) -> None:
    tailnet_parser = subparsers.add_parser(
        "tailnet", help="Reach this Mac's Pal from your other devices over Tailscale",
        description="Serve the local gateway at this Mac's Tailscale name with username/password sign-in.")
    actions = tailnet_parser.add_subparsers(dest="tailnet_command", required=True)
    for name, text in (("status", "Show whether Tailscale access is on"),
                       ("on", "Turn Tailscale access on, or rotate its password"),
                       ("off", "Turn Tailscale access off")):
        action = actions.add_parser(name, help=text, description=text)
        add_json_flag(action, "Emit the result as JSON")
        action.set_defaults(func=_cmd_tailnet)

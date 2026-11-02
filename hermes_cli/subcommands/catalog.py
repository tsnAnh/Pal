from __future__ import annotations

import argparse


def cmd_catalog_migrate(args: argparse.Namespace) -> int:
    from hermes_cli.profile_admin_guard import ProfileAdminDenied, require_profile_admin_grant
    from hermes_cli.shared_catalog_migrate import migrate
    from hermes_cli.shared_catalog_rollback import rollback

    if not args.dry_run:
        try:
            require_profile_admin_grant("catalog_migrate")
        except ProfileAdminDenied as denied:
            print(denied)
            return 1
    if args.rollback:
        if args.dry_run:
            print("--dry-run cannot be combined with --rollback")
            return 2
        return rollback()
    return migrate(dry_run=args.dry_run, retry_failed=args.retry_failed)


def build_catalog_parser(subparsers) -> None:
    catalog_parser = subparsers.add_parser(
        "catalog", help="Shared skills and MCP server catalog across bots",
        description="Skills and MCP server definitions live once in a shared catalog visible to every "
            "bot; each bot keeps its own on/off state and secrets.")
    catalog_sub = catalog_parser.add_subparsers(dest="catalog_command", required=True)
    migrate_parser = catalog_sub.add_parser(
        "migrate", help="Move every bot's skills and MCP definitions into the shared catalog",
        description="Back up every bot's skills and config.yaml, merge identical skills and servers, rename "
            "conflicting ones to <bot>-<name> (and repoint that bot's cron jobs and skill lists), and preserve each "
            "bot's enabled set. Re-running is a no-op; an interrupted run resumes. --rollback restores every bot's "
            "skills from the newest backup and puts shared server definitions back into each bot, keeping settings "
            "changed since the migration.")
    migrate_parser.add_argument("--dry-run", action="store_true", help="Print the merge plan without changing anything")
    migrate_parser.add_argument(
        "--retry-failed", action="store_true", help="Finish switching over bots a previous migration could not")
    migrate_parser.add_argument("--rollback", action="store_true", help="Restore the newest migration backup")
    migrate_parser.set_defaults(func=cmd_catalog_migrate)

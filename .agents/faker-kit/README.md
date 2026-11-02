# Vendored faker-kit

Generated. Do not edit anything under this folder by hand; `check` fails if it changes.

This is faker-kit at the commit in `KIT.json`, copied in so that every agent session, including
cloud sessions that start from a bare clone, has the kit's skills. The skills are linked from
`.claude/skills/` and `.agents/skills/`, and the subagents from `.claude/agents/`.

To move to another kit commit, run `faker-kit vendor --project <project>` on the Hermes machine, or, from a kit
checkout at that commit, `python3 plugins/trust-ladder/skills/setup-cloud-agents/scripts/vendor_kit.py
--kit . --into <this repository>`, and merge the pull request.

The vendored plugins keep their own `LICENSE` files. `NOTICE.md` says where each comes from.

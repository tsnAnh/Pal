<!-- faker-kit:compat:start -->
## Running the upstream skills in Claude Code

The pstack, team-workflows, thermos, advisor, continual-learning, agent-compatibility, and teaching skills were written for another editor and are kept close to word for word. pstack's `docs/harness/claude-code.md` maps the names its skills use to Claude Code; read it once per session. The rows below cover the rest of the plugins and replace the adapter where the team chose differently.

| The skill says | In Claude Code |
|---|---|
| `subagent_type: "thermo-nuclear-review-subagent"` and the other named agents | `<plugin>:<name>`, for example `thermos:thermo-nuclear-review-subagent` |
| `.agents/settings.json`, enabling a plugin for a repository | `enabledPlugins` in `.claude/settings.json` |
| The agent's built-in `create-skill` | The `skill-creator` skill, else the faker-mode "Authoring a skill" playbook |
| The agent's built-in `babysit` | The faker-mode Babysit playbook |
| Custom Mode, a skill pinned across turns | trust-ladder's hook keeps `/faker-mode` on until you say "exit faker mode" |
| Hooks, such as `afterFileEdit` and `stop` | Plugin hooks, through each plugin's `agent-hooks/` |
| Cloud agents, `environment: "cloud"` (overrides the adapter's worktree row) | A Claude Code cloud session, started with `claude --cloud`. A Hermes project bot starts one with `faker-kit launch --brief-file`, from the brief it wrote, per `.agents/dispatch.json` |
| Automations, Grok Bot (overrides the adapter's skip row) | Hermes cron and webhook jobs, which run while the gateway runs |
| Bugbot, agentic security review (overrides the adapter's Bugbot row) | The Claude GitHub review app, set up with `setup-faker-kit` (Review bots) |

Spawn `faker-agent` with the task brief and the absolute path of the `faker-mode` skill's `SKILL.md`; it reads that file itself, so the prompt does not need to start with `/faker-mode`. The cloud session `faker-kit launch` starts for a Hermes project bot is a top-level session, so its brief still starts with `/faker-mode`.

### Models

Each teammate runs Claude Code on Claude Opus 5.5 at max effort.

- Every pstack role and panel seat defaults to `inherit-parent`. Omit `model` and run it on your own agent. A panel keeps its size: each seat is a separate run, so the opinions stay independent.
- A seat someone configured with a model name: `claude-opus-5-5-max` is `model: opus`. For a GPT name, run the seat on your own model and say so.
- Agent files that say `model: inherit` run on your current model.

### Upstream hooks

advisor's end-of-turn nudge and continual-learning's cadence nudge are upstream hooks. They run unchanged through each plugin's `agent-hooks/`, which maps the upstream `afterFileEdit`, `afterAgentResponse`, `stop`, and `subagentStop` events to `PostToolUse`, `Stop`, and `SubagentStop`. A follow-up they post arrives as a hook message that asks you to continue: act on it like a user turn. advisor's hooks need `jq`; continual-learning's needs `bun`. Without them the hook does nothing.
<!-- faker-kit:compat:end -->

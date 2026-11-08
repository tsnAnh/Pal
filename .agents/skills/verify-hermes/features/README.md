# Hermes engine verification map

This directory is the maintained source for verifying the user-facing behavior of the Hermes engine from this checkout: the `hermes` CLI, the classic REPL, and the `hermes serve` JSON-RPC backend. Read the index before driving, then use the matching feature file as the recipe. Desktop and iOS are covered by `verify-desktop` and `verify-ios`.

## Baseline preconditions

- `.venv/bin/python`, `node` 26 or newer and `tmux` are present.
- Every recipe starts from `R=$(hv up)`, or `R=$(hv up --serve)` when the recipe says it needs serve. `hv` means `.agents/skills/verify-hermes/scripts/hv`, run from the repo root.
- `hv doctor $R` exits 0 before the first action.
- The sandbox home is empty apart from the mock provider config. No session exists until a recipe creates one.
- Never drive an instance this verification run did not start. Never touch `~/.hermes`.

## Driving conventions

- Start each recipe from a fresh run unless its preconditions say otherwise.
- Put `--` before Hermes flags: `hv hermes $R -- -z "say hi"`.
- Match literal strings from the product: the prompt `❯ `, the panel header `☤ Hermes`, the mock reply `Hello from the mock inference server! The full boot chain is working.`
- REPL waits use `hv tmux $R wait REGEX`. The reply text repeats each turn, so on turn N pass `--count N`.
- Always finish with `hv down $R`, including after a failure.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final screen.
- CLI proof is the command, stdout, stderr and exit code (`hv hermes` saves all four). REPL proof is a pane capture. RPC proof is the frames file.
- Mutation proof includes a second view of the stored value: `hermes sessions list`, `session.list`, `hermes config get`, or `hv mock-prompts`.
- Record the feature ID and the entry point used when you report an artifact.
- Report an unreachable path with the attempted command and the unmet precondition. Do not report a skipped entry point as verified through a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with hv` starts with `Preconditions:` and uses labeled bullets that pair each user action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

## Features

- [One-shot chat](./oneshot-chat.md) covers `hermes -z` and `hermes chat -q`: one turn, plain output, exit codes, provider receipt and a stored session.
- [REPL session](./repl-session.md) covers the classic REPL: banner, prompt, a streamed turn, `/history`, `/quit` and the stored session.
- [Serve and JSON-RPC chat](./serve-rpc-chat.md) covers `hermes serve` readiness, `/api/status`, the WebSocket gateway, a chat turn, session listing and resume.
- [Slash commands](./slash-commands.md) covers the shared command registry in the REPL, `commands.catalog` and `slash.exec`.
- [Config and sessions CLI](./config-and-sessions-cli.md) covers `hermes config`, `hermes sessions`, `hermes status` and `hermes doctor`.

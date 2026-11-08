# Slash commands

A user types `/` commands in the REPL, and clients list and run the same commands over JSON-RPC. One registry in `hermes_cli/commands.py` defines the names, aliases and help text for every surface.

## Sub-features

- `slash-help` prints the `Available Commands` table grouped by category.
- `slash-version` prints the Hermes version, install directory, install method and update state.
- `slash-catalog` lists commands, categories and skill commands through `commands.catalog`.
- `slash-exec` runs a command for a live session through `slash.exec` and returns its text in `output`.
- `slash-alias` resolves an alias to its canonical command, so `/v` behaves like `/version`.
- `slash-unknown` reports an unknown command without ending the session.

## How to get to it (user POV)

- Type `/help`, `/version`, `/status` or any listed command at the REPL `❯ ` prompt.
- Type `/` to see completions, or press Ctrl+P for the command palette.
- A client calls `commands.catalog` and `slash.exec` over the gateway socket.

## Driving it with hv

Preconditions:

- `R=$(hv up --serve)` and `hv doctor $R` exit 0.

- **REPL help.** Start the REPL with `hv tmux $R start -- --cli` and `hv tmux $R wait 'Welcome to Hermes Agent' --timeout 120`, then run `hv tmux $R send "/help"` and `hv tmux $R wait 'Available Commands'`. The pane lists `── Session ──`, `── Configuration ──`, `/new`, `/model` and `/quit`.
- **REPL version.** Run `hv tmux $R send "/version"` and `hv tmux $R wait 'Install method'`. The pane shows `Hermes Agent v` with the same version as `hv hermes $R -- --version`.
- **REPL alias.** Run `hv tmux $R send "/v"` and `hv tmux $R wait 'Install method' --count 2`. The version block appears a second time.
- **Unknown command.** Run `hv tmux $R send "/nosuchcmd"` and `hv tmux $R wait 'Unknown command /nosuchcmd'`. The pane shows `Unknown command /nosuchcmd — nothing was sent.` and `Type /help for the full list.`, and the `❯ ` prompt is still there.
- **Capture and leave.** Run `hv tmux $R capture slash`, then `hv tmux $R send "/quit"`.
- **Catalog.** Run `hv rpc $R commands.catalog '{}'`. `pairs` contains `/new`, `/help` and `/version` with descriptions, and `categories` names include `Session` and `Info`.
- **Exec.** Create a session with `hv rpc $R session.create '{"cols":120,"source":"hv"}'`, then run `hv rpc $R slash.exec '{"session_id":"<session_id>","command":"/version"}'`. The `output` starts with `Hermes Agent v` and ends with an update line such as `Up to date`.
- **Proof.** The pane capture and the `*-rpc-*.frames.jsonl` file under `hv path $R evidence` show the same version text from both surfaces.

## Gotchas

- `slash.exec` needs a runtime `session_id` from `session.create` on the same running serve. An unknown id returns error `4001` `session not found`.
- `slash.exec` starts a slash-worker subprocess on first use. It can take several seconds, and `hv down` stops it with the serve process tree.
- `/help` output is long. Capture it to a file instead of reading it from the terminal. `hv rpc` prints the full text.
- Catalog presence does not mean every surface can run a command. Some are REPL-only and the gateway answers `unsupported_command`. Test the surface you changed.
- `/quit` on an empty session prints `Goodbye!`. After a turn it prints `Resume this session with:`.

# Config and sessions CLI

A user reads and changes configuration, lists and exports stored sessions, and checks health from the shell, without starting a chat.

## Sub-features

- `config-get` prints a value from the active `config.yaml`, such as `model.default`.
- `config-set` writes a value to `config.yaml` and a later `config get` reads it back.
- `config-path` prints the active config path inside the sandbox home.
- `sessions-list` lists stored sessions with preview, workspace, source and id.
- `sessions-export` writes a stored session to a JSONL file.
- `status` prints model, provider and component state.
- `doctor` prints a health report and a list of issues.

## How to get to it (user POV)

- Run `hermes config get <key>`, `hermes config set <key> <value>` or `hermes config path`.
- Run `hermes sessions list` or `hermes sessions export <file> --session-id <id>`.
- Run `hermes status` or `hermes doctor`.

## Driving it with hv

Preconditions:

- `R=$(hv up)` and `hv doctor $R` exit 0.
- One stored session exists: `hv hermes $R -- -z "seed session"` exited 0.

- **Read.** Run `hv hermes $R -- config get model.default`. Stdout is `mock-model`.
- **Path.** Run `hv hermes $R -- config path`. Stdout is `<hermes-home>/config.yaml` where `<hermes-home>` equals `hv path $R hermes-home`.
- **Write.** Run `hv hermes $R -- config set display.skin mono`. Stdout says `Set display.skin = mono` and names the sandbox config path.
- **Read back.** Run `hv hermes $R -- config get display.skin` and `grep -n "skin" "$(hv path $R hermes-home)/config.yaml"`. Stdout is `mono` and the file has `skin: mono` under `display:`.
- **List.** Run `hv hermes $R -- sessions list`. One row has Preview `seed session` and Src `oneshot`.
- **Export.** Run `hv hermes $R -- sessions export "$(hv path $R evidence)/seed.jsonl" --session-id <id from the list>`. Stdout says `Exported 1 session to` the path. The file's first line is JSON with `"source": "oneshot"` and a `system_prompt`.
- **Status.** Run `hv hermes $R -- status`. Stdout has `Model:        mock-model` and `Provider:     custom`.
- **Doctor.** Run `hv hermes $R -- doctor`. The report ends with `Found N issue(s) to address`. The expected harness items are the migrate-config hint, the missing `~/.local/bin/hermes` symlink, missing API keys and the mock `custom_providers` entry.
- **Proof.** The `.stdout` files and `seed.jsonl` under `hv path $R evidence`, plus the `grep` output, show the written value and the stored session.

## Gotchas

- Run these only through `hv hermes`. A bare `hermes config set` in the caller's shell edits the real `~/.hermes`.
- `config set` of a secret-shaped name routes to `.env`, not `config.yaml`. Use a non-secret key like `display.skin` for the round trip.
- `sessions list` ids differ by source. `hermes -z` makes a long `local-<hash>` id. Gateway sessions use a short date id like `20261108_031258_aeb032`.
- `hermes doctor` takes about 20 seconds and exits nonzero-looking text (`Found N issue(s)`) even in a healthy sandbox. Judge the listed items, not the count.
- `sessions export` writes the full system prompt and messages. Keep the file in the evidence dir only. Do not export from a sandbox that talked to a real provider.

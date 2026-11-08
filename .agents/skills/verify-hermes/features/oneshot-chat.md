# One-shot chat

A user or script sends a single prompt from the shell and gets the model's final answer on stdout, with no banner or spinner, then the process exits. The turn is stored as a session and reaches the configured provider.

## Sub-features

- `oneshot-z` prints only the final reply for `hermes -z PROMPT` and exits 0.
- `oneshot-q` prints a `session_id:` line and then the reply for `hermes chat -q PROMPT -Q`.
- `oneshot-provider` sends the prompt to the provider in `config.yaml`, not to a default.
- `oneshot-persist` stores the turn as a session with source `oneshot` and the prompt as its preview.

## How to get to it (user POV)

- Run `hermes -z "<prompt>"` in a terminal or script.
- Run `hermes chat -q "<prompt>" -Q` for programmatic use with a session id.
- Run `hermes chat --query-file <path>` to read the prompt from a file.

## Driving it with hv

Preconditions:

- `R=$(hv up)` and `hv doctor $R` exit 0.
- No session exists yet: `hv hermes $R -- sessions list` prints `No sessions found.`

- **Plain reply.** Send one prompt. Run `hv hermes $R -- -z "say hi"`. Exit code 0 and stdout is exactly `Hello from the mock inference server! The full boot chain is working.`
- **Provider receipt.** Check what the provider saw. Run `hv mock-prompts $R`. `receivedPrompts` has an entry that starts with `say hi`.
- **Stored session.** Read the history from a second view. Run `hv hermes $R -- sessions list`. One row has Preview `say hi` and Src `oneshot`.
- **Quiet chat.** Run `hv hermes $R -- chat -q "quiet one" -Q`. Stdout has a line starting `session_id: local-` followed by the mock reply. Exit code 0.
- **Proof.** The `.stdout`, `.stderr` and `.cmd` files of each step under `hv path $R evidence` hold the command, output and exit code. Add `hv hermes $R -- sessions list` output for the stored-session view.

## Gotchas

- The first `hermes` command in a fresh sandbox takes 15 to 30 seconds. Do not treat that as a hang. Keep the default 240 s timeout.
- `-z` prints only the reply, so a passing run has no `session_id`. Use `chat -q -Q` when you need the id.
- The first prompt in a fresh home may reach the provider with a "first message ever" system note appended. Assert with `startswith`, not equality.
- An unreachable provider is not a reliable recipe. With the mock killed, `-z` once exited 1 after 17 s with `Error: Gateway connection failed; no local fallback` and another time ran past 240 s. `hv hermes` then exits 124 and records the timeout.
- Do not export `OPENAI_*` or provider keys to make a command work. The harness scrubs them on purpose.

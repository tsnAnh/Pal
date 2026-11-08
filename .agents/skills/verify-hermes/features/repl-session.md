# REPL session

A user starts the classic prompt_toolkit REPL, sees the banner and an input prompt, chats, reviews the conversation, quits and finds the session saved.

## Sub-features

- `repl-banner` shows the Hermes banner with the version and the line `Welcome to Hermes Agent!`.
- `repl-prompt` shows the `❯ ` input prompt and the status bar with the model name.
- `repl-turn` sends typed text and renders the reply under a `☤ Hermes` header.
- `repl-history` lists both messages under `/history`.
- `repl-quit` exits on `/quit`, prints the session summary and a resume command, and exits with status 0.
- `repl-persist` leaves the session in history with source `cli→local` and the first message as its preview.

## How to get to it (user POV)

- Run `hermes` in a terminal.
- Run `hermes --cli` to force the classic REPL when `display.interface` is `tui`.
- Run `hermes -c` or `hermes --resume <id>` to reopen a stored session in the REPL.

## Driving it with hv

Preconditions:

- `R=$(hv up)` and `hv doctor $R` exit 0.
- No other tmux session is attached to this run.

- **Start.** Open the REPL. Run `hv tmux $R start -- --cli` then `hv tmux $R wait 'Welcome to Hermes Agent' --timeout 120`. The banner shows `Hermes Agent v` with this checkout's version, and the screen ends with a `❯ ` prompt and a `☤ mock-model` status bar.
- **Turn.** Send a message. Run `hv tmux $R send "hello repl"` then `hv tmux $R wait 'Hello from the mock inference server' --timeout 90`. The pane shows `❯ hello repl`, a `☤ Hermes` header and the mock reply.
- **History.** Run `hv tmux $R send "/history"` then `hv tmux $R wait 'Conversation History'`. The pane lists `[You #1] hello repl` and `[Hermes #2]` with the mock reply.
- **Capture.** Run `hv tmux $R capture after-history`. The saved screen shows the banner, the turn and the history.
- **Quit.** Run `hv tmux $R send "/quit"` then `hv tmux $R wait 'Resume this session with' --timeout 30`. The pane shows `Messages: 2 (1 user, 0 tool calls)`. `hv doctor $R` reports the tmux process as exited.
- **Stored session.** Run `hv hermes $R -- sessions list`. One row has Preview `hello repl` and Src `cli→local`.
- **Proof.** `hv path $R evidence` holds the pane captures and the `sessions list` stdout. A clean pass also means the pane exit status in the last capture is 0 (`Pane is dead (status 0`).

## Gotchas

- A fresh home that has not answered the shared-metrics offer opens a "Help improve Hermes?" dialog that eats typed text. `hv up` pre-answers it. If you see the dialog, the sandbox config was not written by `hv up`.
- Run the REPL from the sandbox `work/` directory only (`hv tmux` does). From the repo root it loads the repo's `AGENTS.md` and prints a project-skills trust notice.
- The input line shows a rotating placeholder such as `What changed in this repo recently?` before you type. It is not a message.
- After one turn `/quit` prints `Resume this session with:`. With no messages it prints `Goodbye!` instead. Wait for the one that matches your recipe.
- `hermes --tui` does not start under this harness. The sandbox disables lazy installs, and the TUI needs the PM-managed `node`. Report the Ink TUI as unverified, do not substitute the REPL.

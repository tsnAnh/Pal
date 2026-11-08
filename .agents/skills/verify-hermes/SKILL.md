---
name: verify-hermes
description: Drive the real Hermes engine from this checkout (the `hermes` CLI and classic REPL, one-shot `-z` and `chat -q`, `hermes serve` with its JSON-RPC gateway, slash commands, sessions, config) in an isolated sandbox against the repo's fake LLM, and capture proof. Use after any change under cli.py, hermes_cli/, agent/, tui_gateway/, gateway/ or hermes_state*.py that a CLI user or a gateway client can see, before reporting the change done. Not for apps/desktop (verify-desktop), apps/ios (verify-ios), the Ink TUI, or real providers.
---

# verify-hermes

The Hermes engine is one Python agent core behind several front ends. This skill drives the front ends an agent can reach without a window or a real model: the `hermes` CLI (one-shot `-z`, `chat -q`, the classic prompt_toolkit REPL, config and session subcommands) and `hermes serve`, the JSON-RPC/WebSocket backend that Desktop, iOS and the dashboard also use. Every run gets a disposable `HERMES_HOME` and a fake OpenAI-compatible provider (`tests-js/scripts/mock-server.ts`) that answers every turn with a canned reply. Nothing touches `~/.hermes` or a real provider.

All paths are relative to the repo root. `hv` below means `.agents/skills/verify-hermes/scripts/hv`.

Read the feature map first: `features/README.md` lists what is covered and how to prove each feature. Run `hv` with no arguments or `hv --help` for the command list.

## Launch

Needs `.venv/bin/python` (the checkout env that `source ./activate` provisions), `node` 26 or newer (it runs the TypeScript mock directly) and `tmux`. If `.venv` is missing, stop and ask. Provisioning it touches the PM store and is not part of a verification run.

```bash
R=$(.agents/skills/verify-hermes/scripts/hv up)           # sandbox + mock provider
R=$(.agents/skills/verify-hermes/scripts/hv up --serve)   # the same plus `hermes serve` on a free port
```

`up` prints only the run id on stdout and returns once the run is usable.

- Sandbox: `$TMPDIR/hermes-verify-<run>/` holds `hermes-home/` (`HERMES_HOME`), `home/` (`HOME`, so `~` resolves inside the sandbox), `work/` (the cwd of every command, empty on purpose so the repo's `AGENTS.md` and project skills do not load) and `run.json`.
- Mock provider: `scripts/mock-up.mts` starts `startMockServer`, then writes `config.yaml` and `.env` with `writeMockProviderConfig` and `writeEnvFile`. The config points `model.provider: custom` at the mock, marks onboarding done, sets approvals off, and records the shared-metrics offer as declined. Without that last key the REPL opens a "Help improve Hermes?" dialog and swallows the first keystrokes. Ready is the line `HV_MOCK_READY port=N url=http://127.0.0.1:N`.
- `hermes serve` (with `--serve`, or `hv serve $R start`): `hermes serve --host 127.0.0.1 --port 0 --skip-build` with a random `HERMES_DASHBOARD_SESSION_TOKEN` and `HERMES_DESKTOP_ISOLATED_BACKEND=1`. Ready is the line `HERMES_BACKEND_READY port=N`, and `hv doctor` then confirms `/api/status` reports the sandbox home.
- REPL ready: the banner line `Welcome to Hermes Agent!` and the prompt `❯ `.
- Environment: every child gets a scrubbed copy of the caller's environment. All `HERMES_*` and `HV_*` variables, every name matching `API_KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|ACCESS_KEY|PRIVATE_KEY|BASE_URL`, provider prefixes (`OPENAI_`, `ANTHROPIC_`, `OPENROUTER_`, ...), `TERMINAL_*`, `PYTHONPATH` and `VIRTUAL_ENV` are dropped, the same rule as `stripCredentials` in `apps/desktop/e2e/fixtures.ts`. The harness then sets `HOME`, `HERMES_HOME`, `HV_RUN_ID` (the process marker), `LANG` and `TERM`.
- Verification scaffolding: the harness also sets `HERMES_DISABLE_LAZY_INSTALLS=1`. This checkout's `install-stamp.json` lags `HEAD`, so without it `hermes_cli/venv_sync.py::prepare_launch` rebuilds a Python runtime inside every fresh `HERMES_HOME` (400 MB and minutes) before the first command. The flag skips that sync. Its cost: anything that needs the PM-managed `node` or `npm` refuses to start, which is why the Ink TUI (`hermes --tui`) is out of scope here.
- Side by side: runs do not share state. Each has its own sandbox, its own tmux server (`-L hv-<run>`), its own mock port and a `--port 0` serve. Two agents can run at once. `serve` binds its own free port and sets `HERMES_DESKTOP_ISOLATED_BACKEND=1`, as the Desktop e2e fixtures do, so it is not meant to route to a machine-level backend. `hv doctor` still checks that `/api/status` reports the sandbox home.
- Never use `hermes serve --stop` or `--status`. They act on every Hermes web server process on the machine, including ones this run did not start.

## Doctor

```bash
.agents/skills/verify-hermes/scripts/hv doctor $R
```

Read-only. Run it first, and again whenever a step looks wrong. It prints one `ok` or `FAIL` line per check and exits 1 on any `FAIL`:

- the Hermes home is under the temp dir and is not the user's `~/.hermes`
- the scrubbed environment carries no credential or provider variable
- `.venv/bin/python` exists
- the mock process is ours and alive, `GET /v1/models` lists `mock-model`, and `config.yaml` points at the mock URL
- `hermes --version` runs from the sandbox and names this checkout's `HEAD` short hash
- with serve: the process is alive, and `/api/status` reports `hermes_home` equal to the sandbox home (the port is owned by this run) and a version
- with tmux: the session exists and whether its process is running or exited
- the evidence dir exists and `git check-ignore` confirms it is ignored

The version line carries `.dirty` when the tree has uncommitted changes. That is expected during development. A mismatching hash means the run is not driving the checkout you think it is.

## Drive

Three entry points, each with stable handles from the code.

One-shot CLI. `hv hermes` runs `.venv/bin/python hermes ...` in the sandbox with the scrubbed environment, saves stdout, stderr, the command and the exit code to the evidence dir, and mirrors them to your terminal. Put `--` before Hermes flags.

```bash
hv hermes $R -- -z "say hi"                    # stdout is ONLY the reply
hv hermes $R -- chat -q "say hi" -Q            # stdout: "session_id: <id>" then the reply
hv hermes $R -- sessions list
hv hermes $R -- config get model.default
hv hermes $R -- status
hv mock-prompts $R                             # what the provider actually received
```

The mock answers every turn with `Hello from the mock inference server! The full boot chain is working.` A cold `hermes` start costs 15 to 30 seconds of imports. The default timeout is 240 s (`--timeout S`).

Classic REPL. `hv tmux` drives `hermes --cli` in a dedicated tmux server (140x45) with `remain-on-exit`, so the final screen of an exited process is still capturable.

```bash
hv tmux $R start -- --cli
hv tmux $R wait 'Welcome to Hermes Agent' --timeout 120
hv tmux $R send "hello repl"                   # types the text and presses Enter
hv tmux $R wait 'Hello from the mock inference server' --timeout 90
hv tmux $R send "/version"
hv tmux $R capture after-version               # screen plus 500 lines of scrollback, saved as evidence
hv tmux $R send "/quit"
hv tmux $R wait 'Resume this session with' --timeout 30
```

Handles: prompt `❯ `, response panel header `☤ Hermes`, status bar `☤ mock-model`, slash echo `⚙️  /<command>`, help banner `Available Commands`, exit text `Resume this session with:` (after a turn) or `Goodbye!` (empty session). `wait REGEX` searches the visible screen and scrollback and succeeds once the match count reaches `--count N` (default 1). Replies are identical every turn, so on turn N wait for `--count N`. A `wait` fails fast, with the final screen, if the process exits first. Other actions: `type TEXT` (no Enter), `key KEY...` (tmux key names such as `C-c`), `stop`.

JSON-RPC gateway (needs `up --serve`). The socket is `ws://127.0.0.1:<port>/api/ws?token=<token>`. The server sends a `gateway.ready` event first. Methods are in `tui_gateway/contracts/`, events carry `params.type` and `params.session_id`.

```bash
hv chat $R "hello via rpc"                     # session.create + prompt.submit + wait for message.complete
hv rpc $R session.list '{}'
hv rpc $R session.resume '{"session_id":"<stored id>","cols":120}'
hv rpc $R commands.catalog '{}'
hv rpc $R slash.exec '{"session_id":"<runtime id>","command":"/version"}'
hv rpc $R prompt.submit '{"session_id":"<id>","text":"hi"}' --until message.complete
```

`hv chat` prints `session_id` (runtime, valid while serve runs) and `stored_session_id` (durable, what `session.resume` and `hermes sessions list` use), the submit receipt, the event types seen and the `message.complete` payload. It exits 6 unless `payload.status` is `complete`. Server-to-client requests (approvals, clarify) are not answered by this client, so keep recipes on prompts that need no tool approval.

Tool-calling turns are out of reach by default: the mock only scripts tool calls for trigger prompts defined in `tests-js/scripts/mock-server.ts`. Read it before writing a tool journey.

## Evidence

Everything lands in `test-results/verify-hermes/<run-id>/`. The root `.gitignore` ignores `test-results/` (`git check-ignore` confirms it, and `hv doctor` re-checks it), and `hv down` never deletes it. Contents:

- `steps.log`: one timestamped line per `hv` action
- `NN-hermes-*.stdout`, `.stderr`, `.cmd`: each CLI run, with its exact command, exit code and elapsed time
- `NN-rpc-*.frames.jsonl`: every JSON-RPC frame of that call, in order
- `NN-tmux-*.txt`: pane captures
- `mock.log`, `serve.log`, `hermes-logs/` (the sandbox `agent.log`, `errors.log`, `gui.log`), `run.json` (no token): copied in by `hv down`

Proof standards:

- Exercise the real user path: the CLI command, the typed REPL input, the public RPC method. Never import `hermes_state` or call an internal setter to arrange the result.
- Capture the action and the resulting state. For a turn that means the typed input or command, the visible reply, and a second view of the stored result (`hermes sessions list`, `session.list`, `mock-prompts`).
- Verify side effects alongside what is visible: the session row exists with the expected source and preview, the provider received the prompt, the config file holds the value.
- Assert the first prompt the provider receives with `startswith` or `contains`. A fresh home can append a "first message ever" system note to the first user message (seen over JSON-RPC).
- The mock is the only fake, and it sits at the production boundary (the provider HTTP endpoint). The sandbox `.env` carries an inert key, `e2e-mock-key`.
- `hermes doctor` inside the sandbox reports the mock `custom_providers` entry and a missing `~/.local/bin/hermes` symlink. Both are harness noise, not product bugs.

Report a path you could not drive with the command you tried and the unmet precondition. Do not report it as verified through a different entry point.

## Cleanup

```bash
.agents/skills/verify-hermes/scripts/hv down $R
```

Run it after every run, including failed ones. It kills the tmux server on this run's socket, the process trees of the pids the run recorded (mock, serve), and any other process whose environment carries this run's `HV_RUN_ID` marker (detached children and daemons that Hermes spawned inherit it). It copies logs into the evidence dir, then deletes the sandbox only after confirming nothing tagged is still alive. If something survives, it keeps the sandbox, names the pids and exits 7. Never kill by process name. To look for strays: `ps -wwE -axo pid=,command= | grep HV_RUN_ID=`. `hv down` on a run id that is already gone is a no-op.

## Helpers

| Command | Does |
|---|---|
| `hv up [--serve] [--run ID]` | create sandbox, start mock, optionally serve; prints run id |
| `hv down RUN` | stop everything this run started, keep evidence, delete sandbox |
| `hv doctor RUN` | read-only health check, exit 1 on any `FAIL` |
| `hv status RUN` | run state as JSON, token redacted |
| `hv path RUN evidence\|work\|hermes-home\|root` | print one of the run's directories |
| `hv hermes RUN [--timeout S] -- ARGS...` | run `hermes ARGS` in the sandbox, capture evidence |
| `hv serve RUN start\|stop\|info` | manage this run's `hermes serve` |
| `hv rpc RUN METHOD [JSON] [--until EVENT] [--timeout S]` | one JSON-RPC call, frames saved; exit 5 on an RPC error |
| `hv chat RUN TEXT [--session ID] [--timeout S]` | one real chat turn over JSON-RPC |
| `hv tmux RUN start\|send\|type\|key\|wait\|capture\|stop ...` | drive the REPL |
| `hv mock-prompts RUN` | user prompts the mock received |
| `scripts/mock-up.mts HOME [PORT]` | the mock provider process; `hv up` starts it, do not run it by hand |

`hv` re-executes itself under `.venv/bin/python` and needs no other dependency.

## Not covered

The Ink TUI (`hermes --tui`, see Launch for why), messaging gateway platforms (`hermes gateway run`), cron and kanban execution, the dashboard web UI, real model providers, and tool-calling turns beyond the mock's scripted triggers. Desktop and iOS have their own skills. For the cron scheduler's restart-safe dispatch use `verify-cron-occurrences`.

After a change in a covered area, run the affected feature recipes from `features/` and report the evidence dir. For keeping the map honest as the engine changes, the user can run `/maintain-verification-skill`.

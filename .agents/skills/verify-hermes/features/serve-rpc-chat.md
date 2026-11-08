# Serve and JSON-RPC chat

`hermes serve` runs the headless backend that Desktop, iOS and the dashboard talk to. A client connects to its WebSocket, creates a session, submits a prompt, receives streamed events and a completed reply, then lists and resumes the stored session.

## Sub-features

- `serve-ready` prints `HERMES_BACKEND_READY port=N` and answers `GET /api/status` with the sandbox home.
- `rpc-connect` opens `/api/ws` with the session token and receives a `gateway.ready` event first.
- `rpc-chat` runs `session.create` and `prompt.submit` and streams `message.start`, `message.delta` and `message.complete` with status `complete`.
- `rpc-session-list` lists the stored session with its preview and source.
- `rpc-session-resume` resumes the stored session on a new connection and returns both messages.
- `rpc-bad-method` answers an unknown method or key with a JSON-RPC error instead of dropping the socket.

## How to get to it (user POV)

- Run `hermes serve` (Desktop and remote clients start it for you).
- Connect a client to `ws://<host>:<port>/api/ws?token=<token>`. The Desktop app, the iOS Bot client and the dashboard Chat tab do this.

## Driving it with hv

Preconditions:

- `R=$(hv up --serve)` and `hv doctor $R` exit 0. Doctor shows `serve owns the sandbox home`.
- `hv serve $R info` prints a non-null `port`.

- **Ready.** Check the backend identity. Run `curl -s http://127.0.0.1:$(hv serve $R info | python3 -c "import json,sys;print(json.load(sys.stdin)['port'])")/api/status`. The JSON has `version` and `hermes_home` equal to `hv path $R hermes-home`.
- **Chat turn.** Run `hv chat $R "hello via rpc"`. Output has a `session_id=` and a `stored_session_id=`, `submit={"status": "streaming"...}`, event types including `message.start`, `message.delta` and `message.complete`, and a `complete=` payload with `"status": "complete"` and the mock reply as `text`. Exit code 0.
- **List.** Run `hv rpc $R session.list '{}'`. One session has `preview` `hello via rpc`, `message_count` 2 and `source` `hv`.
- **Provider receipt.** Run `hv mock-prompts $R`. An entry starts with `hello via rpc`.
- **Resume.** Take `stored_session_id` from the chat output and run `hv rpc $R session.resume '{"session_id":"<stored id>","cols":120}'`. The result has `resumed` equal to that id, `message_count` 2, and `messages` with the user text then the mock reply.
- **Error path.** Run `hv rpc $R no.such.method '{}'`. Exit code 5 and the printed result is an `error` object with a numeric `code`, and a follow-up `hv rpc $R session.list '{}'` still succeeds.
- **Proof.** The `*-rpc-*.frames.jsonl` files under `hv path $R evidence` hold every frame. `serve.log` (copied by `hv down`) holds the readiness line.

## Gotchas

- `session_id` is a runtime id that dies with the serve process. `stored_session_id` is the durable id for `session.resume` and for `hermes sessions list`.
- `session.list` is a human-facing window over the sessions the gateway owns. Sessions made by `hermes -z` or the REPL show in `hermes sessions list`, and may not show in `session.list`. Cross-check each surface with its own command.
- `hv rpc` and `hv chat` send no `client.capabilities`, so the server cannot ask them approvals or clarifying questions. Keep the prompt simple and the mock's reply canned.
- Each `hv rpc` call is its own WebSocket connection. State that must live on one connection needs a longer script than `hv` offers.
- Parameter keys are strict. An unknown key returns error `4000` with the key path. Copy params from `tui_gateway/contracts/`.
- Do not run `hermes serve --stop` or `--status` to check the server. They act on every Hermes backend on the machine. Use `hv serve $R info` and `hv doctor $R`.
- The token is in `run.json` in the sandbox only. `hv status` and the copied evidence redact it.

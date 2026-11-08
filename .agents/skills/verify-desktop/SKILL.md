---
name: verify-desktop
description: Drive the real Hermes Desktop Electron app (apps/desktop) end to end against an isolated backend and a fake LLM, and capture proof. Use after any change a desktop user can see or feel (renderer UI, Bot Mode, chat, onboarding, Electron main/preload, the gateway leg the app uses), before reporting the change done.
---

# verify-desktop

Hermes Desktop is an Electron shell (`apps/desktop`) that spawns a local Hermes gateway from this checkout and renders chat, Bot Mode and settings. This skill launches it the way the repo's own Playwright suite does: a disposable `HERMES_HOME` and Electron user-data dir per run, the backend from the checkout's `.venv`, and the mock inference server in `tests-js/scripts/mock-server.ts` in place of a real model. Nothing touches `~/.hermes` or a real provider.

All paths below are relative to the repo root.

## Doctor

Run this first, and again whenever a run looks wrong:

```bash
.agents/skills/verify-desktop/scripts/doctor
```

It is read-only. It checks node >= 26, `@playwright/test` and the Electron binary at the repo root, that `.venv/bin/python` imports `hermes_cli`, whether `apps/desktop/dist` is older than `src/` or `electron/`, the machine load average, and leftover processes from earlier verify runs. Any `FAIL` blocks a run. A `warn` on load means every step runs slower, so expect long provisioning.

## Launch, drive, evidence, cleanup in one command

```bash
.agents/skills/verify-desktop/scripts/verify bot-avatar-gaze
.agents/skills/verify-desktop/scripts/verify chat
STARTUP_WARM_RUNS=4 .agents/skills/verify-desktop/scripts/verify startup-timing
.agents/skills/verify-desktop/scripts/verify --no-build bot-avatar-gaze
.agents/skills/verify-desktop/scripts/verify --help
```

`scripts/verify [--no-build] [journey ...]` does, in order:

1. Creates the evidence dir `apps/desktop/test-results/verify-desktop/<UTC stamp>-<pid>/` (gitignored) and records the commit and dirty-file count in `run.txt`.
2. Runs `npm run build` in `apps/desktop` (log in `build.log`) unless `--no-build`. Use `--no-build` only when doctor says `dist/` is newer than the sources, because the journeys load `dist/`, not the Vite dev server.
3. Runs the named journeys from `journeys/` through `playwright.config.ts` in this skill. Each journey launches its own Electron app through `apps/desktop/e2e/fixtures.ts` (`createSandbox`, `buildAppEnv`, `launchDesktop`, `waitForAppReady`), which strips inherited `HERMES_*` and credential variables, sets `HERMES_HOME`, `HERMES_DESKTOP_USER_DATA_DIR`, `HERMES_DESKTOP_ISOLATED_BACKEND=1` and a unique app name, so runs never share state with the user's app or each other.
4. Runs `scripts/cleanup <run-id>` and appends its result and the exit code to `run.txt`.

Every journey provisions its sandbox home before it launches the app: `journeys/provision.ts` `provisionHome(env, home)` runs `hermes gateway ensure --json --timeout 900` against that home, waits for `"state":"ready"`, then runs `hermes gateway stop`. This is required, not an optimization. A fresh `HERMES_HOME` makes PM build that home's runtime under `<home>/installs/` first, which takes 70 s on an idle machine and several minutes under load. Electron gives `gateway ensure` only 75 s (`apps/desktop/electron/local-gateway.ts`, `GATEWAY_ENSURE_PROTOCOL_DEADLINE_MS` + grace), kills it, reclaims the half-built install and starts over, so an unprovisioned sandbox sits on `CONNECTING` forever. The repo's own `apps/desktop/e2e` specs hit the same wall on this machine. After provisioning, the app still starts the gateway itself, so the desktop's own start path stays covered.

Ready means usable: `waitForAppReady` waits until the chat composer accepts a click, not only until a window exists. A run that still stays on `CONNECTING` fails there with a screenshot. The main-process log (`Error occurred in handler for 'hermes:api': Error: hermes gateway ensure timed out`) is not saved by default. To get it, attach `app.process().stdout` and `stderr` to a file in the journey, and copy `<home>/logs/desktop.log` before cleanup.

Every process a run starts carries `HERMES_E2E_VERIFY_RUN=<run-id>` in its environment (the fixtures pass `HERMES_E2E_*` through to Electron and the backend). That marker is how cleanup finds exactly this run's processes.

## Journeys

| Journey | Proves | Feature file |
|---|---|---|
| `bot-avatar-gaze` | Roster avatar eyes follow the pointer on a sphere and restore their baked pose on leave | `features/bot-avatar-gaze.md` |
| `bot-avatar-loading` | A working roster avatar plays the shared eye clips on blob, math and sigil faces, changes clips, settles back to the static render, and white bots are drawn dark on the light theme | `features/bot-avatar-loading.md` |
| `bot-chat-internals` | Bot chat shows product language only: the approval card reads "Needs your OK" with the command behind Show details / Hide details, tool turns (including a failed call) render no tool rows or command text, and a regular chat approval still shows the Command header and raw command | `features/bot-roster.md` |
| `chat` | A typed prompt reaches the mock model and the reply renders | `features/chat.md` |
| `startup-timing` | Cold and warm launch timings to a usable composer (`STARTUP_WARM_RUNS`, default 3), with desktop.log boot phases, the frame the composer first accepts a click, and copied gateway logs in `startup-timing/timings.json` | `features/chat.md` |

A new journey is a `journeys/<feature>.spec.ts` that imports the fixtures from `apps/desktop/e2e/` with `../../../../apps/desktop/e2e/...` paths, calls `provisionHome` on its sandbox before `launchDesktop` (never `setupMockBackend`, which launches without provisioning), uses `test`/`expect` from `apps/desktop/e2e/test` (it fails a test on any error banner), writes evidence under `process.env.VERIFY_RUN_DIR`, and closes its app in `afterAll`. The skill's `package.json` marks the directory as ESM. Playwright needs that to load the repo's TypeScript helpers.

## Drive conventions

- Use stable handles from the code: `data-slot`, `data-roster-key`, `data-bot-face`, `data-hb-*`, ARIA roles and names. Never coordinates alone, never tab order.
- The Playwright config used by `apps/desktop/e2e` forces `prefers-reduced-motion: reduce`. This skill's config does not, but journeys that need motion call `page.emulateMedia({ reducedMotion: 'no-preference' })` explicitly, because motion features (bot gaze, blinks) switch themselves off under reduced motion.
- Seed state through the real backend: `writeMockProviderConfig`, `writeEnvFile`, and `RealSessionBuilder` (see `journeys/bot-avatar-gaze.spec.ts` `seedBot`). Never set renderer stores directly.

## Evidence

Each run leaves `apps/desktop/test-results/verify-desktop/<run-id>/` with:

- `run.txt`: run id, commit, dirty-file count, journeys, cleanup output, exit code.
- `build.log`, `playwright.log`, `results.json`.
- `playwright/<test>/trace.zip` (open with `npx playwright show-trace <path>` from `apps/desktop`) and a final screenshot per test.
- One folder per journey with the action-by-action proof it captured (screenshots before and after each action, serialized DOM state, JSON of the asserted values).

Proof standards: drive the real user path (pointer, click, keyboard) in the real Electron app, capture the state before and after each action, and check side effects in a second view (the mock's received prompts, the backend's stored session) when the feature has them. The mock inference server is the only stand-in, and it sits behind the provider boundary the product already isolates.

## Cleanup

`scripts/verify` cleans up after itself. To clean a run that was killed:

```bash
.agents/skills/verify-desktop/scripts/cleanup <run-id>
.agents/skills/verify-desktop/scripts/cleanup
```

It sends TERM, then KILL after 15 s, only to processes whose environment carries `HERMES_E2E_VERIFY_RUN=<run-id>` (with no argument, any verify run), skipping its own ancestors. It never kills by process name and never touches evidence. Sandbox homes live under the Playwright run's temp root, which `apps/desktop/e2e/run-tmp.ts` deletes on exit (and the next run reaps if a run was killed). Delete old evidence folders by hand when they are no longer needed.

## Helpers

- `scripts/doctor`: read-only health check, exits 1 on any `FAIL`.
- `scripts/verify [--no-build] [journey ...]`: build, run journeys, clean up, print the evidence dir. Exit code is Playwright's.
- `scripts/cleanup [run-id]`: stop processes left by a verify run.
- `journeys/provision.ts`: `provisionHome(env, home)` builds a sandbox home's runtime and stops its gateway again.
- `playwright.config.ts`: refuses to run without `VERIFY_RUN_DIR`, so always go through `scripts/verify`. Allows 20 minutes per test because provisioning dominates.

## Feature map

`features/README.md` indexes every mapped user-facing feature with how to reach it, how to drive it, and what proves it. A change verifies every entry point its feature file lists, not just the convenient one.

---
name: verify-ios
description: Drive and prove the Hermes Bots iOS app (apps/ios, native Bot Mode client, bundle dev.tsnanh.hermes.bot) on an iOS Simulator against an isolated local Hermes gateway with a fake LLM. Use after any change under apps/ios (App/, Packages/HermesKit, Packages/HermesDesign, UITests/) to sign in, list bots, chat, and check avatars with real XCUITest runs, video, screenshots, and logs.
---

# verify-ios

The app is a thin client: with no gateway it only shows the sign-in form. So every run starts a sandbox gateway (temp `HERMES_HOME`, two bot profiles `bot-alpha` and `bot-beta`, auth enabled) whose model is a local fake LLM. No real model is ever called. Read `features/README.md`, then the feature file you are proving.

Everything below runs from the repo root. Helpers live in `.agents/skills/verify-ios/scripts/` (call them as `S=.agents/skills/verify-ios/scripts; $S/launch`).

## Rules this skill enforces

- Never touch `~/.hermes`. The gateway runs with `HERMES_HOME=/tmp/hermes-ios-e2e.*/home` (a `config.yaml` there makes it the profile root, so `bot-alpha` and `bot-beta` are created inside it). `HOME` stays real because `simctl` and `xcodebuild` need it. Doctor asserts `~/.hermes/profiles/bot-alpha` and `bot-beta` do not exist, and `cleanup` fails if the listing of `~/.hermes/profiles` differs from the baseline. <!-- no-tmp: ok — names the sandbox path apps/ios/Scripts/e2e-gateway creates and doctor and push-on-ready require under /tmp -->
- Credentials and inherited `HERMES_*` runtime vars are stripped from every child env (same rules as `apps/desktop/e2e/fixtures.ts` `stripCredentials`).
- One run at a time per checkout. State is keyed by the checkout path, so agents in different worktrees run in parallel (ports are free-picked, simulators are slot-gated and ledger-claimed per owner). `launch` refuses to start while this checkout's run is active. Do not drive an instance you did not start.
- Simulator rules (machine-wide, from the user's global rules): at most 4 simulators run on this machine across all sessions (`CLAUDE_MAX_DEVICES`, shared with the resource gate hook). `sim-up` waits for a free slot (`VERIFY_IOS_SLOT_WAIT_SECONDS`, default 900) and never boots past the cap. It reuses an existing simulator, never creates or erases one, never claims one booted by someone else, claims the one it boots in the device ledger (`VERIFY_IOS_OWNER`, default `verify-ios`), and never opens Simulator.app. Never touch physical devices.
- Do not put the literal command `xcrun simctl boot` in your own Bash calls: the resource gate hook pattern-matches it. Boot only through `scripts/sim-up`.

## Launch

```
S=.agents/skills/verify-ios/scripts
VERIFY_IOS_OWNER=<your-task-slug> $S/launch
```

`launch` runs, in order, and runs `cleanup` itself if any step fails:

1. `baseline`. Saves `xcrun simctl list devices`, `du -sh` of `~/Library/Developer/CoreSimulator/Devices` and `~/Library/Developer/XCTestDevices`, the ledger, and the XCTestDevices clone list under the run's evidence dir. Picks the simulator: one you already own in the ledger, else `VERIFY_IOS_UDID`, else a shutdown iPhone (prefers "iPhone 17" on the newest runtime).
2. `backend-up`. Starts `apps/ios/Scripts/e2e-gateway` (stub LLM from `apps/ios/Tools/stub-llm/stub_llm.py` plus an auth-gated `hermes gateway run`) in a credential-stripped env. The first start of a fresh `HERMES_HOME` provisions an isolated runtime (Python and Node dependencies, a desktop build) and takes several minutes; `VERIFY_IOS_BACKEND_READY_SECONDS` (default 1200) bounds the wait. Ready means the script printed its `export HERMES_IOS_TEST_*` lines (it prints them only after `/api/auth/providers` answers), the fake LLM answers `/v1/models`, and both profile configs exist. Sandbox credentials (random per run) go to `$STATE_ROOT/backend.env`, mode 600.
3. `build`. `xcodegen generate` (the `.xcodeproj` is generated and gitignored) then `xcodebuild build-for-testing` into `apps/ios/build/DerivedData`.
4. `sim-up`. Waits for a slot, boots, `bootstatus`, claims the device in `~/.claude/hooks/device-ledger.sh`, records whether the app was already installed.
5. `doctor`.

Why the in-repo fake LLM and not `tests-js/scripts/mock-server.ts`: the iOS harness already ships a stub that speaks what the app's tests need (streaming, a `clarify` tool call on the prompt `CLARIFY`, a slow stream on `SLOW`, and a request log). The desktop mock server does not. The pairing is the real product path, see Drive.

State for the run lives in `/tmp/verify-ios-state-<uid>/<checkout-hash>/` (`run.env`, `backend.env`, `last-failed`). Evidence goes to `apps/ios/Artifacts/verify-ios/<run-id>/`, which is gitignored by `apps/ios/.gitignore` (`Artifacts/`) and survives cleanup. <!-- no-tmp: ok — names the state root common.sh creates under /tmp -->

## Doctor

```
$S/doctor
```

Read-only. Answers "is this instance worth driving": backend wrapper alive and is `e2e-gateway`, port owned by our gateway process, `/api/auth/providers` and the fake LLM answer, `HERMES_HOME` is under `/tmp` and points at the fake LLM, both profiles exist, real `~/.hermes` has no `bot-*` profile, simulator booted and claimed by this owner, machine simulator count within the cap, built app newer than every Swift source (stale build means rerun `$S/build`), `.xctestrun` present, evidence dir gitignored. Exits 1 with a `FAIL` line per problem. Run it first whenever anything looks off. <!-- no-tmp: ok — describes doctor's /tmp sandbox guard -->

## Drive

Pairing needs no human. The app signs in through `ASWebAuthenticationSession` against the gateway's basic-auth login page. The UI tests type the base URL into `baseURLField`, tap `signInButton`, accept the system consent alert (SpringBoard "Continue"), fill the web form with the sandbox username and password from env, and wait for `rosterScreen`. Passing `-hermes-reset-credentials` as a launch argument clears the keychain first.

Primary driver is XCUITest, because the app exposes accessibility identifiers and the shipped suite in `apps/ios/UITests/` already scripts sign-in and chat:

```
$S/drive BotChatE2ETests/test2SendStreamsReply
$S/drive SignInFlowTests
$S/drive --label roster BotChatE2ETests/test1RosterShowsBothBots
```

`drive` runs `xcodebuild test-without-building` on the claimed simulator with `TEST_RUNNER_HERMES_UITEST_{BASE_URL,USERNAME,PASSWORD,SHOTS}` pointing at the launched backend, records `simctl io recordVideo`, and exits 0 only if the xcresult summary shows at least one pass, no failure, and no skip (a skipped test is not a proof). Tests needing the control channel (kill and restart the gateway, external turns):

```
$S/drive-control RosterLiveE2ETests/test1ExternalTurnShowsWorkingThenIdleWithNewPreview
$S/drive-control BotChatE2ETests/test5OfflineSendDeliversOnce
```

`drive-control` delegates to `apps/ios/Scripts/run-ui-e2e`, which starts its own sandbox gateway (env stripped, `/tmp` `HERMES_HOME`; it pays the same multi-minute provisioning cost) and reuses the simulator you launched. It does not boot or claim anything. <!-- no-tmp: ok — names the sandbox path run-ui-e2e and e2e-gateway create under /tmp -->

`drive` refuses, before touching the simulator, any selected test that calls `control(...)` or reads `HERMES_UITEST_CTL` (classified by `scripts/test-lanes`), and prints the exact `drive-control` and `drive` commands to run instead. Such a test failing with "HERMES_UITEST_CTL not set" was never a product failure, so never build the base branch to prove it pre-existing.

### Iterating

Simulator slots are shared machine-wide, so a run costs every other agent time.

- While fixing, rerun only what failed: `$S/drive --rerun-failed` reads the failures the previous `drive` recorded. Add a test only when your edit touched the code it covers.
- Run the unit's full UI suite once, after the last fix. Do not rerun the whole suite after each fix.
- Run the cross-unit regression (other features' suites) once, at the end, not per iteration. When the coordinator integrates branches it runs it again on the combined tree.
- Rebuild (`$S/build`) only after Swift edits; `doctor` reports a stale build.

Host-only package tests (no simulator, no backend needed):

```
$S/swift-test HermesDesign                        # avatar parity and motion
$S/swift-test HermesDesign --filter AvatarMotionTests
```

Ad hoc evidence between drives:

```
$S/snap roster-after-signin     # simctl io screenshot of the claimed simulator
$S/logs 5m                      # app os_log (subsystem dev.tsnanh.hermes.bot)
```

Stable handles from the code (`apps/ios/App/`): `baseURLField`, `signInButton`, `signOutButton`, `statusLabel`, `instanceIDLabel`, `errorLabel`, `rosterScreen`, `botRow-<profile>` (value is the activity: `idle`, `working`, `needs-input`, `offline`), `rosterSearchField`, `userAvatarButton` (value `Connected` when the live link is up), `chatScreen`, `chatTitle`, `composerField`, `sendButton`, `userBubble`, `assistantBubble`, `assistantBubble-streaming`, `clarifyCard`, `clarifyChoice-<n>`, `deliveryQueued`, `deliveryFailed`, `reconnectingIndicator`, `reach-offer-banner`. To drive something the shipped tests do not cover, add a test to `apps/ios/UITests/` using `E2ETestCase` helpers in `E2ESupport.swift`; do not tap by coordinates.

## Evidence

Per run, under `apps/ios/Artifacts/verify-ios/<run-id>/`:

- `baseline/` device list before, after start, after cleanup; disk before; ledger; XCTestDevices clones.
- `drive-<time>-<label>/` `run.mov`, `shots/*.png` (written by the tests' `shot()`), `result.xcresult`, `result-summary.json`, `xcodebuild-test.log`, `app-os-log.txt`, `gateway.log`, `fake-llm-requests.jsonl`, `sandbox-db-messages.txt`, `verdict.txt`.
- `cleanup-report.txt` what was uninstalled, shut down, removed, plus disk after.

Proof standards:

- Exercise the real user path: real sign-in through the web auth session, real taps and typing. No test-only endpoints, no setters.
- Capture the action and the state it caused, not only the last screen: the video plus at least one screenshot before and one after.
- Verify side effects outside the UI. A chat proof also shows the fake LLM received the user text (`fake-llm-requests.jsonl`) and the sandbox DB holds the messages (`sandbox-db-messages.txt`).
- The fake LLM is the only mock, at the model boundary the gateway already isolates. The gateway, the transport, the auth flow and the app are real.
- A verdict of `PASS` in `verdict.txt` is required. Read at least one screenshot yourself before claiming a visual result.
- Text artifacts have the sandbox password redacted. The xcresult can contain the typed throwaway password; it is valid only for the sandbox gateway that cleanup destroys. Do not paste xcresult contents into reports.

## Cleanup

```
$S/cleanup
```

Run it after every drive session, pass or fail, and after any failed attempt. It only touches what this run started: uninstalls the app and `dev.tsnanh.hermes.bot.uitests.xctrunner` unless they were installed beforehand; runs `device-ledger.sh cleanup --owner <owner>` (shuts down only the simulator this run claimed); stops the gateway wrapper, gateway and fake LLM by recorded pid (never by process name) and verifies the port is free; verifies `~/.hermes/profiles` is unchanged; removes XCTestDevices clones created during the run only when no other `xcodebuild` is running; prints disk against baseline. It never deletes baseline simulators and never deletes evidence. If it exits 1, fix the named problem and rerun. Simulator.app is never opened by this skill; if you opened it for a visual check and nothing else is booted, quit it with `osascript -e 'quit app "Simulator"'`.

## Helpers

| Script | Invocation | Purpose |
|---|---|---|
| `launch` | `$S/launch` | baseline, backend, build, simulator, doctor |
| `baseline` | `$S/baseline` | record baseline, choose simulator (called by launch) |
| `backend-up` | `$S/backend-up` | sandbox gateway plus fake LLM (called by launch) |
| `build` | `$S/build` | xcodegen plus build-for-testing; rerun after source edits |
| `sim-up` | `$S/sim-up` | slot-gated boot and ledger claim (called by launch) |
| `doctor` | `$S/doctor` | read-only health check |
| `drive` | `$S/drive [--label X] [--no-video] Class[/test]... \| --rerun-failed` | XCUITest against the launched backend; refuses control tests |
| `test-lanes` | `$S/test-lanes apps/ios/UITests Class[/test]...` | which selected tests need `drive-control` |
| `drive-control` | `$S/drive-control Class/test` | XCUITest that needs gateway kill, external turns |
| `swift-test` | `$S/swift-test <HermesDesign\|HermesKit> [args]` | host package tests |
| `snap` | `$S/snap <name>` | simulator screenshot |
| `logs` | `$S/logs [window]` | app os_log extract |
| `cleanup` | `$S/cleanup` | teardown, never evidence |

Env knobs: `VERIFY_IOS_OWNER`, `VERIFY_IOS_UDID`, `VERIFY_IOS_SLOT_WAIT_SECONDS`, `VERIFY_IOS_BACKEND_READY_SECONDS`, `HERMES_IOS_PYTHON` (default `<repo>/.venv/bin/python`).

## Rules and what enforces them

| Rule | Enforced by |
|---|---|
| Control-channel tests run only under `drive-control` | `drive` refuses them via `test-lanes` (exit 2, prints the commands) |
| Iterate on failures, not the whole suite | `drive --rerun-failed` is the shortest path; the full-suite-once rule is judgment, this section only |
| At most 4 simulators machine-wide (`CLAUDE_MAX_DEVICES`) | `sim-up` slot wait plus `~/.claude/hooks/resource-gate.sh` |
| Never touch `~/.hermes` | `doctor` and `cleanup` compare `~/.hermes/profiles` to the baseline |
| A simulator taken by another agent between baseline and boot is replaced, never fought over | `sim-up` re-picks a shutdown iPhone (unless `VERIFY_IOS_UDID` pins one) |
| Parallel agents never share run state | `common.sh` keys `STATE_ROOT` by checkout path |
| Never boot a simulator directly | resource gate hook matches the raw boot command |

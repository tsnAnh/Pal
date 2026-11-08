# Hermes Bots iOS verification map

This directory is the maintained source for verifying user-facing behavior of the Hermes Bots iOS app (`apps/ios`, bundle `dev.tsnanh.hermes.bot`). Read the index, then drive the matching feature file.

## Baseline preconditions

- Run `.agents/skills/verify-ios/scripts/launch` (shell variable `S=.agents/skills/verify-ios/scripts` below). It starts a sandbox gateway with auth enabled, two bot profiles `bot-alpha` and `bot-beta`, a fake LLM, and one claimed simulator.
- Run `$S/doctor` and require every line `PASS`.
- Never drive a backend or simulator this run did not start. Never touch `~/.hermes`.
- A run is single-tenant per user. If `launch` reports an active run, finish or `cleanup` it first.

## Driving conventions

- Tests are XCUITest classes in `apps/ios/UITests/`. Name a test as `Class/testMethod` after `$S/drive` or `$S/drive-control`.
- Use `drive` for tests that only need the launched backend. Use `drive-control` for tests that kill and restart the gateway or inject external turns.
- Prefer accessibility identifiers (`baseURLField`, `botRow-bot-alpha`, `composerField`) over labels or coordinates.
- Several tests sign in on their own (`signInIfNeeded`), so any one can run alone, but state set by earlier tests (relaunch, history) is not assumed.
- Fake LLM prompts: any text streams `stub-NN` words, text containing `CLARIFY` produces a clarify question with choices `vanilla` and `chocolate`, text containing `SLOW` streams `slow-NN` words slowly.

## Proof and skip reporting

- A proof needs `verdict=PASS` in `verdict.txt`, with video, screenshots, `fake-llm-requests.jsonl` and `sandbox-db-messages.txt` from the drive's evidence dir.
- A test that the harness reports as skipped is a failure of the proof, not a pass.
- Report an unreachable sub-feature with the command tried and the unmet precondition. Do not claim it verified through a different path.
- Record the feature ID with every artifact (use `--label <feature-id>`).

## Feature entry contract

Each feature file starts with an H1 title and one paragraph. It then uses exactly four H2 sections in this order: `Sub-features`, `How to get to it (user POV)`, `Driving it with verify-ios`, `Gotchas`.

## Features

- [Connect to a gateway](./connect-gateway.md) covers sign-in through the web auth session, connected status, instance ID, and sign-out.
- [Bot roster](./bot-roster.md) covers the bot list, search, live activity state, and offline and recovery behavior.
- [Bot chat turn](./bot-chat.md) covers sending, streaming replies, clarify questions, relaunch mid-stream, offline queueing, large text, and reopening a long chat.
- [Bot avatar](./bot-avatar.md) covers avatar rendering and mood motion in the roster and chat header, and the host-side parity suite.

## Not mapped

- Reach presence offers (`reach-offer-banner`, `PresenceE2ETests`, `PresenceCrossClientE2ETests`) need the real Desktop app running against the same gateway. Run `apps/ios/Scripts/e2e-presence` directly; this skill does not drive it.
- TestFlight upload (`apps/ios/Scripts/testflight`) is release tooling, not app behavior.

# Hermes Desktop verification map

This directory is the maintained source for verifying what a Hermes Desktop user can see and do. Read this index, then use the matching feature file as the recipe.

## Baseline preconditions

- `scripts/doctor` reports no `FAIL`.
- Every run goes through `scripts/verify`, which builds `apps/desktop/dist`, launches Electron with a disposable `HERMES_HOME` and user-data dir, and points the provider at the mock inference server.
- Never drive the user's own Hermes Desktop or a gateway this run did not start.

## Driving conventions

- Each journey provisions its sandbox home (`journeys/provision.ts`), launches its own app from `apps/desktop/e2e/fixtures.ts`, and waits for `waitForAppReady`, meaning the chat composer accepts a click.
- Prefer ARIA roles and names, then `data-slot`, `data-roster-key` and `data-hb-*` attributes. Never rely on coordinates alone.
- Seed bots, sessions and providers through the real backend (`writeMockProviderConfig`, `writeEnvFile`, `RealSessionBuilder`).
- Motion features need `page.emulateMedia({ reducedMotion: 'no-preference' })`.

## Proof and skip reporting

- Capture the state before and after each user action, not only the final screen.
- Record serialized DOM state or JSON for any value a screenshot cannot show precisely.
- Confirm side effects from a second view: the mock's received prompts (`readMockPrompts`) or the stored session.
- Report an entry point you could not reach with the attempted step and the unmet precondition. Do not count it as verified through another path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior, then exactly four H2 sections in order: `Sub-features`, `How to get to it (user POV)`, `Driving it with Playwright Electron`, `Gotchas`.

## Features

- [Chat](./chat.md) covers sending a message, the mock reply rendering, and the busy-turn composer states.
- [Bot roster](./bot-roster.md) covers the Bots tab, opening a bot chat, roster previews, and pinning.
- [Bot avatar gaze](./bot-avatar-gaze.md) covers roster avatar eyes following the pointer on a sphere and resting again.
- [Bot avatar loading](./bot-avatar-loading.md) covers the eye clips a working bot plays, the settle back to idle, and the white bot tone on the light theme.
- [Onboarding](./onboarding.md) covers the first-run provider setup shown when no provider is configured.

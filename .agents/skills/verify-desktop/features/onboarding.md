# Onboarding

On a first launch with no model provider configured, the app shows a setup overlay that asks the user to choose a provider, enter an API key or sign in, instead of the chat composer.

## Sub-features

- `onboarding-shown` the overlay appears on first boot with no provider.
- `onboarding-choose` the overlay offers provider choices and key or sign-in entry.

## How to get to it (user POV)

- Launch the app with an empty Hermes home.

## Driving it with Playwright Electron

Preconditions:

- `setupNoProvider()` launched the app with an empty config.

- **First boot.** `waitForOnboarding(page, 90_000)` returns once `#root` text shows `provider`, `Choose`, `API key` or `Sign in`.
- **Proof.** No dedicated journey yet. `apps/desktop/e2e/onboarding.spec.ts` is the maintained recipe. A journey here should screenshot the overlay into `VERIFY_RUN_DIR/onboarding/` and assert that the composer is absent.

## Gotchas

- `waitForOnboarding` matches loose text, so pair it with a screenshot before calling the overlay correct.
- Never point onboarding at a real provider. Choosing one would ask for real credentials.
- `setupNoProvider` launches without provisioning. A journey here must create the sandbox, run `provisionHome`, then `launchDesktop`, or it never leaves `CONNECTING`.

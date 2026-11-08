# Chat

A user types a message in the composer, presses Enter, and sees the assistant's reply stream into the transcript. While a turn runs, the send button becomes Stop and a second message can steer or queue.

## Sub-features

- `chat-send` a typed prompt is sent and appears as the user's message.
- `chat-reply` the model's reply renders in the transcript.
- `chat-busy` while a turn runs, the primary button reads `Stop` and `Queue message` is offered.
- `chat-new-session` `New session` starts an empty conversation.

## How to get to it (user POV)

- The composer on the main chat screen after boot.
- `New session` in the sidebar, then the composer.

## Driving it with Playwright Electron

Preconditions:

- The sandbox home has the mock provider config, `provisionHome` ran on it, `launchDesktop` started the app, and `waitForAppReady(fixture, 240_000)` returned.

- **Send.** `runDesktopChatSmoke(page, { mockUrl, phase: 'installed', outDir })` from `tests-js/scripts/desktop-chat-smoke.ts` clicks the composer (`[data-slot="composer-root"] [contenteditable="true"]`), types a checkpoint prompt and presses Enter. The mock's `/__e2e__/prompts` endpoint must then list that prompt.
- **Reply.** The same helper waits for the mock reply text in `[data-slot="aui_thread-viewport"]` and for the composer's `Send` (or `Start voice conversation`) button to return.
- **Busy states.** Start the mock with `holdFirstStreamForPrompt`, send that prompt, and `fixture.mock.waitForHeldStream()`. `[data-slot="composer-root"] button[type="submit"]` has `aria-label="Stop"`. Release with `fixture.mock.releaseHeldStream()`. The repo's `apps/desktop/e2e/chat.spec.ts` drives this end to end.
- **Proof.** Run `scripts/verify chat`. Evidence folder `chat/` holds the helper's screenshots and transcript dump. Its assertions on the mock's received prompts are the side-effect check.

## Gotchas

- The composer also renders an `aria-hidden` sr-only textarea. Never target bare `textarea`.
- Apps prettify the model id, so `mock-model` shows as `Mock Model`.
- A boot that stays on `CONNECTING` fails before the first send. An unprovisioned home is the usual cause. See the provisioning note in `SKILL.md`.

# Bot roster

Bot Mode lists every bot (Hermes profile) as a roster row with its face, name and a preview of the last message. Clicking a row opens that bot's chat. A row's context menu can pin the bot into a strip of tiles above the list.

## Sub-features

- `roster-list` seeded bots appear as rows with face, name and preview line.
- `roster-open` clicking a row opens the bot chat with its history.
- `roster-pin` `Pin to top` moves the bot from the list into the pinned strip.
- `roster-reply-chrome` replies show the bot's name and a 20 px face above a card.
- `chat-internals-hidden` bot chat never shows tool rows, command text or technical approval wording; the approval card reads `Needs your OK` and keeps the command behind `Show details`.

## How to get to it (user POV)

- The `Bots` button or tab in the app chrome.
- Right-click a roster row for its context menu.

## Driving it with Playwright Electron

Preconditions:

- Bot profiles seeded under `<HERMES_HOME>/profiles/<name>` with `writeMockProviderConfig`, `writeEnvFile` and one `RealSessionBuilder` session each.

- **Open roster.** Click `Bots`. `[data-slot="bots-roster"] [data-roster-key="local::<name>"]` is visible per bot.
- **Open chat.** Click the row. The seeded turn text (`Hello <name>`) is visible in the transcript, and the row's text gains a second preview line.
- **Pin.** Right-click the row and choose menu item `Pin to top`. `[data-slot="bots-pinned-strip"] [data-roster-key="local::<name>"]` appears and the visible row count for that key is 1.
- **Reply chrome.** `[data-slot="bot-reply-name"]` reads the bot name and `[data-slot="bot-reply-avatar"]` is 20 px wide.
- **Internals hidden.** In a bot chat with `approvals: mode: "manual"`, send `APPROVAL_COMMAND_TRIGGER`. `[data-slot="tool-approval-card"]` reads `Needs your OK`, `APPROVAL_COMMAND` is absent from the surface, `Show details` (`aria-expanded`) reveals it and `Hide details` hides it. A `E2E_CALL(terminal)` turn, including a failing `ls`, leaves `[data-slot="tool-block"]` at 0 and no command text inside `[data-slot="aui_response-group"]`. A regular chat keeps the `Command` header and a raw `pre`.
- **Proof for roster rows and pinning.** No dedicated journey yet. `apps/desktop/e2e/grok-bot-layout.spec.ts` is the maintained recipe for this whole feature. Copy its setup into `journeys/bot-roster.spec.ts` and save screenshots under `VERIFY_RUN_DIR`.
- **Proof for internals hidden.** `journeys/bot-chat-internals.spec.ts` (`verify bot-chat-internals`) drives all three cases and writes `a-approval.json`, `b-tool-turn.json`, `c-regular.json` plus before and after screenshots.

## Gotchas

- A freshly opened bot can show `Waking up` for a while. Wait for it to hide before measuring layout.
- The roster key is `local::<profile>` for local bots. Remote bots use a different prefix.
- The grok spec's setup launches without provisioning. Call `provisionHome` on the sandbox home before `seedBot` and `launchDesktop` when you port it.

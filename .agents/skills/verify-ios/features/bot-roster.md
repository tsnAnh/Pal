# Bot roster

After sign-in the user sees their bots on the home screen: pinned bots as a row of avatars at the top, the rest as rows with avatar, name, last-message preview, timestamp and a live activity state, and a collapsed `Hidden Bots` section. A search launcher at the bottom opens a search screen for bots and messages. The roster goes offline when the gateway is lost and recovers on its own.

## Sub-features

- `roster-list` shows one row per bot profile with name and preview, and pinned bots as a hero row of avatars.
- `roster-search` opens the bottom search launcher into a search screen that lists matching bots and messages, and returns to the roster when closed. There is no inline filter of the rows.
- `roster-live-activity` shows `working`, `needs-input` and `idle` as another client runs a turn.
- `roster-offline` shows every bot `offline` when the gateway is lost and `idle` again after it returns, with no user action.
- `roster-pin` pins and unpins a bot from its context menu, moving it to or from the hero avatars.
- `roster-primary` marks one bot as the primary bot with a star; `Make Primary` moves the star.
- `roster-context-menu` offers Pin, Mark as Unread, Rename Bot, Copy conversation ID, Hide, Make Primary, View Profile and Share as Template.
- `roster-hidden` hides a bot into the collapsed `Hidden Bots` section and shows it again. No shipped UI test.
- `roster-unread` marks a bot unread or read from the context menu. No shipped UI test.
- `roster-attention` shows the `attention` state when a bot's setup is incomplete (`BotActivity.attention`). No shipped UI test.
- `roster-parity-seed` shows eight seeded bots with their previews. Needs the parity seed.

## How to get to it (user POV)

- Sign in. The roster is the first screen.
- Tap `Search` at the bottom of the roster to open the search screen and type a name or a message.
- Long-press a bot row or hero avatar for its context menu.
- Watch the roster while another client (the Desktop app or a CLI client) runs a turn on a bot.

## Driving it with verify-ios

Preconditions:

- `$S/doctor` is all `PASS`. Default seed: profiles `bot-alpha` (`Bot Alpha`) and `bot-beta` (`Bot Beta`) exist in the sandbox.
- `roster-pin`, `roster-primary`, `roster-parity-seed` and the message search need `VERIFY_IOS_SEED=parity $S/launch`. The eight parity bots replace `bot-alpha` and `bot-beta` (slugs `default`, `cho-ua`, `cho-ai-image-gen`, `upwork-hunter`, `cho-research-app`, `cho-hong-hot`, `market-researcher`, `cho-dinh`), and `HomeE2ETests` and `SeededRosterE2ETests` skip without it. A skip is a failed proof.

- **List and search** (`roster-list`, `roster-search`). Run `$S/drive --label roster-list BotChatE2ETests/test1RosterShowsBothBots`. The test asserts `botRow-bot-alpha` and `botRow-bot-beta` exist with height at least 56 and a label containing `Bot Alpha` and `Bot Beta`, taps `rosterSearchField` (the launcher), types `alpha` into `searchField`, waits for `searchResult-bot-bot-alpha`, waits for `searchResult-bot-bot-beta` to disappear, closes with `searchClose` and waits for `botRow-bot-alpha`. Result: `verdict=PASS`, screenshots `roster.png` and `roster-search.png`.
- **Live activity** (`roster-live-activity`). Run `$S/drive-control --label roster-live RosterLiveE2ETests/test1ExternalTurnShowsWorkingThenIdleWithNewPreview`. An external client submits a slow turn to `bot-alpha`; the row value goes `idle`, `working` within 6 s, then `idle` with a `slow-` preview, and `bot-beta` does not change. Screenshots `realtime-1-idle.png`, `realtime-2-working.png`, `realtime-3-idle-new-preview.png`. Needs-input: `$S/drive-control RosterLiveE2ETests/test3ExternalClarifyShowsNeedsInputInRosterAndChatHeader`.
- **Offline and recovery** (`roster-offline`). Run `$S/drive-control RosterLiveE2ETests/test2GatewayLossShowsOfflineThenRecoversWithoutInteraction`. The gateway is killed; both rows report `offline` within 8 s and `userAvatarButton` leaves `Connected`; after the gateway restarts both return to `idle` and `Connected` without a tap. Screenshots `realtime-4-connected.png`, `realtime-5-offline.png`, `realtime-6-recovered.png`.
- **Pin and primary** (`roster-pin`, `roster-primary`, `roster-context-menu`). With the parity seed run `$S/drive --label roster-pin HomeE2ETests/test2PinAndUnpinMovesTheBotToTheTopAvatars HomeE2ETests/test3MakePrimaryMovesTheStar`. Test 2 long-presses `botRow-cho-ua`, taps `pinAction`, sees `heroAvatar-cho-ua`, then `unpinAction` removes it. Test 3 opens the menu on `botRow-cho-dinh`, taps `makePrimaryAction` and checks the `primary bot` label moved from the previous primary and back.
- **Message search** (`roster-search`). With the parity seed run `$S/drive HomeE2ETests/test4SearchFindsAMessageAndOpensItsChat`: the `searchChips-messages` chip, typing `Crashlytics` finds `searchResult-message-cho-dinh`, and tapping it opens `chatScreen`.
- **Working state** (`roster-live-activity`, seeded). `$S/drive HomeE2ETests/test5WorkingBotShowsItsActivity` sends `SLOW keep working` to `market-researcher` and waits for its row value `working`.
- **Seeded roster** (`roster-parity-seed`). `$S/drive SeededRosterE2ETests/test1RosterShowsTheEightParityBots` waits for the eight rows and a seeded preview on `botRow-upwork-hunter`.
- **Proof.** Each drive evidence dir holds `shots/*.png`, `run.mov` or `ui-e2e.mov`, and `verdict.txt`. Read the `working` and `offline` screenshots and confirm the row text and avatar match the state.

## Gotchas

- Row state is in the accessibility value (`idle`, `working`, `needs-input`, `offline`, `attention`), not the label. Assert the value.
- Pinned bots render as hero avatars in a row under the same `botRow-<name>` identifier; do not assume a separate row for them. Under the default seed check the screenshot to see which bots are pinned.
- The primary bot is marked by a star badge (also on rows) and the `primary bot` text in its label.
- `drive-control` tests start their own sandbox gateway and may restart it on a new process; the port stays the same, the gateway pid changes. Do not run `doctor` against the launch backend while they run and expect the same gateway pid.
- Live-activity tests hold an external client open (`--hold 90`). `drive-control` stops them in its cleanup; confirm no `gateway_client.py` process remains.
- `drive-control` always uses the default two-bot gateway, so run it from a default-seed launch.

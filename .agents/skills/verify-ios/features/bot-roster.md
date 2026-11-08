# Bot roster

After sign-in the user sees their bots as a list with an avatar, name, last-message preview, timestamp and a live activity state. They can search by name, and see the list go offline when the gateway is lost and recover on its own.

## Sub-features

- `roster-list` shows one row per bot profile with name and preview.
- `roster-search` filters rows as the user types and restores them when cleared.
- `roster-live-activity` shows `working`, `needs-input` and `idle` as another client runs a turn.
- `roster-offline` shows every bot `offline` when the gateway is lost and `idle` again after it returns, with no user action.

## How to get to it (user POV)

- Sign in. The roster is the first screen.
- Type in the `Search` field at the bottom of the roster.
- Watch the roster while another client (the Desktop app or a CLI client) runs a turn on a bot.

## Driving it with verify-ios

Preconditions:

- `$S/doctor` is all `PASS`. Profiles `bot-alpha` and `bot-beta` exist in the sandbox.

- **List and search** (`roster-list`, `roster-search`). Run `$S/drive --label roster-list BotChatE2ETests/test1RosterShowsBothBots`. The test asserts `botRow-bot-alpha` and `botRow-bot-beta` exist with height at least 56 and a label containing the name, types `alpha` into `rosterSearchField`, waits for `botRow-bot-beta` to disappear, and asserts `botRow-bot-alpha` remains. Result: `verdict=PASS`, screenshots `roster.png` and `roster-search.png`.
- **Live activity** (`roster-live-activity`). Run `$S/drive-control --label roster-live RosterLiveE2ETests/test1ExternalTurnShowsWorkingThenIdleWithNewPreview`. An external client submits a slow turn to `bot-alpha`; the row value goes `idle`, `working` within 6 s, then `idle` with a `slow-` preview, and `bot-beta` does not change. Needs-input: `$S/drive-control RosterLiveE2ETests/test3ExternalClarifyShowsNeedsInputInRosterAndChatHeader`.
- **Offline and recovery** (`roster-offline`). Run `$S/drive-control RosterLiveE2ETests/test2GatewayLossShowsOfflineThenRecoversWithoutInteraction`. The gateway is killed; both rows report `offline` within 8 s and `userAvatarButton` leaves `Connected`; after the gateway restarts both return to `idle` and `Connected` without a tap.
- **Proof.** Each drive evidence dir holds `shots/*.png` (idle, working, offline, recovered), `run.mov` or `ui-e2e.mov`, and `verdict.txt`. Read the `working` and `offline` screenshots and confirm the row text and avatar match the state.

## Gotchas

- Row state is in the accessibility value (`idle`, `working`, `needs-input`, `offline`), not the label. Assert the value.
- `drive-control` tests start their own sandbox gateway and may restart it on a new process; the port stays the same, the gateway pid changes. Do not run `doctor` against the launch backend while they run and expect the same gateway pid.
- The first bot is shown as a hero with the same `botRow-<name>` identifier. Do not assume a separate row for it.
- Live-activity tests hold an external client open (`--hold 90`). `drive-control` stops them in its cleanup; confirm no `gateway_client.py` process remains.

# Bot avatar

Each bot has a generated avatar that renders in the roster rows, the pinned hero row and the chat header, and animates by mood (idle, think, work, done) with reduced-motion support. The Swift drawing and motion code must stay pixel-equivalent with the Desktop reference.

## Sub-features

- `avatar-render` draws each bot's avatar in the roster rows and the pinned hero, with a star badge on the primary bot.
- `avatar-mood` follows the bot's live activity: `working` shows the work mood, `idle` and `needs-input` show idle, a one-shot done mood plays when a bot goes from working to idle, and `offline` dims the avatar to 0.45 opacity.
- `avatar-parity` matches the Desktop reference pixel matrix and motion spec on the host (`AvatarParityTests`, `AvatarMotionTests`, `DesktopSemanticsTests`).
- `avatar-tone` turns a white avatar dark on a light screen, and `avatar-pointer-look` lets the eyes follow the pointer (`AvatarToneTests`, `AvatarPointerLookTests`, host only).
- `avatar-surfaces` reuses the avatar on the sign-in floating avatars, voice mode (think mood), bot-thread participants, the create-bot preview and search rows. No shipped UI test; judge from screenshots taken by other features.

## How to get to it (user POV)

- Sign in and look at the avatar beside each bot on the roster, and at the pinned avatars at the top.
- Run a turn on a bot from another client and watch its avatar change while it works, then celebrate once.
- Open a bot and see the avatar in the chat header.

## Driving it with verify-ios

Preconditions:

- For `avatar-parity`, `avatar-tone` and `avatar-pointer-look`, none: `swift-test` needs no simulator, backend or launch.
- For `avatar-render` and `avatar-mood`, `$S/doctor` is all `PASS`.

- **Parity, motion, tone and pointer look** (`avatar-parity`, `avatar-tone`, `avatar-pointer-look`). Run `$S/swift-test PalDesign`. All Swift Testing suites pass with exit 0; `verdict.txt` in the evidence dir records `swift_test_exit=0`. Narrow with `$S/swift-test PalDesign --filter 'AvatarToneTests|AvatarPointerLookTests|AvatarMotionTests|DesktopSemanticsTests'`; the filter uses the Swift type names, while the log prints each suite's display name.
- **Render in the roster** (`avatar-render`). Run `$S/drive --label avatar-render BotChatE2ETests/test1RosterShowsBothBots`, then read `shots/roster.png`. Each row or hero cell shows a distinct avatar next to the bot name, and the primary bot carries a star badge. The test asserts only row existence; the visual judgment is yours, and you state it from the screenshot.
- **Mood follows activity** (`avatar-mood`). Run `$S/drive-control RosterLiveE2ETests/test1ExternalTurnShowsWorkingThenIdleWithNewPreview`. Compare `realtime-1-idle.png`, `realtime-2-working.png` and `realtime-3-idle-new-preview.png`: the working avatar differs from idle. Then run `RosterLiveE2ETests/test2GatewayLossShowsOfflineThenRecoversWithoutInteraction` and read `realtime-5-offline.png` (dimmed) and `realtime-6-recovered.png`.
- **Proof.** For the host suites, the passing test count and exit code. For render and mood, the screenshots plus `run.mov` showing the motion.

## Gotchas

- The simulator screenshot is a still frame; blink and gaze motion need `run.mov` or the host motion suite, not a single image.
- Reduced Motion changes poses; the simulator setting is off by default, so reduced-motion behavior is covered only by `AvatarMotionTests`.
- `needs-input` and `attention` map to the idle mood; the roster shows a glyph, not a different avatar pose. Only `working` changes the pose, and the done mood is a short one-shot too brief to catch reliably in a still.
- Regenerating parity fixtures (`apps/ios/Tools/avatar-parity/regenerate.sh`) changes committed test data; this skill never runs it.
- Mood assertions in UI tests read the row accessibility value, not the avatar pixels.
- Pinned bots appear in the hero row; which bots are pinned depends on the seed, so read the screenshot.

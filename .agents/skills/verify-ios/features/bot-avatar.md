# Bot avatar

Each bot has a generated avatar that renders in the roster rows, the primary-bot hero and the chat header, and animates by mood (idle, working, needs input, done) with reduced-motion support. The Swift drawing and motion code must stay pixel-equivalent with the Desktop reference.

## Sub-features

- `avatar-render` draws each bot's avatar in the roster rows and hero.
- `avatar-mood` changes the avatar mood and opacity with the bot's live activity.
- `avatar-parity` matches the Desktop reference pixel matrix and motion spec on the host.

## How to get to it (user POV)

- Sign in and look at the avatar beside each bot on the roster.
- Run a turn on a bot from another client and watch its avatar change while it works.
- Open a bot and see the avatar in the chat header.

## Driving it with verify-ios

Preconditions:

- For `avatar-parity`, none beyond a launched run for the evidence directory. `swift-test` needs no simulator or backend.
- For `avatar-render` and `avatar-mood`, `$S/doctor` is all `PASS`.

- **Parity and motion** (`avatar-parity`). Run `$S/swift-test HermesDesign`. The Swift Testing suites (`AvatarParityTests`, `AvatarMotionTests`, `DesktopSemanticsTests`) pass with exit 0; `verdict.txt` in the evidence dir records `swift_test_exit=0`. Narrow with `$S/swift-test HermesDesign --filter AvatarMotionTests`.
- **Render in the roster** (`avatar-render`). Run `$S/drive --label avatar-render BotChatE2ETests/test1RosterShowsBothBots`, then read `shots/roster.png`. Each row shows a distinct avatar left of the bot name, and the hero (first bot) shows a larger avatar with a star badge. The test asserts only row existence; the visual judgment is yours, and you state it from the screenshot.
- **Mood follows activity** (`avatar-mood`). Run `$S/drive-control RosterLiveE2ETests/test1ExternalTurnShowsWorkingThenIdleWithNewPreview`. Compare `realtime-1-idle.png`, `realtime-2-working.png` and `realtime-3-idle-new-preview.png`: the working avatar differs from idle, and offline (`realtime-5-offline.png` from the gateway-loss test) is dimmed.
- **Proof.** For parity, the passing log line count and exit code. For render and mood, the screenshots plus `run.mov` showing the motion.

## Gotchas

- The simulator screenshot is a still frame; blink and gaze motion need `run.mov` or the host motion suite, not a single image.
- Reduced Motion changes poses; the simulator setting is off by default, so reduced-motion behavior is covered only by `AvatarMotionTests`.
- Regenerating parity fixtures (`apps/ios/Tools/avatar-parity/regenerate.sh`) changes committed test data; this skill never runs it.
- Mood assertions in UI tests read the row accessibility value, not the avatar pixels.

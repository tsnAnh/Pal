---
name: control-mobile
description: Build or adapt a local harness to drive and inspect an Android, iOS, Flutter, or Kotlin Multiplatform app on an emulator or simulator. Use for mobile UI verification, screenshots and screen recordings, UI hierarchy dumps, logs, startup and frame timing, deep links, or reproducing mobile bugs. The mobile counterpart of team-workflows's control-ui.
---

# Control mobile

Use an emulator or simulator to verify mobile behavior with evidence. First reuse the repository's own harness if it has one (Maestro flows, Espresso or UI Automator tests, XCUITest, Flutter `integration_test`, Detox). Otherwise assemble one from the commands below. When the harness proves useful, turn it into a project verification skill with `/create-verification-skill` so the next agent does not rebuild it.

## What it is used for

- Reproducing bugs that depend on real touch, keyboard, rotation, permissions, background and foreground, or deep links.
- Before and after screenshots and recordings for `verify-this` and pull requests.
- Reading the UI hierarchy to find stable targets instead of guessing coordinates.
- Capturing logs, startup time, frame timing, and traces for performance work.

## Setup pattern

1. Build the debug app with the repository's command.
2. Boot one emulator or simulator that you own for this run. Record its id so cleanup removes only what you started.
3. Install and launch the app, then wait until it is ready: a known screen in the hierarchy, not a sleep.
4. Drive one action at a time and observe after each.

## Android

```bash
emulator -list-avds
emulator -avd <avd> -no-window -no-audio -no-snapshot-save &
adb wait-for-device && until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ]; do sleep 1; done
./gradlew :app:installDebug
adb shell am start -W -n <package>/<activity>
adb shell uiautomator dump /sdcard/ui.xml && adb pull /sdcard/ui.xml /tmp/ui.xml
adb shell input tap <x> <y>
adb shell input text "<text>"
adb exec-out screencap -p > /tmp/after.png
adb shell screenrecord --time-limit 20 /sdcard/run.mp4
adb logcat -d -v time --pid "$(adb shell pidof -s <package>)"
adb shell dumpsys gfxinfo <package> framestats
adb shell am start -a android.intent.action.VIEW -d "<scheme>://<path>"
```

`am start -W` prints `TotalTime`, the cold start time. Take tap coordinates from a hierarchy dump captured immediately before the tap, using the node's `bounds`.

## iOS

```bash
xcrun simctl list devices available
xcrun simctl boot "<device name or udid>"
xcodebuild -scheme <scheme> -destination "platform=iOS Simulator,name=<device name>" -derivedDataPath /tmp/dd build
xcrun simctl install booted /tmp/dd/Build/Products/Debug-iphonesimulator/<App>.app
xcrun simctl launch --console-pty booted <bundle id>
xcrun simctl io booted screenshot /tmp/after.png
xcrun simctl io booted recordVideo /tmp/run.mp4
xcrun simctl openurl booted "<scheme>://<path>"
xcrun simctl privacy booted grant photos <bundle id>
xcrun simctl spawn booted log stream --predicate 'subsystem == "<subsystem>"'
```

`simctl` cannot tap. Drive touches with Maestro or an XCUITest target. The iOS Simulator needs macOS; in a Linux cloud session, verify iOS on a macOS runner instead.

## Flutter

```bash
flutter devices
flutter run -d <device id> --debug
flutter test integration_test -d <device id>
flutter screenshot -d <device id> -o /tmp/after.png
flutter run -d <device id> --profile
```

`integration_test` drives widgets by key or text and runs on Android, iOS, and desktop devices. Profile mode plus DevTools gives frame timing and CPU profiles.

## Kotlin Multiplatform

Verify shared logic with `./gradlew allTests`. Verify each platform's UI with the Android and iOS sections above. Compose Multiplatform desktop targets can be driven like any desktop app.

## Maestro, for both platforms

Maestro drives Android and iOS with the same YAML, by visible text or accessibility id:

```yaml
appId: <package or bundle id>
---
- launchApp
- tapOn: "Checkout"
- assertVisible: "Order placed"
- takeScreenshot: after-checkout
```

Run it with `maestro test flow.yaml`, and inspect targets with `maestro hierarchy`. A folder of Maestro flows is a good core for a mobile verification skill's CLI.

## Interaction loop

1. Capture the hierarchy or a screenshot before acting.
2. Pick a target from that capture: an accessibility id or visible text first, coordinates last.
3. Perform exactly one action.
4. Capture again and check the expected change.
5. Save before and after artifacts when the user asked for proof.

## Guardrails

- Never drive a physical device, or an emulator the user has open, without asking. Boot your own.
- Clear app data only on debug builds you installed (`adb shell pm clear <package>`, `xcrun simctl uninstall`).
- Keep screenshots of real accounts private unless the user agrees to share them.
- Do not hard-code device names, package ids, or coordinates from another repository.
- Clean up what you started: `adb emu kill` for your emulator, `xcrun simctl shutdown <udid>` for your simulator, and the processes you launched. Keep the evidence files.

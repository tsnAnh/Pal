# Verification drivers

A verification skill lets an agent prove its own change by driving the real app. `/create-verification-skill` (pstack) builds one per repository. This table gives it a starting recipe for each kind of surface. See `skills/control-mobile/SKILL.md` for the mobile commands and team-workflows's `control-ui` and `control-cli` for web and terminal apps.

## Per surface

| Surface | Launch | Doctor (is it worth driving?) | Drive | Evidence | Performance |
|---|---|---|---|---|---|
| Android app | `./gradlew :app:installDebug`, `adb shell am start -W` | Emulator booted (`sys.boot_completed`), right build installed (`dumpsys package` version) | Maestro, UI Automator, or `adb shell input` after a hierarchy dump | `screencap`, `screenrecord`, `logcat --pid` | `am start -W` TotalTime, `dumpsys gfxinfo framestats`, Perfetto |
| iOS app | `xcodebuild ... build`, `simctl install`, `simctl launch` | Simulator booted, bundle installed, right version (`simctl appinfo`) | Maestro or XCUITest | `simctl io screenshot`, `recordVideo`, `log stream` | Instruments via `xcrun xctrace record` |
| Flutter app | `flutter run -d <device>` | `flutter devices` lists the device, app reachable over the VM service | `integration_test`, Maestro | `flutter screenshot`, platform recorders | Profile mode, DevTools timeline |
| Kotlin Multiplatform | Per platform, as above | Per platform | Shared logic through `allTests`; UI per platform | Per platform | Per platform |
| Web app | The dev server command | Port answers, right build hash | Playwright or CDP (`control-ui`) | Screenshots, accessibility snapshots, console and network logs | Traces, CPU profiles, Web Vitals |
| Electron or desktop | The app with `--remote-debugging-port` | The debug port answers for our checkout | CDP (`control-ui`) | Screenshots, accessibility tree | Traces, heap snapshots |
| CLI or TUI | Build the binary once | Binary runs `--version` | tmux or a PTY harness (`control-cli`) | Terminal transcripts, exit codes, written files | `hyperfine`, CPU profiles |
| HTTP service | Start it with seeded data | Health endpoint answers | `curl` or a small client script | Response bodies, database rows, logs | Load test with a fixed script |

## The CLI inside the verification skill

Give agents a small command-line tool inside the skill, not paragraphs of instructions. Each run then costs one command instead of a throwaway script. The tool should have:

- Subcommands grouped by purpose: inspection (`info`, `snapshot`, `screenshot`), navigation (`home`, `open <screen>`), interaction (`tap`, `type`, `press`, `feature-flag`), performance (`trace`, `startup`, `frames`), streaming (`logs`), and health (`doctor`, `cleanup`).
- `--help` with an example for every subcommand.
- JSON output with `--json`, so results can be compared across runs.
- `--dry-run` on anything with side effects.
- Errors that say what to do next, for example "No emulator is booted. Run `control-app boot` first."
- A `--checkout` or instance flag, so parallel agents never drive each other's app.

## The feature map

Next to the CLI, keep `references/features/`: a `README.md` index and one file per user-facing feature, each with the sections `Sub-features`, `How to get to it (user POV)`, `Driving it with <cli>`, and `Gotchas`. It is the app's memory in a form agents can search: what exists, how a user reaches it, and how to prove it works. Keep it current with `/maintain-verification-skill`, ideally from a daily scheduled job, and give the skill an owner the way you would any critical infrastructure.

## Proof without a device

Linux cloud sessions cannot start the iOS Simulator, and most lack the KVM an accelerated Android emulator needs. Give the verification skill a second proof mode for those sessions, and have `doctor` report which mode the current machine supports, so the agent says up front what it can show.

| Surface | Proof a Linux container can take | Where on-device proof comes from |
|---|---|---|
| Android or KMP with Compose | JVM screenshot tests: Roborazzi (Robolectric) or Paparazzi (layoutlib). Record per screen state; compare in `check` | A KVM-enabled or macOS CI runner, or a device farm |
| Flutter | `flutter test` with `matchesGoldenFile`, plus the web target driven by `control-ui` | As Android and iOS |
| iOS | None | A GitHub Actions macOS runner running the snapshot tests and posting the images (`templates/github/ios-snapshots.yml`); Xcode Cloud or fastlane to TestFlight to put a build on a person's phone |

Screenshot tests double as proof and as a regression check: once recorded, `check` fails when a screen changes without its images being updated. How the images reach the pull request: [evidence in pull requests](evidence-in-prs.md).

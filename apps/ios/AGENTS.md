# Pal (apps/ios)

Pal is the SwiftUI iPhone and macOS app (`apps/ios`), not the Electron desktop app. Read `.agents/skills/verify-ios/SKILL.md` before running UI tests.

## Rule 1: service suggestions follow Connected apps

A Suggested item that depends on a service shows only when that service is connected in Connected apps. It is hidden, with no placeholder, when the service is not connected or its state is not yet known. A Suggested section with no visible items does not render.

- Shared helper: `ConnectedServices` and `ServiceSuggestion` in `Packages/HermesKit/Sources/HermesConnect/ConnectedServices.swift`. "Connected" is the Connected apps catalog (`ConnectAppsService.load()`), never a second status call.
- App wiring: `ProfileSuggestion` and `ConnectedServicesModel` in `App/Profile/ProfileSuggestion.swift`. Both `MacInspector` and `BotProfileView` render `visibleSuggestions` only.
- New suggestion: add a `ServiceKind` case if it needs a service, add a `ProfileSuggestion` case with its `requiredService`, and render it inside the `visibleSuggestions` loop. The Connect entry point for a service lives in Connected apps, never in Suggested.

## Rule 2: sign-in, OAuth and add-to links open in the system browser

Every sign-in, OAuth or "add to <service>" link opens in the system browser (`UIApplication.open` on iOS, `NSWorkspace` on Mac), never in SFSafariViewController, WKWebView, WebPage or an in-app sheet. Slack's flow does not support in-app browsers.

- Shared helper: `ExternalLink.open(_:)` in `App/Platform/ExternalLink.swift`. Only https and http URLs open.
- New link: call `ExternalLink.open(url)`. Do not use `inAppBrowser(url:)`; it is for plain content links in the Library only.
- Exception: `WebAuthenticationBrowser` (`ASWebAuthenticationSession`) stays for gateway and Connected apps sign-in, because those flows return to the app through the `dev.tsnanh.hermes.bot` callback or a loopback redirect that a plain `open` cannot deliver.
- Enforced by `ExternalLinkPolicyTests` in `Packages/HermesKit/Tests/HermesKitTests`, which scans `App/` for web surfaces outside their allowlist.

## Tests

- `swift test` in `apps/ios/Packages/HermesKit` covers `ConnectedServices` and the source scan.
- UI tests pass `-hermes-record-external-links` (links are recorded, not opened; read `externalLinkProbe`) and `-hermes-test-connected-services slack` (see `BotProfileSupport.signedInApp`).

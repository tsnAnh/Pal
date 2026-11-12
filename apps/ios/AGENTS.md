# Pal (apps/ios)

Pal is the SwiftUI iPhone and macOS app (`apps/ios`), not the Electron desktop app. Read `.agents/skills/verify-ios/SKILL.md` before running UI tests.

## Rule 1: service suggestions follow Connected apps

A Suggested item that depends on a service shows only when that service is connected in Connected apps. It is hidden, with no placeholder, when the service is not connected or its state is not yet known. A Suggested section with no visible items does not render.

- Shared helper: `ConnectedServices` and `ServiceSuggestion` in `Packages/PalKit/Sources/PalConnect/ConnectedServices.swift`. "Connected" is the Connected apps catalog (`ConnectAppsService.load()`), never a second status call.
- App wiring: `ProfileSuggestion` and `ConnectedServicesModel` in `App/Profile/ProfileSuggestion.swift`. Both `MacInspector` and `BotProfileView` render `visibleSuggestions` only.
- New suggestion: add a `ServiceKind` case if it needs a service, add a `ProfileSuggestion` case with its `requiredService`, and render it inside the `visibleSuggestions` loop. The Connect entry point for a service lives in Connected apps, never in Suggested.

## Rule 2: sign-in, OAuth and add-to links open in the system browser

Every sign-in, OAuth or "add to <service>" link opens in the system browser (`UIApplication.open` on iOS, `NSWorkspace` on Mac), never in SFSafariViewController, WKWebView, WebPage or an in-app sheet. Slack's flow does not support in-app browsers.

- Shared helper: `ExternalLink.open(_:)` in `App/Platform/ExternalLink.swift`. Only https and http URLs open.
- New link: call `ExternalLink.open(url)`. Do not use `inAppBrowser(url:)`; it is for plain content links in the Library only.
- Exception: `WebAuthenticationBrowser` (`ASWebAuthenticationSession`) stays for gateway and Connected apps sign-in, because those flows return to the app through the `dev.tsnanh.hermes.bot` callback or a loopback redirect that a plain `open` cannot deliver.
- Upwork (`mcp:upwork`) signs in on the Mac only: `McpOAuthFlow` (PalConnect) runs discovery, dynamic client registration and PKCE against a `LoopbackRedirectListener`, opens the authorization URL through `ExternalLink.open` (`SystemBrowserAuthorization`, never `ASWebAuthenticationSession`) and hands the tokens to the gateway with `auth.submit_oauth_tokens`. The iPhone shows "Sign in on your Mac" (`ConnectorCardState.signInOnMac`).
- Enforced by `ExternalLinkPolicyTests` in `Packages/PalKit/Tests/PalKitTests`, which scans `App/` for web surfaces outside their allowlist.

## Rule 3: connectors that need auth raise the sign-in dialog

Any new connector, MCP preset or service tool that can fail on a missing, expired or revoked credential must declare its auth type and surface the failure through `tools/auth_required.py`, so the gateway raises `auth.required` and the app shows `ServiceSignInView`.

- Declare: catalog manifests carry `auth.type` (`oauth`, `api_key` or `none`); hosted connectors use the `CONNECTION_REQUIRED` and `CONNECTION_EXPIRED` codes; anything else returns `auth_required_result(service, reason)` (or `http_auth_failure(service, status, headers)` for a 401 or 403).
- How to: register a `SigninFlow` for the service prefix with `register(prefix, factory)` in `gateway/auth_flows.py`. Flows are `device_code`, `oauth`, `api_key` and `header` (one masked box, `SecretEntryView`, answered with `auth.submit_credential`) and `manual`. A new Connected apps source kind in `ConnectCatalog.swift` must be added to `auth_flows.CONNECT_APP_SOURCES`.
- Enforced by `tests/gateway/test_auth_catalog.py`: it walks every `optional-mcps` manifest, raises the event through the real detection path, and fails on a missing auth type, a Swift enum drifting from `tui_gateway/contracts/canonical_auth.py`, or an undeclared source kind.
- Secrets: the app never receives a token. Keys go from the masked field straight to the gateway's secret path in `auth.submit_credential` (or the connector's own authenticated settings call) and are never echoed, logged, stored or held in a plain `String` longer than the field needs (`SecretString` redacts). The dialog opens verification and OAuth URLs through `ExternalLink.open` (Rule 2).
- Any configuration or credential the apps still need (messaging included, such as Slack or Telegram) must be settable from the Swift apps, through the shared secret-entry flow (`SecretEntryView`, `SecretField`) or a settings form, never only by a terminal, SSH or the hermes CLI.

## Tests

- `swift test` in `apps/ios/Packages/PalKit` covers `ConnectedServices` and the source scan.
- UI tests pass `-hermes-record-external-links` (links are recorded, not opened; read `externalLinkProbe`) and `-hermes-test-connected-services slack` (see `BotProfileSupport.signedInApp`).

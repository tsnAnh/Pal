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
- Upwork (`mcp:upwork`) signs in from any device (`signin_on: owner_app`): `McpOAuthFlow` (PalConnect) runs discovery, dynamic client registration and PKCE in two phases (`beginPasted()` / `authorize()`, then `complete`). Mac: `LoopbackRedirectListener`. iPhone/iPad: paste route only (`PastedAuthorization.parse`, masked `PasteAddressEntry`, `PasteboardScrub`), registering `http://127.0.0.1:<port>/callback` that nothing serves. Links open through `ExternalLink.open` (never `ASWebAuthenticationSession`); tokens go to the gateway with `auth.submit_oauth_tokens`. Routes per device: `ConnectorPlatform.signInRoutes`. A rejected saved sign-in shows its reason with Reconnect on every device. Upwork and every `mcp_oauth` connector sign in through one sheet (`McpSignInSheet`, state in `McpSignInController`); a failure shows `StatusBlock` with the reason code, method and trace behind Details.
- Enforced by `ExternalLinkPolicyTests` in `Packages/PalKit/Tests/PalKitTests`, which scans `App/` for web surfaces outside their allowlist.

## Rule 3: connectors that need auth raise the sign-in dialog

Any new connector, MCP preset or service tool that can fail on a missing, expired or revoked credential must declare its auth type and surface the failure through `tools/auth_required.py`, so the gateway raises `auth.required` and the app shows `ServiceSignInView`.

- Declare: catalog manifests carry `auth.type` (`oauth`, `api_key` or `none`); Pal connects each catalog entry directly (`mcp.servers.add`, then MCP OAuth or a bearer token) and has no hosted connect flow; anything else returns `auth_required_result(service, reason)` (or `http_auth_failure(service, status, headers)` for a 401 or 403).
- How to: register a `SigninFlow` for the service prefix with `register(prefix, factory)` in `gateway/auth_flows.py`. Flows are `device_code`, `oauth`, `api_key` and `header` (one masked box, `SecretEntryView`, answered with `auth.submit_credential`) and `manual`. A new Connected apps source kind in `ConnectCatalog.swift` must be added to `auth_flows.CONNECT_APP_SOURCES`.
- Enforced by `tests/gateway/test_auth_catalog.py`: it walks every `optional-mcps` manifest, raises the event through the real detection path, and fails on a missing auth type, a Swift enum drifting from `tui_gateway/contracts/canonical_auth.py`, or an undeclared source kind.
- Secrets: the app never receives a token. Keys go from the masked field straight to the gateway's secret path in `auth.submit_credential` (or the connector's own authenticated settings call) and are never echoed, logged, stored or held in a plain `String` longer than the field needs (`SecretString` redacts). The dialog opens verification and OAuth URLs through `ExternalLink.open` (Rule 2).
- Google Workspace (`google:workspace`, `GoogleWorkspaceService` in PalConnect) signs in by paste on every device: `google_workspace.signin.start` returns the Google URL (opened with `ExternalLink.open`), the owner pastes the address that fails to load into `PasteAddressEntry`, and `signin.finish` completes it. The skill's not-authenticated output raises a typed `auth.required` (`google:workspace`, flow `oauth_paste`, `signin_on` `owner_app`); the shared dialog signs in through `GoogleSignIn.servicePasteRoute` (never the native route) and the row shows needs-reauth until `signin.finish` ends the request. The PKCE verifier and every token stay on the gateway (methods `google_workspace.*`); the app only sees status.
- Google Workspace, Figma, Dropbox and Canva (catalog method `oauth_client`, `OAuthClientGuide.guidedSlugs`) connect with the owner's own OAuth client, saved once: `OAuthClientSheet` shows the console steps and redirect URL, writes both values with `vault.add`, then `connectors.oauth_client.save` receives only the item ids. Connect: Figma, Dropbox and Canva relay the redirect through `mcp.servers.oauth.callback` (Mac: `LoopbackRedirectListener` on localhost:27890; iPhone/iPad: paste route); Google opens the consent page and polls `connectors.catalog` until the row is `connected`. Remove calls `connectors.oauth_client.remove` and keeps the client. Other `oauth_client` rows without a guide (Slack) show `needs_setup` with no action until their own setup lands. Errors show `ChatInstallStatus` with the reason code (`NEEDS_PUBLIC_URL` and the others in `OAuthClientFailure`). UI tests script the gateway with `-hermes-test-oauth-client` (`ScriptedOAuthClientRPC`).
- Any configuration or credential the apps still need (messaging included, such as Slack or Telegram) must be settable from the Swift apps, through the shared secret-entry flow (`SecretEntryView`, `SecretField`) or a settings form, never only by a terminal, SSH or the hermes CLI.
- Use the system back and close controls; one way out per screen: the NavigationStack back, a `ToolbarItem(placement: .cancellationAction)` or `Button(role: .close)`, never a custom `chevron.left`/`xmark` Button (`scripts/ci/check_swift_nav_chrome.py`, `swift-nav-chrome` in `python scripts/check`; exception: `// nav-chrome: ok`).

## Rule 4: UI changes start from an owner-approved HTML mockup

Any unit that adds or changes what a person sees in the Pal app (macOS, iPhone, iPad, desktop: a screen, card, control, spacing, colour, empty or error state) is two steps. Follow-up polish on an already shipped screen counts too.

- Step 1, mockup: one self-contained HTML file of the result, with the app's real tokens, fonts, colours and spacing, light and dark, Mac and iPhone sizes where both apply, and every state (normal, empty, error, loading, long text). Hand it to the owner to open.
- Step 2, code: starts only after the owner approves the mockup in his own words. The approved mockup is the spec and the coding session does not deviate from it; any deviation is reported in the PR body as "Deviation:" with the reason.
- A coding session cannot ask the owner, so the gate sits before the session is launched. A session launched for a UI change with no approved mockup in its brief makes no UI code: it writes the mockup file instead and reports.
- Exempt: changes with no visible effect (logic, gateway, data, CI); the brief says so.

## Tests

- `swift test` in `apps/ios/Packages/PalKit` covers `ConnectedServices` and the source scan.
- UI tests pass `-hermes-record-external-links` (links are recorded, not opened; read `externalLinkProbe`) and `-hermes-test-connected-services slack` (see `BotProfileSupport.signedInApp`).

## Learned

- Mac UI tests: real Keychain, serial, fake creds; update: xcodegen, Release→/Applications, devicectl
- Mac/iOS parity+shared code; no streamed text (avatar+step+dots); Liquid Glass ToolbarItems; pinned bots top; no other brands; bot Qs never expire; NO_REPLY-type markers never shown/flashed anywhere
- Avatars: 14 blobs, 1:1:1 3D, unlit; black eyes (white→gray in light); body turns to pointer with eyes (no eyes-only/1-eye anims), upright on hover; rest eyes up-right, slanted; review render pre-build
- T3 Code = catalog connector `t3code` (no bridge): Network on, plain-http tailnet `<ip>:<port>/mcp`, OAuth DCR+PKCE, no refresh; wizard `T3CodeFlow` (PalConnect), Mac prefill `T3AddressSuggestion`

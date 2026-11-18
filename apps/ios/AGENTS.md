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
- Google Workspace, Figma, Dropbox and Canva (catalog method `oauth_client`, `OAuthClientGuide.guidedSlugs`) connect with the owner's own OAuth client, saved once: `OwnerSetupView` (`OwnerSetupModel` on the `StepFlowView` engine, App/Setup) walks the console steps and redirect URL, writes both values with `vault.add`, then `connectors.oauth_client.save` receives only the item ids. Connect: Figma, Dropbox and Canva relay the redirect through `mcp.servers.oauth.callback` (Mac: `LoopbackRedirectListener` on localhost:27890; iPhone/iPad: paste route); Google opens the consent page and polls `connectors.catalog` until the row is `connected`. Remove calls `connectors.oauth_client.remove` and keeps the client. Other `oauth_client` rows without a guide (Slack) show `needs_setup` with no action until their own setup lands. A saved client opens the flow at its sign-in step, with Replace and Remove there. Errors show a `StatusBlock` (`SetupStatus`: plain reason, Details with the code, trace and builds). UI tests script the gateway with `-hermes-test-oauth-client` (`ScriptedOAuthClientRPC`).
- Any configuration or credential the apps still need (messaging included, such as Slack or Telegram) must be settable from the Swift apps, through the shared secret-entry flow (`SecretEntryView`, `SecretField`) or a settings form, never only by a terminal, SSH or the hermes CLI.
- Use the system back and close controls; one way out per screen: the NavigationStack back, a `ToolbarItem(placement: .cancellationAction)` or `Button(role: .close)`, never a custom `chevron.left`/`xmark` Button (`scripts/ci/check_swift_nav_chrome.py`, `swift-nav-chrome` in `python scripts/check`; exception: `// nav-chrome: ok`).

## Rule 4: UI changes start from an owner-approved HTML mockup

Any unit that adds or changes what a person sees in the Pal app (macOS, iPhone, iPad, desktop: a screen, card, control, spacing, colour, empty or error state) is two steps. Follow-up polish on an already shipped screen counts too.

- Step 1, mockup: one self-contained HTML file of the result, with the app's real tokens, fonts, colours and spacing, light and dark, Mac and iPhone sizes where both apply, and every state (normal, empty, error, loading, long text). Hand it to the owner to open.
- Step 2, code: starts only after the owner approves the mockup in his own words. The approved mockup is the spec and the coding session does not deviate from it; any deviation is reported in the PR body as "Deviation:" with the reason.
- A coding session cannot ask the owner, so the gate sits before the session is launched. A session launched for a UI change with no approved mockup in its brief makes no UI code: it writes the mockup file instead and reports.
- Exempt: changes with no visible effect (logic, gateway, data, CI); the brief says so.

## Rule 5: Liquid Glass design rules are lint-enforced

Glass is a control and navigation layer floating above content, never the content layer. Run `python scripts/check --only swift-glass,swift-nav-chrome,swift-bot-tint` on every UI change before calling it ready; a finding names the file, line, rule id and the fix. Today's findings sit in `apps/ios/.glass-lint-baseline.json`: new code never adds to it, units that fix a finding delete its entry (`python scripts/ci/check_swift_glass.py --write-baseline`). Exception: `// glass-lint: ok` on the line.

| Apple rule | Pal decision | Lint id |
|---|---|---|
| Custom glass only sparingly, via `glassEffect(_:in:)` | `glassEffect` and `NSGlassEffectView` live in PalDesign only; screens use `PalGlass`, `.palGlass(...)` or the system `.glass` styles | `glass-hand-rolled` |
| Tint marks prominence, never darkens | No black or dark tint on glass on iOS, iPadOS or Mac (PAL-3 removes `PalGlass.darkTint`) | `glass-dark-tint` |
| Buttons take system styles | Neutral Liquid Glass capsule buttons, no blue; `.glass`, and `.glassProminent` for the one primary action. No `PillButton`, `PillButtonStyle`, `.pill(`, `.palPill`, blue Button (PAL-8 adds the capsule style) | `glass-pill-button` |
| Group nearby custom glass in `GlassEffectContainer` | Two or more `.palGlass` in one view sit in one container | `glass-container` |
| Sheets: standard Close on the leading side | `SheetChrome` hosts every sheet; Close is `Button(role: .close)` on the leading side; bottom inset comes from SheetChrome, never `.padding(.bottom, N)` | `glass-sheet-chrome`, `swift-nav-chrome` |
| Search is `.searchable` | `.searchable`, the plain system field or PalDesign `FloatingSearchBar`; no bezel, border, background or custom search view | `glass-search-field` |
| Bars over scrolling content use system insets (`safeAreaBar`, scroll edge effect) | A bar over a ScrollView uses `safeAreaInset` or `contentMargins` (measured height) and owns a background; no overlay or ZStack with fixed padding (PAL-4) | `glass-floating-bar` |
| System colours with light, dark and increased-contrast variants | Colours come from `PalTokens`, `theme.palette` or system colours; no raw hex, `Color(red:`, `Color(white:` in `App/` | `glass-raw-color` |
| Bot accents stay on small shapes | Surfaces use the neutral palette | `swift-bot-tint` |
| One design system | Mac and iOS share PalDesign components; no Electron (`apps/desktop` is not Pal) | review |
| Design first | UI changes start from an owner-approved mockup (Rule 4) | review |

Apple sources: HIG Materials, Toolbars, Search fields, Color; "Adopting Liquid Glass"; "Applying Liquid Glass to custom views"; `ButtonRole.close`; WWDC25 219, 323, 356. Reduce Transparency and Increase Contrast are automatic for system glass: never branch on them to swap glass.

## Tests

- `swift test` in `apps/ios/Packages/PalKit` covers `ConnectedServices` and the source scan.
- UI tests pass `-hermes-record-external-links` (links are recorded, not opened; read `externalLinkProbe`) and `-hermes-test-connected-services slack` (see `BotProfileSupport.signedInApp`).

## Learned

- Mac UI tests: real Keychain, serial, fake creds; update: xcodegen, Release→/Applications, devicectl
- Mac/iOS parity+shared code; no streamed text (avatar+step+dots); Liquid Glass ToolbarItems; pinned bots top; no other brands; bot Qs never expire; NO_REPLY-type markers never shown/flashed anywhere
- Avatars: 14 blobs, 1:1:1 3D, unlit; black eyes (white→gray in light); body turns to pointer with eyes (no eyes-only/1-eye anims), upright on hover; rest eyes up-right, slanted; review render pre-build
- T3 Code = catalog connector `t3code` (no bridge): Network on, plain-http tailnet `<ip>:<port>/mcp`, OAuth DCR+PKCE, no refresh; wizard `T3CodeFlow` (PalConnect), Mac prefill `T3AddressSuggestion`
- Google Ads = catalog `google-ads` (oauth_client + stdio `google-ads-mcp`, read-only), reuses the Workspace client, adwords scope only; wizard `GoogleAdsFlow` (PalConnect), RPC `connectors.google_ads.status|save|verify`; Explorer access refusal = `explorer_access_needed` status

# Pal (apps/ios)

Pal is the SwiftUI iPhone and macOS app (`apps/ios`), not the Electron desktop app. Read `.agents/skills/verify-ios/SKILL.md` before running UI tests.

## Rule 1: service suggestions follow Connected apps

A Suggested item that depends on a service shows only when Connected apps reports that service connected. Otherwise, unknown state included, it is hidden with no placeholder. An empty Suggested section does not render. Slack is not a suggestion: the bot profile always shows its Slack row (`ProfileSlackStatus`, `BotProfileModel.loadSlack`), since Slack is about the bot, not a connected app.

- Shared helper: `ConnectedServices` and `ServiceSuggestion` in `Packages/PalKit/Sources/PalConnect/ConnectedServices.swift`. "Connected" is the Connected apps catalog (`ConnectAppsService.load()`), never a second status call; `ConnectedServicesModel` (`App/Profile/ConnectedServicesModel.swift`) holds it for the profile.
- New suggestion: add a `ServiceKind` case and render the item only where `services.visible(_:)` allows it. The Connect entry point lives in Connected apps, never in Suggested.

## Rule 2: sign-in, OAuth and add-to links open in the system browser

Every sign-in, OAuth or "add to <service>" link opens in the system browser (`UIApplication.open` on iOS, `NSWorkspace` on Mac), never in SFSafariViewController, WKWebView, WebPage or an in-app sheet. Slack's flow does not support in-app browsers.

- Shared helper: `ExternalLink.open(_:)` in `App/Platform/ExternalLink.swift`. Only https and http URLs open.
- New link: `ExternalLink.open(url)`; `inAppBrowser(url:)` is only for plain content links in the Library.
- Exception: `WebAuthenticationBrowser` (`ASWebAuthenticationSession`) stays for gateway and Connected apps sign-in: they return through `PalURLScheme.current` or a loopback redirect a plain `open` cannot deliver.
- Upwork (`mcp:upwork`) signs in from any device (`signin_on: owner_app`): `McpOAuthFlow` (PalConnect) runs discovery, dynamic client registration and PKCE in two phases. Mac: `LoopbackRedirectListener`. iPhone/iPad: paste route only (`PastedAuthorization.parse`, masked `PasteAddressEntry`, `PasteboardScrub`), registering `http://127.0.0.1:<port>/callback` that nothing serves. Tokens go to the gateway with `auth.submit_oauth_tokens`. Routes per device: `ConnectorPlatform.signInRoutes`. A rejected saved sign-in shows its reason with Reconnect on every device. Upwork and every `mcp_oauth` connector sign in through one sheet (`McpSignInSheet`, state in `McpSignInController`); a failure shows `StatusBlock` with the reason code, method and trace behind Details.
- Enforced by `ExternalLinkPolicyTests` (PalKitTests): it scans `App/` for web surfaces outside their allowlist.

## Rule 3: connectors that need auth raise the sign-in dialog

Any new connector, MCP preset or service tool that can fail on a missing, expired or revoked credential must declare its auth type and surface the failure through `tools/auth_required.py`, so the gateway raises `auth.required` and the app shows `ServiceSignInView`.

- Declare: catalog manifests carry `auth.type` (`oauth`, `api_key` or `none`); Pal connects each catalog entry directly (`mcp.servers.add`, then MCP OAuth or a bearer token) and has no hosted connect flow; anything else returns `auth_required_result(service, reason)` (or `http_auth_failure(service, status, headers)` for a 401 or 403).
- How to: register a `SigninFlow` for the service prefix with `register(prefix, factory)` in `gateway/auth_flows.py`. Flows are `device_code`, `oauth`, `api_key` and `header` (one masked box, `SecretEntryView`, answered with `auth.submit_credential`) and `manual`. A new Connected apps source kind in `ConnectCatalog.swift` must be added to `auth_flows.CONNECT_APP_SOURCES`.
- Enforced by `tests/gateway/test_auth_catalog.py`: it walks every `optional-mcps` manifest, raises the event through the real detection path, and fails on a missing auth type, a Swift enum drifting from `tui_gateway/contracts/canonical_auth.py`, or an undeclared source kind.
- Secrets: the app never receives a token. Keys go from the masked field straight to the gateway (`auth.submit_credential` or the connector's authenticated settings call), never echoed, logged, stored or held in a plain `String` past the field (`SecretString` redacts). Verification and OAuth URLs open via `ExternalLink.open` (Rule 2).
- Google Workspace (`google:workspace`, `GoogleWorkspaceService` in PalConnect) signs in by paste on every device: `google_workspace.signin.start` returns the Google URL (opened with `ExternalLink.open`), the owner pastes the failing address into `PasteAddressEntry`, `signin.finish` completes it. The skill's not-authenticated output raises a typed `auth.required` (flow `oauth_paste`, `signin_on` `owner_app`); the dialog signs in through `GoogleSignIn.servicePasteRoute`. PKCE verifier and tokens stay on the gateway.
- Google Workspace, Figma, Dropbox and Canva (catalog method `oauth_client`, `OAuthClientGuide.guidedSlugs`) connect with the owner's own OAuth client, saved once: `OwnerSetupView` (`OwnerSetupModel` on the `StepFlowView` engine, App/Setup) walks the console steps and redirect URL, writes both values with `vault.add`, then `connectors.oauth_client.save` receives only the item ids. Connect: Figma, Dropbox and Canva relay the redirect through `mcp.servers.oauth.callback` (Mac: `LoopbackRedirectListener` on localhost:27890; iPhone/iPad: paste route); Google opens the consent page and polls `connectors.catalog` until `connected`. Remove calls `connectors.oauth_client.remove` and keeps the client. Unguided rows (Slack) show `needs_setup`. UI tests script the gateway with `-hermes-test-oauth-client` (`ScriptedOAuthClientRPC`).
- Any configuration or credential the apps need (Slack and Telegram included) is settable from the Swift apps (`SecretEntryView`, `SecretField` or a settings form), never only via terminal, SSH or the hermes CLI.
- System back/close only, one way out: NavigationStack back, `.cancellationAction` item or `PalCloseButton`; no custom `chevron.left`/`xmark` Button, no opt-out. Pushed: system back only; pane/full-screen: `SheetChrome` Close.

## Rule 4: UI changes start from an owner-approved HTML mockup

Any unit that adds or changes what a person sees in the Pal app (macOS, iPhone, iPad, desktop: a screen, card, control, spacing, colour, empty or error state) is two steps, follow-up polish on a shipped screen included.

- Step 1, mockup: one self-contained HTML file of the result, with the app's real tokens, fonts, colours and spacing, light and dark, Mac and iPhone sizes where both apply, and every state (normal, empty, error, loading, long text). Hand it to the owner to open.
- Step 2, code: only after the owner approves the mockup in his own words. It is the spec; any deviation goes in the PR body as "Deviation:" with the reason.
- A coding session cannot ask the owner, so the gate sits before launch: a UI session whose brief has no approved mockup writes the mockup file instead of UI code, and reports.
- Exempt: changes with no visible effect (logic, gateway, data, CI); the brief says so.

## Rule 5: Liquid Glass design rules are lint-enforced

Glass is a control and navigation layer floating above content, never the content layer. Run `python scripts/check --only swift-glass,swift-nav-chrome,swift-bot-tint` on every UI change; a finding names file, line, rule id and fix. Findings sit in `apps/ios/.glass-lint-baseline.json`: new code never adds to it; a fix deletes its entry (`check_swift_glass.py --write-baseline`). Exception: `// glass-lint: ok` on the line.

| Apple rule | Pal decision | Lint id |
|---|---|---|
| Custom glass only sparingly, via `glassEffect(_:in:)` | `glassEffect` and `NSGlassEffectView` live in PalDesign only with the Mac 15 fallbacks; screens call `.palGlass`, `.glassButtonStyle()`, `PalGlassContainer`, not raw macOS 26 APIs | `glass-hand-rolled`, `glass-raw-glass-api` |
| Tint marks prominence, never darkens | No black or dark tint on glass on iOS, iPadOS or Mac (PAL-3 removes `PalGlass.darkTint`) | `glass-dark-tint` |
| Buttons are native glass | Text buttons: `.glassButtonStyle()`; primary or selected: `.glassButtonStyle(prominent: true)` (raw `.glassProminent` follows the Mac system accent); default size, no `.controlSize`, no `.tint` (it fills `.glass`), no custom `ButtonStyle` | `glass-pill-button`, `glass-button-size`, `glass-button-tint`, `glass-prominent-direct`, `glass-custom-button-style`; old pill/capsule styles are deleted |
| Group nearby custom glass | Two or more `.palGlass` in one view share a `PalGlassContainer` | `glass-container` |
| Sheets: standard Close on the leading side | `SheetChrome` hosts every sheet; Close is `PalCloseButton` on the leading side, only in SheetChrome/`ToolbarItem`; bottom inset comes from SheetChrome, never `.padding(.bottom, N)` | `glass-sheet-chrome`, `glass-close-chrome`, `swift-nav-chrome` |
| Search is `.searchable` | `.searchable`, the plain system field or PalDesign `FloatingSearchBar`; no bezel, border, background or custom search view | `glass-search-field` |
| Bars over scrolling content use system insets (`.palSafeAreaBar`) | A bar over a ScrollView uses `safeAreaInset` or `contentMargins` (measured height) and owns a background; no overlay or ZStack with fixed padding (PAL-4) | `glass-floating-bar` |
| System colours with light, dark and increased-contrast variants | Colours come from `PalTokens`, `theme.palette` or system colours; no raw hex, `Color(red:`, `Color(white:` in `App/` | `glass-raw-color` |
| Bot accents stay on small shapes | Surfaces use the neutral palette | `swift-bot-tint` |
| Icons are the primary ink | `PalIcon`, `Label(_, palIcon:)`; no raw `Image(systemName:)`, `systemImage:` or blue; exceptions in `swift_icon_tint_allowlist.txt` | `swift-icon-tint` |
| Connect Apps, Slack setup: clear glass, ink | `PalTokens` ink, `.palClearGlass`, `ClearGlassSearchField`; no blue (`toggleOn`), green, red, hex, `.tint(`, `Glass.regular`; errors `palette.destructive` | `swift-connect-palette` |
| iPhone rows scroll | Row drags: `ScrollSafePan` | `swift-scroll-gesture` |
| Mac window fits: one `MacLayoutMetrics`, one `MacShellLayout`; sidebar rows use `.boundedToColumn()` | No width literal outside `MacLayoutMetrics`; the shell never lays out with a stack; a `Mac*Row` or row `LazyVStack` is bounded and has no `fixedSize` | `swift-mac-layout`, `MacLayoutMetricsTests` |
| Chat rows name their side | `chatRowFrame(for: ChatSender)`: bot leading, user trailing, chips `.system`; no max- or fixed-width `.frame` without `alignment:` | `swift-chat-row-alignment` |
| One design system | Mac and iOS share PalDesign components; no Electron (`apps/desktop` is not Pal) | review |
| Design first | UI changes start from an owner-approved mockup (Rule 4) | review |
| Mac popups: size classes (`MacModalSize`) | `MacModalPanel(size:)`/`macSheet(size:)`: compact (440, hugs), form (560, hugs), stepper (540x500), wide (720, hugs, max 600), full (70% of window, 640x440 floor), palette (640, 120pt from top); capped at 90% width, 85% height; no `width:`/`height:` on `MacModalPanel`; `.macAlert`/`.macConfirm`; `.macModalEnvironment()` last | `swift-modal-size`, `MacModalSizingTests` |
| Notification extension never requests Communication Notifications (app only) | entitlements exist | `swift-entitlements` |

Apple sources: HIG Materials, Toolbars, Search fields, Color; WWDC25 219, 323, 356. Reduce Transparency and Increase Contrast are automatic for system glass: never branch on them.

## Rule 6: Mac performance mistakes are lint-enforced

A Mac perf mistake becomes a type, lint rule or test, never a note. Run `python scripts/check --only swift-perf` on every change under `apps/ios`. `.perf-lint-baseline.json` holds findings already on main: never add to it, and delete the entry when you fix one (`python scripts/ci/check_swift_perf.py --write-baseline`). `.perf-lint-allowlist.json` lists, with a reason, files allowed `TimelineView`, `onContinuousHover`, one `NSEvent` monitor or an observed still image.

| Class | Rule | Enforced by |
|---|---|---|
| A. Parse or format in a View body | Markdown parsed once, passed as `ParsedMarkdown`; no `MarkdownDocument(parsing:)`, `AttributedString(markdown:)`, `Calendar.current`, `.formatted(` in a body or `@ViewBuilder`; chat timestamps from `ChatTimestampCache` | type `MarkdownView(parsed:)`; lint `perf-body-parse`, `perf-body-format`, `perf-timestamp-uncached` |
| A | Round or redraw an image once, when cached; one observed slot per cached key, not an observed dictionary; no `reversed()` or `map(\.id)` of rows in a body; no cache key from `CGPath.description` (use a `Hashable` struct) | lint `perf-redraw-per-call`, `perf-observed-image-dictionary`, `perf-body-array-work`, `perf-path-description-key` |
| C. Sync disk, JSON or queue on the main actor | `Data(contentsOf:)`, `String(contentsOf:)`, `JSONEncoder()`, `JSONDecoder()`, `JSONSerialization` in `App/` or `@MainActor` files, `queue.sync`; use `CacheStore.loadDetached` | lint `perf-main-disk-read`, `perf-main-json`, `perf-queue-sync` |
| E. Unbounded animation or tracking | `TimelineView` and `onContinuousHover` only in the allowlist, none faster than 1/30 s; no `.animation(_, value:)` on the Mac shell root; a drag never writes a `@Binding` per tick (`DragWidth`); avatars tick through `AvatarActivity`, list rows pass `sharesSlot: true`, entries share one grid (`AvatarSlotBudget`, `AvatarSchedule.onGrid`) | lint `perf-timeline-unlisted`, `perf-timeline-interval`, `perf-hover-unlisted`, `perf-animation-container`, `perf-avatar-row-slot`, `perf-drag-writes-binding`; tests `DragWidthTests`, `AvatarSharedClockTests` |
| F. Non-lazy or per-row machinery | `LazyVStack` for rows in a `ScrollView`; avatar content decoded once per bot and scheme (`AvatarContentStore`); one shared `NSEvent` monitor (`MessageMenuMonitor`); one `onGeometryChange` in the chat list (`ChatPinProbe`); chat rows take shared state only through `ChatRowContext`, stay `Equatable`, build one `OpenURLAction` (`FileLinkRouter`); markdown views in any `ForEach` take `.equatable()`; the hover bar exists only while shown (`barBuilt`). | lint `perf-eager-stack`, `perf-monitor-per-view`, `perf-geometry-per-row`, `perf-row-reads-model`, `perf-row-openurl-closure`, `perf-markdown-foreach-not-equatable`, `perf-hover-bar-unconditional` |
| M. Model ownership | `@LazyState` (`_model = LazyState { Model(...) }`) or `ModelHost` owns a model, loaded in `.task`; never `State(initialValue:)` in a View init or a model built in a body | lint `perf-state-model-init`, `perf-model-in-body` |
| J. Screen invalidation | `ChatView` never reads the draft (pass `$draft`; `reportsComposerDraft`) or streaming and scroll fields (`ChatTranscriptReaders`); a per-row flag is its own observed slot (`ChatPinSlot`); `ChatScrollController.position` is written only through `write(_:)`; list data is built once per model change (`LibraryModel.macItems`) | lint `perf-screen-reads-draft`, `perf-screen-reads-stream`, `perf-unguarded-scroll-write`, `perf-foreach-regroup`; test `ChatScrollControllerTests` |
| K. Layout, frames, text | `MacShellLayout` never probes subviews unconstrained or in `sizeThatFits`; decoded frames use `ComputerFrameSink`/`layer.contents`, never an observed property or `draw(_:)`; TextKit and measuring live in `SelectableTextLayout`, off the main actor (`SelectableSizeCache`) | lint `perf-shell-layout-probe`, `perf-observed-frame-image`, `perf-frame-cpu-draw`, `perf-textkit-outside-layout`, `perf-textview-scroll`; test `SelectableTextSizingTests` |
| G. Expensive static effects | `shadow` radius under 24; no interactive `palGlass` over an opaque `.background(` | lint `perf-shadow-radius`, `perf-glass-over-fill` |
| B. Observable model written without an equality guard | `assignIfChanged` or `RosterSnapshotChange`; no direct assignment of the `RosterModel` and `ChatModel` fields in `GUARDED_WRITE_FIELDS` | lints `perf-unguarded-write`, `perf-dropped-value` (unused `publish`/`apply` result); tests `RosterApplyGuardTests`, `ChatModelRebuildGuardTests` |
| D. Work per event instead of per frame | snapshots coalesce in `TimelinePacer.consume` and pass `ChatOpenGate`; a streamed delta patches the tail row, not all rows | lint `perf-open-ungated`; call-count tests `TimelinePacerTests`, `ChatModelRebuildTests` |
| H. Resource lifetimes | every `NSEvent` monitor has a paired removal; per-request sleeping Tasks cancelled (`GatewayConnection`) | lint `perf-monitor-unpaired` |
| T. Tests | count on a cache the test owns, not a shared one | lint `perf-test-shared-counter` |

## Tests

- `swift test` in `apps/ios/Packages/PalKit` covers `ConnectedServices` and the source scan.
- UI tests pass `-hermes-record-external-links` (links are recorded, not opened; read `externalLinkProbe`) and `-hermes-test-connected-services slack` (see `BotProfileSupport.signedInApp`).

## Learned

- Mac UI tests: real Keychain, serial, fake creds; update: xcodegen, Release→/Applications, devicectl
- Mac/iOS parity+shared code; no streamed text (avatar+step+dots); Liquid Glass ToolbarItems; pinned bots top; no other brands; bot Qs never expire; NO_REPLY-type markers never shown/flashed anywhere
- Avatars: 15 blobs (heart = primary bot, 🩷 #E05CAC), 1:1:1 3D, unlit; black eyes (white→gray in light); body turns to pointer with eyes (no eyes-only/1-eye anims), upright on hover; rest eyes up-right, slanted; review render pre-build
- T3 Code = catalog connector `t3code` (no bridge): Network on, plain-http tailnet `<ip>:<port>/mcp`, OAuth DCR+PKCE, no refresh; wizard `T3CodeFlow` (PalConnect), Mac prefill `T3AddressSuggestion`
- Google Ads = catalog `google-ads` (oauth_client + stdio `google-ads-mcp`, read-only), reuses the Workspace client, adwords scope only; wizard `GoogleAdsFlow` (PalConnect), RPC `connectors.google_ads.status|save|verify`; Explorer refusal = `explorer_access_needed`
- Pal builds: pull main first
- iPhone screenshot (physical device): `pymobiledevice3 developer dvt screenshot <out.png>`
- Push: Pi APNs key DDRHGPZC24 sandbox-only, topic dev.tsnanh.pal (key limit hit); TestFlight/App Store need a separate prod key. Env from signature (`SignedPushEnvironment`); gateway: `hermes pm install --extra apns`
- swift-lint baseline (`.swiftlint-baseline.json`) matches messages incl. counts: growing an already-oversized file/type re-fails it; offset lines, never re-baseline

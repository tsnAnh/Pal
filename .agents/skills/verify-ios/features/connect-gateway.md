# Connect to a gateway

A user enters the address of their Hermes gateway, signs in through the system web authentication sheet, and lands on the bot roster. Settings then shows the connection status and the gateway instance ID, and lets the user sign out.

## Sub-features

- `connect-signin` signs in against a gateway address through the web auth session.
- `connect-status` shows `Connected` and a non-empty instance ID in settings.
- `connect-signout` signs out and returns to the sign-in form.
- `connect-error` shows an error message for an unreachable or rejected address.

## How to get to it (user POV)

- Launch the app signed out. The `Hermes address` form shows with a text field and a `Sign in` button.
- After signing in, tap the account avatar at the top left of the roster to open settings.
- In settings, `Sign out` appears while connected.

## Driving it with verify-ios

Preconditions:

- `$S/doctor` is all `PASS`. The backend is the sandbox gateway from `$S/launch`.
- No human step is needed. The tests type the sandbox credentials into the gateway's web login page and accept the SpringBoard consent alert.

- **Sign in and check status** (`connect-signin`, `connect-status`). Run `$S/drive --label connect-gateway SignInFlowTests`. The test launches with `-hermes-reset-credentials`, types the base URL into `baseURLField`, taps `signInButton`, accepts the `Continue` consent alert, fills the web form, waits for `rosterScreen`, opens `userAvatarButton`, and asserts `statusLabel` reads `Connected` and `instanceIDLabel` is non-empty. Result: `verdict=PASS passed=1`.
- **Proof.** Open `shots/` and `run.mov` in the drive's evidence dir. Also run `$S/snap settings-connected` only if you drive manually. `gateway.log` shows the login and the app's connection. `app-os-log.txt` shows the app's auth events.
- **Sign out** (`connect-signout`). No shipped test taps `signOutButton`. To prove it, add a test to `apps/ios/UITests/SignInFlowTests.swift` that taps `userAvatarButton`, then `signOutButton`, and asserts `statusLabel` reads `Not signed in` and `baseURLField` exists. Until then this sub-feature is unverified.
- **Error state** (`connect-error`). No shipped test types a bad address. A new test would type `http://127.0.0.1:1`, tap `signInButton`, and assert `errorLabel` exists. Unverified until added.

## Gotchas

- `signInIfNeeded` returns early when `rosterScreen` already exists, so a test that must prove sign-in launches with `-hermes-reset-credentials` (the `resetCredentials: true` helper argument).
- The consent alert belongs to SpringBoard (`com.apple.springboard`), not the app. Query it through `XCUIApplication(bundleIdentifier:)`.
- The web form is a `webViews` element. The password field may need the keyboard `Done` button dismissed before the Sign in button is hittable.
- The gateway's public URL setting is a fake hostname; the app connects to `http://127.0.0.1:<port>` from `HERMES_UITEST_BASE_URL`. A different base URL in the field is a different test.
- The xcresult from this feature contains the typed sandbox password. It is valid only for the sandbox gateway that `cleanup` destroys.

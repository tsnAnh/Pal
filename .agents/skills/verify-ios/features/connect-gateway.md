# Connect to a gateway

A signed-out user sees the Pal landing, connects to their Hermes gateway through the system web authentication sheet, and lands on the bot roster. Settings shows the signed-in account and gateway host, and lets the user sign out or add another account.

## Sub-features

- `connect-signin` signs in against a gateway address through the web auth session and lands on the roster.
- `connect-account` shows the signed-in account in Settings, with the gateway host on the account row.
- `connect-signout` asks `Sign out of Pal on this device?` in Settings and returns to the landing only after the user confirms. Needs the parity seed to drive.
- `connect-add-account` offers Add Account, which warns that another account replaces this one and only signs out after `Continue`. Needs the parity seed to drive.
- `connect-error` shows `Could not reach Hermes.` (and the other sign-in messages) on the landing (`signInErrorMessage`) or in the options sheet (`errorLabel`). No shipped UI test.
- `connect-restore` reconnects from the saved keychain session on launch, and shows `Your session expired. Sign in again.` when the session is no longer valid. No shipped UI test.
- `connect-status` (a `Connected` row and the gateway instance ID) is unreachable on iOS while signed in. `ConnectionForm` (`statusLabel`, `instanceIDLabel`, `signOutButton`) renders only inside the options sheet, which `ConnectionView.swift` presents only while not connected, and Settings has no such row. Do not claim it.

## How to get to it (user POV)

- Launch the app signed out. The landing shows `Pal`, a `Connect to your Hermes` button (it reads `Continue to <host>` once an address is saved) and an `Other options` link.
- `Other options` opens the `Sign in` sheet with the `Hermes address` field and a `Sign in` button.
- After signing in, tap the avatar at the top left of the roster to open Settings. The account row names the gateway host; `Sign Out` sits further down the list.

## Driving it with verify-ios

Preconditions:

- `$S/doctor` is all `PASS`. The backend is the sandbox gateway from `$S/launch`.
- No human step is needed. The tests type the base URL, accept the SpringBoard consent alert and fill the gateway's web login page with the sandbox credentials.

- **Sign in and see the account** (`connect-signin`, `connect-account`). Run `$S/drive --label connect-gateway SignInFlowTests/testNativeSignInThroughWebAuthenticationSession`. The test launches with `-hermes-reset-credentials`, opens `otherOptionsButton` if `baseURLField` is not showing, types the base URL, taps `signInButton`, accepts the `Continue` consent alert, fills the web form, waits for `rosterScreen`, opens `userAvatarButton`, waits for `settingsSheet` and asserts `settingsAccountRow` contains the gateway host. Result: `verdict=PASS passed=1`; `signed-in-settings.png`.
- **Sign out and add account** (`connect-signout`, `connect-add-account`). Launch with `VERIFY_IOS_SEED=parity` and run `$S/drive --label connect-account SettingsE2ETests/test12AccountShowsTheSignedInAccountAndGuardsSwitching SettingsE2ETests/test13SignOutAsksFirstThenReturnsToSignIn`. Test 12 opens `accountScreen`, sees `accountCurrentRow`, taps `accountAddRow`, sees the `Continue` confirmation, dismisses it and is still signed in. Test 13 taps `settingsSignOutRow`, sees the `Sign Out` confirmation, dismisses it, taps again, confirms and waits for `continueButton` (the landing).
- **Error state** (`connect-error`). No shipped test types a bad address. A new test would open `otherOptionsButton`, type `http://127.0.0.1:1` into `baseURLField`, tap `signInButton` and assert `errorLabel` (sheet) or `signInErrorMessage` (landing). Unverified until added.
- **Proof.** Open `shots/` and `run.mov` in the drive's evidence dir. `gateway.log` shows the login and the app's connection. `app-os-log.txt` shows the app's auth events.

## Gotchas

- `signInIfNeeded` returns early when `rosterScreen` already exists, so a test that must prove sign-in launches with `-hermes-reset-credentials` (the `resetCredentials: true` helper argument).
- The consent alert belongs to SpringBoard (`com.apple.springboard`), not the app. Query it through `XCUIApplication(bundleIdentifier:)`.
- The web form is a `webViews` element. The password field may need the keyboard `Done` button dismissed before the Sign in button is hittable.
- The gateway's public URL setting is a fake hostname; the app connects to `http://127.0.0.1:<port>` from `HERMES_UITEST_BASE_URL`. A different base URL in the field is a different test.
- The macOS-only `testWrongPasswordIsRejectedWithoutSigningIn` never runs on iOS; `test-lanes` skips it.
- The xcresult from this feature contains the typed sandbox password. It is valid only for the sandbox gateway that `cleanup` destroys.

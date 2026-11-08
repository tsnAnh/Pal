# Bot avatar loading

While a bot is working or thinking, its roster face plays short eye animations: about twenty clips (spin, nod, shake, peek, bounce, dizzy and more) in a random order that never repeats a clip back to back, the same clips and order logic as the iOS app. When the turn ends the eyes settle back over about 0.4 s to the exact resting face. On the light theme a white bot is drawn dark with light eyes so it stays visible.

## Sub-features

- `loading-clips` a working bot's eyes (and sometimes its body) move through the shared clips on every face kind: blob, legacy math shape and sigil.
- `loading-order` clips follow one another without a visible jump, in a per-session random order.
- `loading-settle` when the turn ends the eyes blend back over 0.4 s and end exactly on the static render.
- `loading-gaze-yield` pointer gaze does not move the eyes of a working bot, and resumes once it is idle.
- `loading-reduced-motion` under reduced motion the face pulses its opacity instead of moving.
- `white-tone` a white bot (luminance 230 or more) is marked `data-hb-tone="white"` and drawn near-black with light eyes on the light theme, unchanged on the dark theme.

## How to get to it (user POV)

- Open the `Bots` tab and send a message to a bot. While its turn runs, its roster row face is in the `think` mood. A bot with a live delegated worker shows `work`.
- Switch the app between light and dark themes to see a white bot's tone.

## Driving it with Playwright Electron

Preconditions:

- Bots seeded under `<HERMES_HOME>/profiles/<name>` with `writeMockProviderConfig`, `writeEnvFile` and one `RealSessionBuilder` session each. A bot's look is seeded in its `profile.yaml` under `ui_meta.hermes-bots` (`color`, `shape`, `custom`).
- One mock server per bot started with `holdBeforeFirstTokenForPrompt: 'E2E_PENDING_PROBE'`, so the turn stays busy until `releaseHeldStream()`.
- `page.emulateMedia({ reducedMotion: 'no-preference' })` has run. `colorScheme` selects the theme because the app follows the system.

- **Start a turn.** Click `Bots`, click the bot row, wait for `Hello <name>`, type `E2E_PENDING_PROBE` into the bot chat editor and press Enter. `mock.waitForHeldStream()` resolves while the turn is busy.
- **Loading.** The row's `svg[data-bot-face]` gets `data-hb-mood="think"` and `data-hb-motion`. Each `[data-hb-eye]` carries a `matrix(...)` transform and its `path` a projected outline that changes every frame. `style.transform` and `style.opacity` on the svg carry the body pose.
- **Settle.** Release the held stream. The mood returns to `idle`, `data-hb-motion` disappears, every eye `transform` equals its `data-hb-rest` again and every `path` `d` equals the pre-turn string.
- **White tone.** With a white bot in the roster, switch `colorScheme` and read `getComputedStyle` fill of `[data-hb-body]`, `[data-hb-eye] path` and `[data-hb-dot]`.
- **Proof.** Run `scripts/verify bot-avatar-loading`. Evidence folder `bot-avatar-loading/` holds per bot `strip.png` (about twenty frames over three seconds, three times enlarged), the raw `frames/`, `trace.json` (every animation frame of 24 s of eye outlines, body transform, opacity and dots), `loading.json` with the counted distinct poses, and `white-tone/` with row screenshots, live face markup and the computed colours for both themes.

## Gotchas

- Only the first held stream of a mock server is held, so each bot needs its own mock server for its own turn.
- Roster rows show `think` only for the bot whose chat is focused and busy. Other bots stay idle.
- Frames are captured with `page.screenshot({ clip })`, not `locator.screenshot`, because the face moves and a locator screenshot waits for it to stand still.
- The roster face is about 36 px wide. The strip is the readable proof, `trace.json` the precise one.
- Blink is off while loading: the clips own `eyeOpen`.

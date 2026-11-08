# Bot avatar gaze

When the pointer moves over a bot's roster row or tile, the bot's face wakes up: its eyes stand upright, spread a little, and turn toward the pointer as if painted on a ball. Each eye's outline is projected onto the sphere, so the leading eye narrows into a bowed crescent toward the edge and the other widens on its outer side. When the pointer leaves, the eyes ease back to their exact resting pose.

## Sub-features

- `gaze-attend` eyes stand upright and re-centre while the pointer is in the row.
- `gaze-sphere-x` looking sideways curves and narrows the leading eye and moves the pair along an arc.
- `gaze-sphere-y` looking up or down shortens both eyes.
- `gaze-rest` leaving the row restores the baked eye transform exactly.
- `gaze-reduced-motion` under reduced motion the eyes never move.

## How to get to it (user POV)

- Open the `Bots` tab and hover any bot row in the roster list.
- Hover a bot tile in the pinned strip at the top of the roster.
- Hover a bot in the cron schedule view (it has a gaze scope too).

## Driving it with Playwright Electron

Preconditions:

- A bot profile `alpha` exists with one stored session. `journeys/bot-avatar-gaze.spec.ts` seeds it with `seedBot`.
- `page.emulateMedia({ reducedMotion: 'no-preference' })` has run.

- **Open roster.** Click the `Bots` button or tab (`getByRole('button' | 'tab', { name: 'Bots', exact: true })`). Row `[data-slot="bots-roster"] [data-roster-key="local::alpha"]` becomes visible.
- **Idle.** Park the pointer outside the row. Each `[data-hb-eye]` inside `svg[data-bot-face]` has `transform` equal to its `data-hb-rest`.
- **Look right.** Move the pointer to the row's right edge at the face's height. After about 0.9 s each eye group holds a `path[data-hb-eye-curve]` (its `rect` is `visibility="hidden"`), the right eye's path is less than 0.85 of the left eye's width, and both translate x values exceed the rest values.
- **Look left.** Move the pointer to the row's left edge. The left eye's path is less than 0.85 of the right eye's width and the pair moves left.
- **Leave.** Move the pointer well below the row. Within 5 s every eye's `transform` equals its `data-hb-rest` again and no `path[data-hb-eye-curve]` remains.
- **Proof.** Run `scripts/verify bot-avatar-gaze`. Evidence folder `bot-avatar-gaze/` holds `0N-*-row.png`, `0N-*-face.svg` (the live face markup per phase, openable in a browser) and `eyes.json` with every transform, curved path and its width.

## Gotchas

- The roster face is about 36 px wide, so a row screenshot shows the squash only faintly. The `*-face.svg` files and `eyes.json` are the precise proof.
- Gaze runs only while the pointer is inside an element with `data-bot-gaze-scope`. Moving outside the row ends attention even if the face is still on screen.
- The `apps/desktop/e2e` Playwright config forces reduced motion, so a gaze check copied into that suite sees no motion unless it calls `emulateMedia`.
- A working bot's eyes belong to the loading clips (`features/bot-avatar-loading.md`): gaze yields while `data-hb-mood` is `think` or `work`, or `data-hb-motion` is set, and resumes once the face is idle.

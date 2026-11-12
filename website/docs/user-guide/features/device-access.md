---
sidebar_position: 12
title: "Device access"
description: "How a bot lists your logged-in devices and acts on the one you name"
---

# Device access

Every bot can see the devices you are logged in on (the Mac and iPhone apps) and act on one when you name it. Without a device in your message a bot works on its own host, as always.

## How a bot picks a device

1. Call `devices_list`. It returns every device of your profile, offline ones too, with `name`, `type` (Mac, iPhone, other), `status` (online or offline), `last_seen`, and `capabilities` (what the device can do and whether each runs without asking).
2. Pass `device` to the `device` tool **only when your message names one** ("run this on my Mac", "set a reminder on Sam's iPhone"). Copy the name from your words; the bot never chooses a device itself.
3. If you say "my phone" and several devices fit, the bot asks which one. A name that matches more than one device fails and lists them (with online or offline and when each was last seen), and a name that matches none fails and lists the available devices. Exact names match ignoring case; a `device_id` from `devices_list` always matches exactly one.
4. A device that is offline fails at once with `<name> is offline, last seen <time>`. Nothing is queued: a command held back and run hours later would be unsafe. Try again when the device is back.
5. If a device drops while an action runs, the result is a failure that says the outcome is unknown. For `shell.run` and `files.write` the bot checks before repeating.

## Actions

| Where | Actions |
|---|---|
| Mac or iPhone | `calendar.*`, `reminders.*`, `contacts.search`, `location.*`, `alarms.*`, `timers.start`, `home.*` |
| Mac only | `shell.run` (command, cwd, timeout_seconds), `files.read`, `files.list`, `files.write` (path, content) |
| Mac only | `input.displays`, `input.move`, `input.click`, `input.drag`, `input.scroll`, `input.type`, `input.key` (mouse and keyboard) |
| Mac only | `clipboard.read` (include_image), `clipboard.write` (text or image_base64) |
| Mac only | `apps.list`, `apps.open` (app by name or bundle id, optional `target` file path or web link), `apps.quit` (asks the app to quit normally, never force-quits), `windows.list`, `windows.focus` (window_id or app) |
| Mac only | `screen.capture` (display, read_text), `screen.read` (display) |
| Mac only | `notify.post` (title, body, subtitle, sound, identifier), `notify.cancel` (identifier) |

Output is capped at 128 KB; longer output is cut with a `[truncated, N characters omitted]` marker and `truncated: true`. Screen results are capped separately: a JPEG of at most 300 KB (long edge 1568 px) plus at most 24,000 characters of recognized text. An iPhone asked for `shell.*`, `files.*`, `clipboard.*`, `apps.*`, `windows.*`, `notify.*` or `screen.*` answers `unsupported`, and so does a Mac app that predates them.

Clipboard reads return at most 23 KB of text (cut with `truncated: true`) and an image only when `include_image` is set and it is at most 48 KB; `types` lists what the clipboard holds (`text`, `image`, `file_urls`). Items an app marked concealed or transient (password managers) come back as `concealed: true` with no content. Clipboard writes take up to 100,000 characters of text or a PNG/JPEG of at most 48 KB and are marked auto-generated so clipboard managers can skip them.

`apps.list` and `windows.list` return at most 200 entries (`truncated: true` when more exist). `windows.list` always returns the app, window id, frame and whether the window is on screen; titles are included only when macOS has given Pal Screen Recording access, otherwise `titles_available` is false and a note says so. `windows.focus` raises one window when Pal has Accessibility access and otherwise brings the app to the front and says so in `note`.

## Who stays in control

- **Notifications** need no switch (macOS asks for permission the first time one is shown). A bot can show text on that screen, labelled with its name and "via Pal", and remove only the notifications it posted. Title 80, subtitle 80 and body 240 characters; five a minute per bot and ten a minute per Mac; no sound unless the bot asks, no buttons, no links. A bot cannot read or list any notification.
- **Commands, Files, Clipboard, Apps and Screen are always on** for every Mac logged in to your profile. There is no per-device switch, and a switch stored by an older app is ignored (nothing is rewritten; an older app still lists these as on and cannot turn them off). Your own chats and every bot of yours, including bots acting for another of your bots, run those actions with no prompt per action. macOS asks for Screen Recording and Accessibility the first time Apps or Screen needs them; until you allow it the bot gets a permission error naming the capability. The clipboard often holds passwords and private text; its content is untrusted data and is never logged. A bot that can see the screen sees everything on it, including passwords and private messages. Pal shows "A bot is looking at your screen" while a capture runs, allows one capture at a time per device and at most one every 3 seconds, keeps screenshots in memory only (no temp files), and never logs them.
- Apple connectors keep their existing state: `ask` still shows the device's consent prompt and the approval card for changes, `allowed` runs without prompting.
- A bot reaches only devices logged in to the profile it runs in. Other profiles and other installs are invisible to it: they are not listed and an action naming them fails as an unknown device.
- There is no screen capture.

## Mouse and keyboard (Mac only)

Mouse and keyboard control needs no switch; macOS asks for the Accessibility permission the first time it is used, and until you allow it the bot gets a permission error. A bot can click and type anywhere on that Mac with no prompt per action, including approving payments, sending messages and deleting files.

- **Coordinates** are screen points, origin at the top-left of the main display, y growing downward. A secondary display can have negative x or y. `input.displays` returns each display's id, origin, size in points and scale (multiply by scale for screenshot pixels) and the pointer position. Pass `display` to give x and y relative to that display.
- **Limits:** at most 60 input calls a minute per Mac; `input.type` at most 500 characters; `input.scroll` at most 50 lines; at least 8 ms between events.
- **Stop at once:** press Escape three times within 1.5 seconds, or choose Stop in the Pal menu bar item. In-flight input is cancelled and bots get a stopped error until you resume mouse and keyboard in the Mac app. While a bot is controlling the Mac, the menu bar item says so, and stays for 5 seconds after.
- **Refusals:** a password field (secure input), a locked screen or login window, and Pal's own windows are never controlled; the result says so and the bot must not retry.
- There is no screen control (no clicks or typing); the Screen connector above only looks.

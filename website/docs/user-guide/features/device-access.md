---
sidebar_position: 12
title: "Device access"
description: "How a bot lists your logged-in devices and acts on the one you name"
---

# Device access

Every bot can see the devices you are logged in on (the Mac and iPhone apps) and act on one when you name it. Without a device in your message a bot works on its own host, as always.

## How a bot picks a device

1. Call `devices_list`. It returns every device of your profile, offline ones too, with `name`, `type` (Mac, iPhone, other), `status` (online or offline), `last_seen`, and `capabilities` (the connectors switched on and whether each runs without asking).
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

Output is capped at 128 KB; longer output is cut with a `[truncated, N characters omitted]` marker and `truncated: true`. An iPhone asked for `shell.*` or `files.*` answers `unsupported`.

## Who stays in control

- **Commands and Files are off by default** on every Mac. Only the person using that Mac switches them on, in the Hermes app's connector settings on that Mac (another device cannot switch them on for it). Once on, bots run those actions with no prompt per action; switching them off stops it at once.
- Apple connectors keep their existing state: `ask` still shows the device's consent prompt and the approval card for changes, `allowed` runs without prompting.
- A bot reaches only devices logged in to the profile it runs in. Other profiles and other installs are invisible to it: they are not listed and an action naming them fails as an unknown device.
- There is no screen capture.

## Mouse and keyboard (Mac only)

The "Mouse and keyboard" connector is off by default and is switched on only in the Mac app, which then asks macOS for the Accessibility permission. A bot can then click and type anywhere on that Mac with no prompt per action, including approving payments, sending messages and deleting files.

- **Coordinates** are screen points, origin at the top-left of the main display, y growing downward. A secondary display can have negative x or y. `input.displays` returns each display's id, origin, size in points and scale (multiply by scale for screenshot pixels) and the pointer position. Pass `display` to give x and y relative to that display.
- **Limits:** at most 60 input calls a minute per Mac; `input.type` at most 500 characters; `input.scroll` at most 50 lines; at least 8 ms between events.
- **Stop at once:** press Escape three times within 1.5 seconds, or choose Stop in the Pal menu bar item, or turn the switch off. In-flight input is cancelled and the switch goes off until you turn it on again. While a bot is controlling the Mac, the menu bar item says so, and stays for 5 seconds after.
- **Refusals:** a password field (secure input), a locked screen or login window, and Pal's own windows are never controlled; the result says so and the bot must not retry.

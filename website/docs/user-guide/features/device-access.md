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
| Mac only | `shell.run` (command, cwd, timeout_seconds), `files.read`, `files.list`, `files.write` (path, content), `screen.capture` (display, read_text), `screen.read` (display) |

Output is capped at 128 KB; longer output is cut with a `[truncated, N characters omitted]` marker and `truncated: true`. Screen results are capped separately: a JPEG of at most 300 KB (long edge 1568 px) plus at most 24,000 characters of recognized text. An iPhone asked for `shell.*`, `files.*` or `screen.*` answers `unsupported`.

## Who stays in control

- **Commands, Files and Screen are off by default** on every Mac. Only the person using that Mac switches them on, in the Hermes app's connector settings on that Mac (another device cannot switch them on for it). Once on, bots run those actions with no prompt per action; switching them off stops it at once. Screen ("Let bots see this Mac's screen") also needs the macOS Screen Recording permission, which Pal asks for only when that switch is turned on; a bot can then see everything on screen, including passwords and private messages. Pal shows "A bot is looking at your screen" while a capture runs, allows one capture at a time per device and at most one every 3 seconds, keeps screenshots in memory only (no temp files), and never logs them.
- Apple connectors keep their existing state: `ask` still shows the device's consent prompt and the approval card for changes, `allowed` runs without prompting.
- A bot reaches only devices logged in to the profile it runs in. Other profiles and other installs are invisible to it: they are not listed and an action naming them fails as an unknown device.
- There is no screen capture and no screen control.

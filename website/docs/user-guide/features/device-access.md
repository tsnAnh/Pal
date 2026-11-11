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
5. If a device drops while an action runs, the result is a failure that says the outcome is unknown. For `shell.run`, `files.write` and browser clicks or typing the bot checks before repeating.

## Actions

| Where | Actions |
|---|---|
| Mac or iPhone | `calendar.*`, `reminders.*`, `contacts.search`, `location.*`, `alarms.*`, `timers.start`, `home.*` |
| Mac only | `shell.run` (command, cwd, timeout_seconds), `files.read`, `files.list`, `files.write` (path, content) |
| Mac only | `browser.open` (url), `browser.read`, `browser.click` (selector or text), `browser.type` (selector, text, submit), `browser.wait_for_text` (text, timeout_seconds), `browser.close` |

Output is capped at 128 KB; longer output is cut with a `[truncated, N characters omitted]` marker and `truncated: true`. An iPhone asked for `shell.*`, `files.*` or `browser.*` answers `unsupported`.

## Browsing on your own machine

Use this when a page needs your login or a few clicks and you do not want to hand the bot a password. Say which device: "open my bank's statements page on my Mac". The bot calls `device` with that device and `browser.open`, then reads and clicks from there.

- **It uses your own browser.** The Mac app opens a separate window in your default browser (Safari, Chrome, Brave, Edge, Arc or Vivaldi), so the sites you are already signed in to just work. The bot never sees or stores your credentials, and it never reads the credential vault for this.
- **Only that window.** The bot can drive the window it opened and nothing else: no other app, no other tab, no screen capture and no screenshots. It reads the page as text.
- **Passwords stay with you.** Typing into a password or one-time-code field is refused. If a page shows a login form the bot stops and Pal shows its "sign in" dialog for that site, with the page open in the browser window on that device. Sign in there yourself, then confirm; the bot reads the page once more. It never retries a second time.
- **Which addresses.** Only `http` and `https` pages open. `file://`, `chrome://`, `about:` and other internal schemes, private and internal network addresses, cloud metadata addresses and addresses the website policy blocks are refused before anything reaches your Mac, and again if a page redirects there. The same policy as the bot's own browser applies.
- **Setup, once per Mac.** In Pal's connector settings on that Mac switch on **Browser** (it is off by default, with a warning). The first use asks macOS for permission to control your browser: allow it. Then turn on your browser's own switch for scripts from Apple Events: Safari, Settings > Advanced > Show features for web developers, then Develop > Developer Settings > Allow JavaScript from Apple Events; Chrome, Brave, Edge, Arc and Vivaldi, View > Developer > Allow JavaScript from Apple Events. Pal never changes either setting for you.
- **Limits.** Firefox cannot be driven this way; make a supported browser your default. Another sign-in already open in that browser profile is used as is.

## Who stays in control

- **Commands, Files and Browser are off by default** on every Mac. Only the person using that Mac switches them on, in the Hermes app's connector settings on that Mac (another device cannot switch them on for it). Once on, bots run those actions with no prompt per action; switching them off stops it at once.
- Apple connectors keep their existing state: `ask` still shows the device's consent prompt and the approval card for changes, `allowed` runs without prompting.
- A bot reaches only devices logged in to the profile it runs in. Other profiles and other installs are invisible to it: they are not listed and an action naming them fails as an unknown device.
- There is no screen capture and no screen control. The browser connector acts only inside the window it opens.

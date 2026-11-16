---
name: himalaya
description: "Himalaya CLI: IMAP/SMTP email from terminal."
version: 1.2.0
author: community
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [Email, IMAP, SMTP, CLI, Communication]
    homepage: https://github.com/pimalaya/himalaya
prerequisites:
  commands: [himalaya]
required_environment_variables:
  - name: HIMALAYA_PASSWORD
    prompt: Mailbox app password
    help: "Gmail, iCloud and Outlook need an app password created in the account's security settings, not the normal sign-in password"
    required_for: "reading and sending mail"
---

# Himalaya Email CLI

Himalaya is a CLI email client that lets you manage emails from the terminal using IMAP, JMAP, SMTP and other backends. This skill documents Himalaya v2; v1 flags and config keys do not work.

This skill is separate from the Hermes Email gateway adapter. The gateway
adapter lets people email the agent and uses Hermes' built-in IMAP/SMTP
adapter; this skill lets the agent operate a mailbox from terminal tools and
requires the external `himalaya` CLI.

## References

- `references/configuration.md` (config file setup + IMAP/SMTP authentication, written for v1)
- `references/message-composition.md` (MML syntax for composing emails)

## Prerequisites

1. Himalaya v2 installed (`himalaya --version` to verify)
2. A configuration file at `~/.config/himalaya/config.toml`
3. `HIMALAYA_PASSWORD` set; loading this skill asks the owner for it in a masked prompt. Never ask for the password in chat, never write it to a file or a command line.

### Installation

```bash
# Pre-built binary (Linux/macOS — recommended)
curl -sSL https://raw.githubusercontent.com/pimalaya/himalaya/master/install.sh | PREFIX=~/.local sh

# macOS via Homebrew
brew install himalaya

# Or via cargo (any platform with Rust)
cargo install himalaya --locked
```

## Configuration Setup

Ask the owner for the address, IMAP and SMTP hosts and ports (none of these is secret), then write
`~/.config/himalaya/config.toml` with the file tool. The password is never in the file: the `command`
below reads `HIMALAYA_PASSWORD` from the environment the skill's masked prompt filled. Do not run
`himalaya configure` or `himalaya account configure`.

```toml
[accounts.personal]
default = true
email = "you@example.com"
display-name = "Your Name"

imap.server = "imaps://imap.example.com:993"
imap.sasl.plain.username = "you@example.com"
imap.sasl.plain.password.command = "printenv HIMALAYA_PASSWORD"

smtp.server = "smtp://smtp.example.com:587"
smtp.starttls = true
smtp.sasl.plain.username = "you@example.com"
smtp.sasl.plain.password.command = "printenv HIMALAYA_PASSWORD"

mailbox.alias.inbox = "INBOX"
mailbox.alias.sent = "Sent"
mailbox.alias.drafts = "Drafts"
mailbox.alias.trash = "Trash"
```

`mailbox.alias.*` is required whenever the server's mailbox names differ from himalaya's roles
(inbox, sent, drafts, trash). On Gmail, sent is `[Gmail]/Sent Mail`. If saving to Sent fails after SMTP
delivery succeeds, `himalaya message send` exits non-zero: do not re-run the send, or the recipient
gets duplicates.

## Hermes Integration Notes

- **Reading, listing, searching, moving, deleting** all work directly through the terminal tool
- **Composing/replying/forwarding** use flags (`--to`, `--subject`, `--body` or `--body-file`) with `--send`, or pipe a finished RFC 5322 message to `himalaya message send`. Without `--send` the draft is not sent
- Add `--json` for structured output that is easier to parse
- A missing or rejected password opens the masked password prompt again on its own; do not retry the command or ask for the password in chat

## Common Operations

### List Mailboxes

```bash
himalaya mailbox list
```

### List Emails

List emails in the inbox (default):

```bash
himalaya envelope list
```

List emails in a specific mailbox, with pagination:

```bash
himalaya envelope list --mailbox "Sent" --page 1 --page-size 20
```

### Search Emails

```bash
himalaya envelope search from john@example.com and subject meeting
```

### Read an Email

```bash
himalaya message read 42
himalaya message read 42 --raw
```

### Reply to an Email

```bash
himalaya message reply 42 --body "Your reply here." --send
```

### Forward an Email

```bash
himalaya message forward 42 --to newrecipient@example.com --send
```

### Write a New Email

```bash
himalaya message compose --to recipient@example.com --subject "Test Message" --body "Hello from Himalaya!" --send
```

Or pipe a finished message:

```bash
printf 'From: you@example.com\nTo: recipient@example.com\nSubject: Test Message\n\nHello from Himalaya!\n' | himalaya message send
```

### Move/Copy Emails

```bash
himalaya message move --to "Archive" 42
himalaya message copy --to "Important" 42
```

### Delete an Email

```bash
himalaya message delete 42
```

### Manage Flags

```bash
himalaya flag add --flag seen 42
himalaya flag remove --flag seen 42
```

## Multiple Accounts

```bash
himalaya account list
himalaya --account work envelope list
```

## Attachments

```bash
himalaya attachment download 42
himalaya attachment download 42 --dir ~/Downloads
```

## Debugging

```bash
himalaya --log-level debug envelope list
```

## Tips

- Use `himalaya --help` or `himalaya <command> --help` for detailed usage.
- Message IDs are relative to the current mailbox; re-list after switching mailboxes.
- Attach files with `--attach <PATH>`.

# Himalaya Configuration Reference

Configuration file location: `~/.config/himalaya/config.toml` (Himalaya v2).

Never write the password into this file or into a command line. Every secret is a `command` that reads
`HIMALAYA_PASSWORD` from the environment, which the skill's masked prompt fills.

## Minimal IMAP + SMTP Setup

```toml
[accounts.default]
default = true
email = "user@example.com"
display-name = "Your Name"

imap.server = "imaps://imap.example.com:993"
imap.sasl.plain.username = "user@example.com"
imap.sasl.plain.password.command = "printenv HIMALAYA_PASSWORD"

smtp.server = "smtp://smtp.example.com:587"
smtp.starttls = true
smtp.sasl.plain.username = "user@example.com"
smtp.sasl.plain.password.command = "printenv HIMALAYA_PASSWORD"

mailbox.alias.inbox = "INBOX"
mailbox.alias.sent = "Sent"
mailbox.alias.drafts = "Drafts"
mailbox.alias.trash = "Trash"
```

`imaps://` is implicit TLS, `smtp://` with `smtp.starttls = true` upgrades with STARTTLS, and
`smtps://host:465` is implicit TLS. A bare `host` or `host:port` means implicit TLS.

## Passwords

Use only the command form:

```toml
imap.sasl.plain.password.command = "printenv HIMALAYA_PASSWORD"
```

Do not use `password.raw`, which keeps the password in the file, and do not run `himalaya configure`.
Himalaya v2 has no keyring or `auth.type` keys.

## Gmail Configuration

```toml
[accounts.gmail]
default = true
email = "you@gmail.com"
display-name = "Your Name"

imap.server = "imaps://imap.gmail.com:993"
imap.sasl.plain.username = "you@gmail.com"
imap.sasl.plain.password.command = "printenv HIMALAYA_PASSWORD"

smtp.server = "smtp://smtp.gmail.com:587"
smtp.starttls = true
smtp.sasl.plain.username = "you@gmail.com"
smtp.sasl.plain.password.command = "printenv HIMALAYA_PASSWORD"

mailbox.alias.inbox = "INBOX"
mailbox.alias.sent = "[Gmail]/Sent Mail"
mailbox.alias.drafts = "[Gmail]/Drafts"
mailbox.alias.trash = "[Gmail]/Trash"
```

Without the aliases, saving to Sent fails after SMTP delivery succeeds (Gmail's sent mailbox is
`[Gmail]/Sent Mail`), and `himalaya message send` exits non-zero. Do not re-run the send: the
recipient gets duplicates.

**Note:** Gmail requires an App Password if 2FA is enabled.

## iCloud Configuration

```toml
[accounts.icloud]
default = true
email = "you@icloud.com"
display-name = "Your Name"

imap.server = "imaps://imap.mail.me.com:993"
imap.sasl.plain.username = "you@icloud.com"
imap.sasl.plain.password.command = "printenv HIMALAYA_PASSWORD"

smtp.server = "smtp://smtp.mail.me.com:587"
smtp.starttls = true
smtp.sasl.plain.username = "you@icloud.com"
smtp.sasl.plain.password.command = "printenv HIMALAYA_PASSWORD"
```

**Note:** Generate an app-specific password at appleid.apple.com

## Mailbox Aliases

Map himalaya's roles (`inbox`, `sent`, `drafts`, `trash`) to whatever the server calls them with
`mailbox.alias.<role>` directly under `[accounts.NAME]`. Alias names are case-insensitive. The `inbox`
alias is the mailbox every command uses when `--mailbox` is not passed. The v1 `folder.aliases` and
`folder.alias` keys are not read by v2.

## Multiple Accounts

```toml
[accounts.personal]
default = true
email = "personal@example.com"
# ... imap and smtp config ...

[accounts.work]
email = "work@company.com"
# ... imap and smtp config ...
```

Switch accounts with `--account`:

```bash
himalaya --account work envelope list
```

## Additional Options

```toml
[accounts.default]
signature = "Best regards,\nYour Name"
signature-delim = "-- \n"
downloads-dir = "~/Downloads/himalaya"
```

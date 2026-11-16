# Message Composition (Himalaya v2)

Himalaya v2 builds messages from command-line flags, or sends a finished RFC 5322 message. It does not
interpret MML; multipart and rich bodies belong to a separate composer (`mml`) that is not part of this
skill.

## Basic Message Structure

An email message is a list of **headers** followed by a **body**, separated by a blank line:

```
From: sender@example.com
To: recipient@example.com
Subject: Hello World

This is the message body.
```

Common headers: `From`, `To`, `Cc`, `Bcc`, `Subject`, `Reply-To`, `In-Reply-To`.

### Address Formats

```
To: user@example.com
To: John Doe <john@example.com>
To: user1@example.com, user2@example.com, "Jane" <jane@example.com>
```

## Composing from the CLI

None of these open an editor. Without `--send` the message is printed, not sent.

### New message

```bash
himalaya message compose --to recipient@example.com --subject "Quick Message" --body "Message body here" --send
himalaya message compose --to recipient@example.com --subject "Report" --body-file body.txt --attach report.pdf --send
```

Also available: `--cc`, `--bcc`, `--from`, `--signature`, `--signature-file`.

### Reply

```bash
himalaya message reply 42 --body "Thanks, got it." --send
```

### Forward

```bash
himalaya message forward 42 --to someone@example.com --send
```

### Send a finished message

From stdin:

```bash
printf 'From: you@example.com\nTo: recipient@example.com\nSubject: Hi\n\nHello.\n' | himalaya message send
```

From a file (the `--` is required before the path):

```bash
himalaya message send -- message.eml
```

Use `--save <MAILBOX>` or `--no-save` to control the copy kept after sending.

## Tips

- Use `himalaya message read 42 --raw` to inspect the raw MIME structure of received emails.
- Attach files with `--attach <PATH>`, repeated for several files.
- Use `himalaya message compose --help` for every flag.

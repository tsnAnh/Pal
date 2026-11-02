security-review: <CLEAN | FINDINGS <N> high, <N> medium, <N> low>
range: <base commit from your prompt, or none>..<the full head commit from your prompt>

## Scope
- Commits: <count>, `<base>..<head>`. Files read: <count>.
- Not reviewed: <what you could not read or run, or "nothing">

## Findings
Most severe first. One block per finding:

### (high) <title>
- Where: `<path>:<line>` in <commit>
- What an attacker does: <the concrete path from input to impact>
- Evidence: <the code, a test you ran, or the command output>
- Fix: <the smallest change that closes it>

## Checked and clear
- <category>: <what you looked at, in one line>

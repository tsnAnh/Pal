# Review bot patterns

Learned patterns for triaging comments from the Claude review bot on this repository. The pstack babysit playbook's Bugbot triage (`references/bugbot-triage.md` in the pstack plugin) defines the fix, dismiss, or ask rubric; this file holds this repository's own patterns in the same shape.

Treat each bot comment on its merits. Security, privacy, data, auth, billing, migration, and concurrency findings are never auto-dismissed.

## Pattern format

```markdown
### <short pattern name>

- Confidence: candidate | recurring | strong
- Skip when: <conditions that must be true>
- Do not skip when: <risk boundaries>
- Example signal: <phrases or code that identify the pattern>
- Source: <PR or comment link>
```

## Patterns

None yet. Add one after a second real dismissal of the same kind of comment.

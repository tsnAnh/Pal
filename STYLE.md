# STYLE.md

Rules the team enforces in review because no tool enforces them yet. Each entry names where it should move next (`Promotion`), so this file shrinks as rules become checks. Run `/correct` on an entry to promote it.

## Entry format

```markdown
### S<n>. <The rule in one sentence>

- Why: <what goes wrong without it>
- Bad: <smallest example>
- Good: <the same example done right>
- Promotion: type | lint:<rule-id> | review | skill:<name> | style-only
- Source: <PR or review comment where it came up>
```

`style-only` means the rule is a matter of judgment and stays here.

## Entries

### S1. Comments keep the why, never the what

- Why: AGENTS.md "Rules that apply everywhere" requires it, and no tool enforces it.
- Bad: `# loop over the sessions`
- Good: `# Compression rewrites past context, so the cached prefix is invalid after this point.`
- Promotion: style-only
- Source: AGENTS.md

### S2. A moved symbol takes its docs with it

- Why: internal moves leave no re-export shim, so stale paths in docs and skills mislead agents.
- Bad: moving `foo` to a sibling module and leaving `website/docs` pointing at the old path.
- Good: grep `website/docs`, `skills/` and every `AGENTS.md` for the old path in the same change.
- Promotion: review
- Source: AGENTS.md "Facade + siblings layout"

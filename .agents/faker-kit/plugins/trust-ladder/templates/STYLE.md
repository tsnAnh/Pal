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

### S1. Error messages tell the user what to do next

- Why: an error that only says what failed leaves people stuck and creates support tickets.
- Bad: "Upload failed."
- Good: "The photo is larger than 20 MB. Choose a smaller photo or crop this one."
- Promotion: review
- Source: <link>

### S2. Name booleans as questions that read true

- Why: `isNotHidden` and `flag` make every condition a double negative or a lookup.
- Bad: `val hidden = !visible`
- Good: `val isVisible = ...`
- Promotion: lint:<naming rule for your stack>
- Source: <link>

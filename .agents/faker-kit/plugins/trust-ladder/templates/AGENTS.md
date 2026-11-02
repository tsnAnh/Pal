# AGENTS.md

<One sentence: what this repository is and who uses it.>

## Commands

Run the build, test, and lint commands below before you say a change is done. They are the commands CI runs.

| Task | Command |
|---|---|
| Install dependencies | `<command>` |
| Run the app locally | `<command>` |
| Build | `<command>` |
| Run the tests | `<command>` |
| Lint | `<command>` |
| Prove a user-facing change | the `verify-<app>` skill, which drives the real app and captures evidence |

## Layout

- `<path>/`: <what lives there>.

## Boundaries

These dependency rules are enforced by the build and CI. They are listed here so you know why a check fails.

- <Layer A> may import <layer B>, never the reverse.

## Paved paths

Each concern has one blessed way. The alternatives are deleted and banned by lint.

| Concern | Use | Not |
|---|---|---|
| <Logging> | `<api>` | `<banned api>` |

## Never

- Never skip, disable, or weaken a check, test, or lint rule to get green. Fix the cause.
- Never add a comment to justify a workaround. Fix the root cause, or open a task and link it.
- Never say a change works without evidence from running it: test output, and for user-facing changes, screenshots or video from the verification skill.
- Never hand-edit generated files: <list>.
- Never commit secrets, tokens, or customer data, including in test fixtures and screenshots.

## How to work here

- Restate a bug report or request in your own words before changing code.
- Keep each pull request to one concern. Put the evidence in its description.
- Every user-facing text change updates every supported locale with a real translation.
- When you are corrected for something that could happen again, fix the mistake and add the rule to the table below. If the rule is already there and nothing enforces it, that is a repeat: in the same change, fix it at the highest level that works (architecture, then types, then a lint or CI check whose error names the fix, then a test). For mistakes that keep coming back, the owner runs `/correct`.

## Rules and what enforces them

`/correct` keeps this table. Drop a rule once its mistake can no longer happen.

| Rule | Enforced by |
|---|---|

## Review guidelines

The Claude review workflow reads this section with REVIEW.md.

- Treat the rules in REVIEW.md as the review checklist.
- Treat every rule under Blocking in REVIEW.md as P1.
- Do not comment on formatting or anything CI already enforces.
- Mark each finding `[blocking]` or `[nit]`.

# The trust ladder

You can only run many agents at once when you trust what they do unattended. That trust comes from the environment the agents work in. Every time you correct an agent, put the fix in the strongest layer that can hold it, so no agent needs the same correction again.

## The five layers, strongest first

| Layer | What holds the rule | Enforced by | Fails when |
|---|---|---|---|
| 1. Codebase | Types, module boundaries, one blessed API per concern, deleted alternatives | The compiler and the build | Never, if the bad state cannot be written |
| 2. Static analysis | Lint rules, compiler flags, CI checks, ratchets | CI on every change | Someone disables or baselines the rule |
| 3. Rules | AGENTS.md, nested AGENTS.md, `.claude/rules/` | Agents reading instructions | An agent skips the file |
| 4. Skills | Verification skills, workflow skills, playbooks | Agents choosing to load them | Nobody loads the skill |
| 5. Style guide | STYLE.md entries | Humans in review | The reviewer is busy or new |

Two rules follow from the table:

1. **Take the strongest layer that can hold the rule.** A lint rule beats an instruction because it works without anyone's cooperation. A type beats a lint rule because the bad code cannot exist.
2. **Do not also write the rule at a weaker layer.** If a lint rule enforces it, the AGENTS.md line is noise. Put the "do this instead" text in the lint message, where the agent sees it at the moment it matters.

The style guide is where rules start, not where they stay. Each STYLE.md entry names the layer it should climb to.

## Why the codebase is layer 1

Agents copy the code around them. A codebase with one clean pattern per concern teaches every agent that pattern. A codebase with a workaround teaches every agent the workaround, and it spreads within days. So the codebase is the agent's memory: keep it in a state you would be happy to see copied.

## Routing examples

| Correction | Layer | Mechanism |
|---|---|---|
| "Don't use `!!`" (Kotlin) | 2 | detekt `UnsafeCallOnNullableType` at error severity |
| "Don't force-unwrap" (Swift) | 2 | SwiftLint `force_unwrapping` as an error |
| "Don't `unwrap()` outside tests" (Rust) | 2 | `clippy::unwrap_used = "deny"` with `allow-unwrap-in-tests` |
| "Don't use `dynamic`" (Dart) | 2 | `strict-raw-types`, `strict-inference`, `avoid_dynamic_calls` |
| "No `# type: ignore` without a reason" (Python) | 2 | mypy `warn_unused_ignores` plus ruff `PGH003` |
| "UI code must not call the network" | 1, then 2 | Move networking into a data module the UI module cannot depend on; add a Konsist, import-linter, or import-boundary test so the rule survives refactors |
| "commonMain must not import Android APIs" (KMP) | 1 | expect/actual declarations; the compiler rejects platform imports in commonMain |
| "Use our `DateFormatter` wrapper, not three new helpers" | 1, then 2 | `/correct`: migrate callers, delete the helpers, ban the raw API with a lint message that names the wrapper |
| "Stop explaining workarounds in comments" | 2 | A check in the repository's own CI that fails on comments added in the diff, plus `/no-comments` before review |
| "Every user-facing string needs all locales" | 2 | A CI check that every locale file has the same keys |
| "Prove it works before saying done" | 4, then 3 | A verification skill that drives the real app (`/create-verification-skill`), and an AGENTS.md rule that PRs carry its evidence |
| "Screens must match the design system spacing" | 1, then 4 | Spacing tokens as the only public API, plus the visual-parity playbook with screenshots |
| "Our error copy should sound calm, not alarming" | 5, then 3 | STYLE.md entry with bad and good examples; once stable, a rule in AGENTS.md |

## Measuring the climb

`/correct` (pstack) keeps a table in AGENTS.md that pairs each rule with what enforces it, and a rule that nothing enforces counts as a repeat. `/check-agent-compatibility` reports how ready the repository is for agents. Read both before raising `max_in_flight` in `.agents/dispatch.json`, which the owner sets: the share of rules a check enforces (layers 1 and 2) should grow, and no rule should be left to the doc alone.

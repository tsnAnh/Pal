# Agent-friendly architecture

A codebase that agents extend well is locked down enough that the easy path is the right path. It may feel strict to humans. It lets an agent with little context, driven by a designer or a CEO, make a correct change by copying what is already there.

## Principles

1. **One paved path per concern.** Networking, persistence, navigation, date formatting, feature flags, logging: each has exactly one blessed API. Delete the alternatives and ban them with a lint rule whose message names the blessed API.
2. **Colocate a feature.** Everything a feature needs lives in one folder: its entry point, UI, state, data access, and tests. An agent working on the feature reads one folder, not ten.
3. **Enforce boundaries in the import graph.** Decide which layers may depend on which, then make the build or a test fail when that rule breaks. Documentation alone does not hold a boundary.
4. **No comments.** Explain with names, types, and structure. Agents treat a comment next to a workaround as permission to keep the workaround, and they copy the comment and the workaround together. Allowed: license headers, public API docs, a link to an external constraint, and a suppression with its reason.
5. **Delete tech debt, or at least stop it growing.** A pattern you would not want copied gets a lint rule today and a cleanup task. Run `/correct` on it.
6. **Make performance budgets structural.** If the UI thread must stay under 16 ms (8 ms at 120 Hz), keep slow work out of the UI module by construction, not by review.
7. **Prefer strict tools.** Strict compiler modes, exhaustive switches over sealed types, and warnings as errors turn whole classes of agent mistakes into build failures.

## Boundaries per stack

| Stack | Hold the boundary with | Test it with |
|---|---|---|
| Android (Kotlin) | Gradle modules per layer (`:feature:*`, `:core:data`, `:core:ui`); `implementation` over `api` | Konsist architecture tests; Android Lint and detekt forbidden imports |
| Kotlin Multiplatform | `commonMain` for shared logic, `expect`/`actual` for platform APIs; `explicitApi()` in library modules | The compiler rejects platform imports in `commonMain`; Konsist for layer rules |
| iOS (Swift) | Swift Package targets per layer; `internal` by default, `public` only at the package edge | The build fails on undeclared target dependencies; SwiftLint custom rules for banned imports |
| Flutter (Dart) | `lib/features/<feature>/` folders; a `core/` package for shared code | An import-boundary check in CI: a lint rule or a script over `package:` imports |
| Rust | Crates per layer in a workspace; `pub(crate)` by default | Cargo refuses undeclared dependencies; `cargo deny` bans crates |
| Python | Packages per layer | import-linter layer and forbidden contracts |
| Web or Electron | Separate entry points per process (main, renderer, worker) | Import-graph rules in the linter; a CI check on the bundle graph |

## Signs the architecture is wrong

- The same workaround appears in unrelated call sites.
- Types need escape hatches: `any`, force casts, `!!`, `unwrap()` outside tests, `dynamic`, `# type: ignore`.
- A new feature touches many unrelated folders.
- Agents keep asking where something should go.

When you see one, redesign the structure rather than documenting the workaround. The pstack principles `principle-redesign-from-first-principles`, `principle-model-the-domain`, and `principle-type-system-discipline` apply.

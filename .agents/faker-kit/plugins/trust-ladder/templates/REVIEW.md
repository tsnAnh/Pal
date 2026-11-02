# REVIEW.md

What reviewers check that no tool can. Human reviewers and the Claude review workflow both use this file. Anything a linter or compiler already enforces is out of scope here.

## Blocking

Mark these `[blocking]`. Each one names what to do instead.

1. **Unproven behavior change.** A change to what users see or do has no evidence from running it. Ask for test output, and for UI changes, screenshots or video from the verification skill.
2. **A second way to do something.** The change adds a new pattern for a concern AGENTS.md lists under Paved paths. Ask for the blessed API.
3. **A workaround instead of a fix.** A guard, retry, sleep, or special case hides a failure whose cause is not understood. Ask for the root cause.
4. **Tests that prove nothing.** A test would still pass if the code under test returned a default value, or it asserts on internals instead of what a caller observes.
5. **Security, privacy, data loss, money, auth, migrations, concurrency.** Anything that can leak data, lose data, charge wrongly, bypass a permission, fail a migration, or race.
6. **User-facing copy.** Text that exposes internal details (stack traces, table names, file paths) or is missing from a supported locale.
7. **A rule that should be a check.** The same review comment has appeared before. Ask for a lint rule or type through `/correct` instead of repeating it.

## Nits

Mark these `[nit]`. They never block a merge.

- Naming that makes a reader stop.
- A simpler equivalent exists in the same file.

## Style

Entries in STYLE.md are review rules too. Cite the entry id, for example `[nit] S3: error copy should say what to do next`.

## Out of scope

- Formatting, import order, and anything else CI enforces.
- Rewrites unrelated to the change.

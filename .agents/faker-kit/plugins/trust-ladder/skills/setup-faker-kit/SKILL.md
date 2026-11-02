---
name: setup-faker-kit
description: Prepare a repository so agents can work in it unattended and anyone on the team can use the kit. Writes AGENTS.md, CLAUDE.md, REVIEW.md and STYLE.md around the repository's own build, test, and lint commands; wires the Claude review workflow; links project skills for Claude Code; adds team settings so teammates get the kit automatically; and starts the corrections ledger. It adds no check script or lint configuration of its own; the one CI step it adds checks the kit's own links and vendored copy. Use for /setup-faker-kit, "set this repo up for agents", "set up PR review", or a repo with no AGENTS.md.
---

# Set up faker-kit in a repository

Work on a new branch. Everything here lands as one reviewable PR. Paths below starting with `templates/` or `references/` are in the trust-ladder plugin, two directories above this skill.

## 1. Inspect the repository

Answer from the files, not from the user:

- **Stacks.** The languages and build tools in use: Gradle with Android or Kotlin Multiplatform plugins, `Cargo.toml`, `pyproject.toml` or `requirements*.txt`, `pubspec.yaml`, `Package.swift` or `*.xcodeproj`, `package.json`.
- **Commands.** How to install, build, test, lint, and run the app, exactly as the repository already defines them (Makefile, package scripts, Gradle tasks, `justfile`, its CI workflows). These are the validation commands; setup does not add another.
- **What exists.** AGENTS.md, CLAUDE.md, other editors' rule folders, `.claude/`, CI workflows, linters, CODEOWNERS, `.github/pull_request_template.md`.
- **Surfaces.** What a user touches: mobile app, web app, desktop app, CLI, or service.

If the repository does not build or its tests do not pass as they are, stop and report it. Setting up on a broken base teaches agents the wrong commands.

## 2. Write the instruction files

1. **AGENTS.md** from `templates/AGENTS.md`. Fill every section from step 1: the repository's own install, build, test, lint, and run commands as they exist today, the layout, the boundaries, the paved paths, the never-list, and `## Review guidelines`. Record existing commands; do not add a wrapper script or a lint configuration. The only CI addition is the kit-integrity step in step 4. Delete a section rather than leave a placeholder. If AGENTS.md exists, merge: keep its content and add only the missing sections.
2. **The compat block.** Copy the text between the markers in `references/compat.md`, markers included, to the end of AGENTS.md. With it in place, the SessionStart hook stops injecting it.
3. **CLAUDE.md.** If it does not exist, create it containing only `@AGENTS.md`. If it exists, add `@AGENTS.md` as its first line and move anything that applies to every agent into AGENTS.md.
4. **Rules from other tools.** Port rule files from other editors (such as `*.mdc` rules) into AGENTS.md sections, or into nested AGENTS.md files for rules scoped to one directory. Then run pstack's `/correct` on each rule to see whether it can move down to a targeted lint in the repository's own CI.
5. **REVIEW.md and STYLE.md** from `templates/`. Seed STYLE.md with rules the team already repeats in review. Leave it short; `style-guide-from-reviews` fills it from real review comments.

## 3. Review bots

Every pull request gets an automatic Claude review that follows the repository's own REVIEW.md, the AGENTS.md review guidelines, and STYLE.md. It runs on the Claude GitHub app and the team's subscription; the repository needs no `ANTHROPIC_API_KEY` secret. Never write a key into a file.

1. **Write the rules the reviewer follows.**
   - `REVIEW.md` from `templates/REVIEW.md`. Keep the blocking list short and concrete; every item says what to do instead.
   - The `## Review guidelines` section of AGENTS.md: point at REVIEW.md, say what not to comment on, and ask for every blocking rule to be treated as P1.
   - `STYLE.md` from `templates/STYLE.md`, if it does not exist yet.
2. **Install the review workflow.** Copy `templates/github/claude-review.yml` byte for byte to `.github/workflows/claude-review.yml`. It is the only review a Hermes project bot's `faker-kit merge` counts:
   - the `review` job runs on every push to a same-repository, non-draft pull request, comments on findings, and submits one formal review of the head whose body ends with a `Risk: low`, `Risk: medium`, or `Risk: high` line;
   - the `security` job reviews the diff with the `review-main-security` checklist, returns its verdict as the action's structured output (`--json-schema`), so no file a branch carries can stand in for it, posts the `security-review` commit status on the head with a link to its run, and fails when the verdict is not `PASS`. `faker-kit merge` uses the status only to find that run, then accepts it only when the run belongs to this workflow file on this head and its `security` job succeeded, because any workflow can post a status but none can change another run's job result.

   Tell the owner what it needs, and do not write any secret yourself:
   1. The Claude GitHub app installed on the repository (github.com/apps/claude).
   2. A `CLAUDE_CODE_OAUTH_TOKEN` repository secret, from `claude setup-token`, which the owner adds on GitHub. No `ANTHROPIC_API_KEY`.
   3. A runner for both `runs-on` lines. The template uses GitHub's hosted `ubuntu-latest`. A repository in an organization with its own self-hosted runners uses their labels instead (`gh api orgs/<org>/actions/runners` lists them), and a repository listed under `ci_runners` in the machine config uses `[self-hosted, faker-kit]`.
   4. The owner merges the pull request that adds or changes this file. The review action refuses to run on a pull request that edits its own workflow, so that pull request gets no review, and `faker-kit merge` leaves every pull request that touches `.github/workflows/` to the owner.
3. **Make the findings count.** Review comments are not status checks, so the gate is conversation resolution: in branch protection (`templates/branch-protection.md`), require CI, a code owner's approval, and resolved conversations before merge. A `[blocking]` or P1 finding must be fixed, or answered with a reason and resolved, before the pull request can merge. Claude Code Review (Team and Enterprise) is an alternative an Owner turns on in the organization's admin settings; its check run is always neutral, so it never blocks a merge on its own.
4. **Set up triage.** Bots catch real bugs and also file noise. The pstack babysit playbook handles review comments with a fix, dismiss, or ask rubric (`references/bugbot-triage.md` in the pstack plugin; "Bugbot" there means any review bot). Copy `templates/review-bot-patterns.md` to `.agents/review-bot-patterns.md`; that file collects this repository's learned dismissal patterns so each agent does not relearn them. When the same `[blocking]` comment appears on two pull requests, it is a rule that belongs in a check. Run `/correct` on it.
5. **Prove it.** Open a throwaway pull request that breaks one REVIEW.md rule, for example a user-facing string added in one locale only. The review must flag it as `[blocking]`. Close the pull request.

## 4. Skills

1. Copy `scripts/link-skills.sh` from this skill to the repository's `scripts/`, then run `bash scripts/link-skills.sh .`. It links every project skill into `.claude/skills` and `.agents/skills`. Run it again whenever a project skill is added, and `bash scripts/link-skills.sh --check .` to confirm every link resolves.
2. Keep the kit intact in CI. Add one step to the repository's existing CI workflow that runs on every pull request, running `bash scripts/link-skills.sh --check .` and, when `.agents/faker-kit/vendor_kit.py` exists (the kit is vendored: always for a Hermes project, otherwise once `setup-cloud-agents` has run), `python3 .agents/faker-kit/vendor_kit.py --check .`. The first fails when a project skill is not linked; the second when the vendored kit was edited, a link broke, or `.agents/dispatch.json` pins another commit. If the repository has no CI workflow besides `claude-review.yml`, create `.github/workflows/faker-kit-checks.yml` with only these steps, and drop the second command while the kit is not vendored. Replace `<runs-on of claude-review.yml>` with the `runs-on` value of the `review` job in the repository's `.github/workflows/claude-review.yml`, copied exactly (a label list stays a list), so the workflow never runs on a runner that file does not use:

   ```yaml
   name: faker-kit-checks
   on:
     pull_request:
   jobs:
     kit:
       runs-on: <runs-on of claude-review.yml>
       steps:
         - uses: actions/checkout@v4
         - run: bash scripts/link-skills.sh --check .
         - run: python3 .agents/faker-kit/vendor_kit.py --check .
   ```

   That workflow checks the kit only. `faker-kit merge` does not count it as CI, so a repository whose only CI is this workflow still needs one that builds and tests every pull request before a Hermes bot can merge (`setup-hermes-project` stops without it).
3. If the repository has a user-facing surface and no verification skill, recommend `/create-verification-skill` next. It is the most valuable skill the repository can have: it lets an agent prove its own work. For Android, iOS, Flutter, or KMP apps, point it at `control-mobile` and `references/verification-drivers.md`.

## 5. Team settings

So that every teammate gets the kit without setup:

- `.claude/settings.json` from `templates/claude-settings.json`: adds this marketplace, enables the plugins, and denies destructive commands.
- Cloud sessions do not install the plugins this file enables. `setup-cloud-agents` vendors the kit into the repository for them.
- `CODEOWNERS` and the branch-protection checklist in `templates/branch-protection.md`: the repository's own CI checks, resolved review conversations, and one human approval, so changes from anyone, including non-engineers, pass the same gates.

## 6. Start the records

Keep the template's `## Rules and what enforces them` table in AGENTS.md; `/correct` (pstack) fills it as mistakes get fixed. When agents keep repeating a mistake, `/correct` picks the strongest layer that can stop it and, when that is a lint, adds a targeted one to the repository's own CI. Setup installs no lint configuration of its own, and no CI job beyond the kit-integrity step. Run `/check-agent-compatibility` and put its report in the pull request as the baseline the team improves on.

## 7. Verify and open the PR

1. Run the build, test, and lint commands recorded in AGENTS.md. They must pass as they did in step 1.
2. Run `scripts/link-skills.sh --check .`, and `python3 .agents/faker-kit/vendor_kit.py --check .` when the kit is vendored, the same two commands the CI step runs.
3. Open one PR titled `chore(agents): set up faker-kit`. The body lists what was added, the `/check-agent-compatibility` report, what the user must turn on after merging (the Claude GitHub app, the `CLAUDE_CODE_OAUTH_TOKEN` secret, and branch protection), links to the review from step 3.5, and the recommended next step (usually `/create-verification-skill`).

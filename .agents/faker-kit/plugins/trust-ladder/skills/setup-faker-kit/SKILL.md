---
name: setup-faker-kit
description: Prepare a repository so agents can work in it unattended and anyone on the team can use the kit. Writes AGENTS.md, CLAUDE.md and STYLE.md around the repository's own build, test, and lint commands; links project skills for Claude Code; adds team settings so teammates get the kit automatically; and starts the corrections ledger. It adds no check script or lint configuration of its own; the one CI step it adds checks the kit's own links and vendored copy. Use for /setup-faker-kit, "set this repo up for agents", or a repo with no AGENTS.md.
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

1. **AGENTS.md** from `templates/AGENTS.md`. Fill every section from step 1: the repository's own install, build, test, lint, and run commands as they exist today, the layout, the boundaries, the paved paths, and the never-list. Record existing commands; do not add a wrapper script or a lint configuration. The only CI addition is the kit-integrity step in step 4. Delete a section rather than leave a placeholder. If AGENTS.md exists, merge: keep its content and add only the missing sections.
2. **The compat block.** Copy the text between the markers in `references/compat.md`, markers included, to the end of AGENTS.md. With it in place, the SessionStart hook stops injecting it.
3. **CLAUDE.md.** If it does not exist, create it containing only `@AGENTS.md`. If it exists, add `@AGENTS.md` as its first line and move anything that applies to every agent into AGENTS.md.
4. **Rules from other tools.** Port rule files from other editors (such as `*.mdc` rules) into AGENTS.md sections, or into nested AGENTS.md files for rules scoped to one directory. Then run pstack's `/correct` on each rule to see whether it can move down to a targeted lint in the repository's own CI.
5. **STYLE.md** from `templates/STYLE.md`. Seed it with rules the team already repeats in review. Leave it short; `style-guide-from-reviews` fills it from real review comments.

## 3. CI and verification

A pull request is checked by the repository's own CI and proved by its verification skills. Setup adds no workflow or secret for either.

1. **CI.** The repository's own GitHub Actions workflow must build and test every pull request, triggered by `push` or `pull_request`. A Hermes project bot's `faker-kit merge` needs a passing check run from such a workflow on the head, so a repository without one cannot have its pull requests landed by a bot. If there is none, say so under "Owner to do" in the pull request; add no check runner of your own.
2. **Verification skills.** Recommend `/create-verification-skill` for any repository with a user-facing surface, and `/create-formal-verification-skill` for logic where a missed case is costly (a parser, a permission check, a state machine). They leave `verify-*` skills in the repository. The author's own session runs those skills on its change. For Hermes projects `verification_skill` in `.agents/dispatch.json` names the skill.
3. **High-risk paths.** List the paths that need the closest review (authentication, secrets, migrations, deployment) under `risk_paths_high` in `.agents/dispatch.json` (`setup-hermes-project`). `CODEOWNERS` and branch protection (`templates/branch-protection.md`) hold the same line on the GitHub side.

## 4. Skills

1. Copy `scripts/link-skills.sh` from this skill to the repository's `scripts/`, then run `bash scripts/link-skills.sh .`. It links every project skill into `.claude/skills` and `.agents/skills`. Run it again whenever a project skill is added, and `bash scripts/link-skills.sh --check .` to confirm every link resolves.
2. Keep the kit intact in CI. Add one step to the repository's existing CI workflow that runs on every pull request, running `bash scripts/link-skills.sh --check .` and, when `.agents/faker-kit/vendor_kit.py` exists (the kit is vendored: always for a Hermes project, otherwise once `setup-cloud-agents` has run), `python3 .agents/faker-kit/vendor_kit.py --check .`. The first fails when a project skill is not linked; the second when the vendored kit was edited, a link broke, or `.agents/dispatch.json` pins another commit. If the repository has no CI workflow, create `.github/workflows/faker-kit-checks.yml` with only these steps, and drop the second command while the kit is not vendored. Replace `<runs-on>` with the runner the repository uses: GitHub's hosted `ubuntu-latest` by default, the labels of the organization's own self-hosted runners for an organization repository that has them (`gh api orgs/<org>/actions/runners` lists them), or `[self-hosted, faker-kit]` for a repository listed under `ci_runners` in the machine config (a label list stays a list):

   ```yaml
   name: faker-kit-checks
   on:
     pull_request:
   jobs:
     kit:
       runs-on: <runs-on>
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
3. Open one PR titled `chore(agents): set up faker-kit`. The body lists what was added, the `/check-agent-compatibility` report, what the user must turn on after merging (branch protection, and CI that builds and tests every pull request if the repository has none), and the recommended next step (usually `/create-verification-skill`).

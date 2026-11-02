---
name: style-guide-from-reviews
description: Build or update STYLE.md from what reviewers actually say. Mines human review comments on merged pull requests, clusters the repeated ones into rules with bad and good examples, and names the layer each rule should move to next (type, lint, review bot, skill, or style-only). Use for /style-guide-from-reviews, when STYLE.md is empty or stale, or when reviewers keep repeating themselves.
---

# Style guide from reviews

A style guide that lives in reviewers' heads is the weakest layer: it works only when a busy person remembers it. Writing it down is the first step. Moving each rule into a check is the goal. This skill does the first step from evidence and sets up the second.

## 1. Collect review comments

Use `gh` against the repository. Default to the last 90 days of merged pull requests.

```bash
gh pr list --state merged --limit 200 --json number,mergedAt,author
gh api repos/{owner}/{repo}/pulls/{number}/comments --paginate
gh api repos/{owner}/{repo}/pulls/{number}/reviews --paginate
```

Keep comments written by people. Drop bot accounts, approvals with no text, and replies that only say "done" or "fixed". Keep the file, the diff hunk, and the pull request link with each comment.

## 2. Cluster

Group comments that ask for the same change, even when worded differently. A cluster needs at least two comments on two different pull requests to become a rule. Single comments are anecdotes; list them at the end of the report and do not write them into STYLE.md.

## 3. Write each rule

For each cluster, write an entry in the STYLE.md format (`templates/STYLE.md` in the trust-ladder plugin):

- The rule in one sentence.
- Why, in the reviewers' own terms.
- Bad and good examples taken from the real diffs, trimmed to the smallest form.
- The source links.
- `Promotion`: the strongest layer that could hold it. Use `type` or `lint:<id>` when a tool could check it, `review` when only judgment can, `skill:<name>` when it is a procedure, and `style-only` for taste.

Do not duplicate what a linter already enforces. If reviewers repeat a comment that a rule already covers, the rule is misconfigured; report that instead.

## 4. Merge into STYLE.md

Update entries that already exist instead of adding near-duplicates. Keep ids stable so review comments can cite `S3`. Remove entries whose rule has since moved into a check, and leave a line in the report saying where it went.

## 5. Promote the easy ones

For every new entry whose promotion is `type` or `lint:*`, fix it now the way the pstack `correct` skill does (read it and apply its fix order), or list it for `/correct` if there are many. For `review` entries, make sure REVIEW.md's blocking or nit list covers them.

## Report

- Pull requests and comments read, and the date range.
- New and updated STYLE.md entries, each with its promotion target.
- Entries promoted in this run, with their PRs.
- Anecdotes that did not reach the two-comment bar.

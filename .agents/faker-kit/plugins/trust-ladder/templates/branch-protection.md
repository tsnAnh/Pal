# Branch protection checklist

Every change reaches the default branch through the same gates, whether an engineer, a designer, or an agent wrote it. That is what makes it safe for anyone on the team to open a pull request.

Turn these on for the default branch in the repository's settings (Rules, then Rulesets, or Branches, then Branch protection rules):

- [ ] Require a pull request before merging.
- [ ] Require at least one approval, and require review from Code Owners.
- [ ] Dismiss stale approvals when new commits are pushed.
- [ ] Require status checks to pass: the repository's CI jobs, the ones that build and test every pull request.
- [ ] Require branches to be up to date before merging.
- [ ] Require conversation resolution before merging, so every review comment is fixed or answered first.
- [ ] Block force pushes and deletions.
- [ ] Do not allow bypassing the rules above, including for administrators.

Add a `CODEOWNERS` file (see `CODEOWNERS` in these templates) so every pull request has a named human reviewer. Non-engineers' pull requests go to an engineer who owns that area.

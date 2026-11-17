"""Fleet exact-head CI provenance policy (``fleet-ci:`` completion contracts).

Accepts a PR whose head carries a qualifying CI success without requiring
repository-required checks. CI acceptance is not merge consent: review, conflict
and ownership checks stay with the merge path, and nothing here writes to GitHub.
"""
from __future__ import annotations

import re

from hermes_cli.kanban_pr_acceptance import _api, _PR, phase

_SHA = re.compile(r"[0-9a-f]{40}")
_WORKFLOW_DIR = ".github/workflows/"
_IGNORED_WORKFLOWS = frozenset({".github/workflows/claude-review.yml"})
_NON_BUILD_WORKFLOWS = _IGNORED_WORKFLOWS | {".github/workflows/faker-kit-checks.yml"}
_IGNORED_STATUS = re.compile(r"security-review|claude-review.*")
_NON_FAILING = {"success", "neutral", "skipped"}
_RETARGET_EVENTS = {"base_ref_changed", "automatic_base_change_succeeded", "automatic_base_change_failed"}


def _pages(endpoint: str, key: str | None, profile_home: str | None) -> list[dict]:
    pages = _api(endpoint, paginate=True, profile_home=profile_home)
    if not isinstance(pages, list) or not pages:
        raise ValueError("Missing provenance pages")
    items = []
    for page in pages:
        part = page[key] if key else page
        if not isinstance(part, list):
            raise ValueError("Malformed provenance page")
        items.extend(part)
    if key and len({i["id"] for i in items}) != pages[0]["total_count"]:
        raise ValueError("Incomplete provenance pagination")
    return items


def _workflow_path(run: dict) -> str:
    return (run.get("path") or "").split("@")[0]


def _tree(repo: str, ref: str, profile_home: str | None) -> dict[str, str]:
    tree = _api(f"repos/{repo}/git/trees/{ref}?recursive=1", profile_home=profile_home)
    if tree.get("truncated"):
        raise ValueError("Workflow tree is truncated")
    return {e["path"]: e["sha"] for e in tree["tree"] if e["path"].startswith(_WORKFLOW_DIR)}


def _qualifies(run: dict, *, repo: str, sha: str, number: int, branch: str, default: str,
               opened: str, workflows_match, linked: bool) -> bool:
    path = _workflow_path(run)
    if (run.get("head_sha") != sha or not path.startswith(_WORKFLOW_DIR) or path in _NON_BUILD_WORKFLOWS
            or (run.get("repository") or {}).get("full_name", "").lower() != repo.lower()
            or (run.get("head_repository") or {}).get("full_name", "").lower() != repo.lower()
            or run.get("head_branch") != branch):
        return False
    if run.get("event") == "push":
        return workflows_match()
    if run.get("event") == "pull_request":
        listed = run.get("pull_requests")
        # GitHub drops pull_requests from a run once its PR merges; an empty list is then proven by the commit-to-PR link.
        attached = linked if listed == [] else any(
            p.get("number") == number and (p.get("base") or {}).get("ref") == default for p in listed or [])
        return attached and (run.get("run_started_at") or run.get("created_at") or "") >= opened
    return False


def collect(receipt: dict, target: str, published_pr: str | None, profile_home: str | None) -> dict:
    """Fill ``receipt`` for ``target`` (OWNER/REPO or exact PR URL); raises like ``collect_acceptance``."""
    declared = _PR.fullmatch(target)
    url = target if declared else published_pr
    match = _PR.fullmatch(url or "")
    if not match or (not declared and match[1] != target) or (declared and published_pr and published_pr != target):
        receipt["detail"] = "Supply metadata.published_pr matching the persisted completion contract."
        return receipt
    repo, number = match[1], int(match[2])
    receipt.update(pr_url=url, policy="fleet-ci")
    with phase("pull request read"):
        pr = _api(f"repos/{repo}/pulls/{number}", profile_home=profile_home)
        sha, branch = pr["head"]["sha"], pr["head"]["ref"]
        receipt["head_sha"] = sha
        if not _SHA.fullmatch(sha) or pr["state"] not in {"open", "closed"} or (pr["state"] == "closed" and not pr.get("merged")):
            raise ValueError("PR is closed or current head is unavailable")
    with phase("repository read"):
        default = _api(f"repos/{repo}", profile_home=profile_home)["default_branch"]
    if pr["base"]["ref"] != default or any(
            (pr[side].get("repo") or {}).get("full_name", "").lower() != repo.lower() for side in ("head", "base")):
        receipt["detail"] = "PR must be same-repository and target the default branch."
        receipt["classification"] = "provenance"
        return receipt
    owner = repo.split("/")[0]
    with phase("commit-to-PR pages"):
        commit_prs = _pages(f"repos/{repo}/commits/{sha}/pulls?per_page=100", None, profile_home)
    same_head = [p for p in commit_prs if p["number"] != number and p["state"] == "open" and p["head"]["sha"] == sha]
    linked = any(p["number"] == number and p["base"]["ref"] == default and p["head"]["sha"] == sha for p in commit_prs)
    with phase("branch PRs"):
        branch_prs = _pages(f"repos/{repo}/pulls?state=all&head={owner}:{branch}&per_page=100", None, profile_home)
    with phase("timeline"):
        timeline = [event for n in sorted({number, *(p["number"] for p in branch_prs)})
                    for event in _pages(f"repos/{repo}/issues/{n}/timeline?per_page=100", None, profile_home)]
    problems = (["another open PR shares this head"] if same_head else []) + (
        ["a PR from this branch targeted a non-default base"] if any(p["base"]["ref"] != default for p in branch_prs) else []) + (
        ["the PR base was retargeted"] if any(e.get("event") in _RETARGET_EVENTS for e in timeline) else [])
    if problems:
        receipt.update(classification="provenance", detail="; ".join(problems) + ".")
        return receipt
    with phase("workflow runs"):
        workflow_runs = {r["check_suite_id"]: r for r in _pages(
            f"repos/{repo}/actions/runs?head_sha={sha}&per_page=100", "workflow_runs", profile_home)}
    cache: list[bool] = []

    def workflows_match() -> bool:
        if not cache:
            with phase("workflow tree"):
                cache.append(_tree(repo, sha, profile_home) == _tree(repo, default, profile_home))
        return cache[0]
    with phase("check runs"):
        runs = _pages(f"repos/{repo}/commits/{sha}/check-runs?per_page=100&filter=latest", "check_runs", profile_home)
    with phase("statuses"):
        statuses = _pages(f"repos/{repo}/commits/{sha}/statuses?per_page=100", None, profile_home)
    latest = {}
    for status in statuses:
        if status["context"] not in latest or status["id"] > latest[status["context"]]["id"]:
            latest[status["context"]] = status
    outcomes, qualifying = [], 0
    for run in runs:
        workflow = workflow_runs.get((run.get("check_suite") or {}).get("id"))
        if workflow is not None and _workflow_path(workflow) in _IGNORED_WORKFLOWS:
            continue
        if run.get("head_sha") != sha:
            classification = "stale"
        elif run.get("status") != "completed":
            classification = "pending"
        elif run.get("conclusion") not in _NON_FAILING:
            classification = "failure"
        else:
            classification = "success"
        counted = (classification == "success" and run["conclusion"] == "success" and workflow is not None
                   and _qualifies(workflow, repo=repo, sha=sha, number=number, branch=branch, default=default,
                                  opened=pr["created_at"], workflows_match=workflows_match, linked=linked))
        qualifying += counted
        outcomes.append(classification)
        receipt["checks"].append({"name": run["name"], "id": run["id"], "url": run.get("html_url"),
                                  "head_sha": run.get("head_sha"), "classification": classification,
                                  "conclusion": run.get("conclusion"), "qualifying": counted,
                                  "workflow": _workflow_path(workflow) if workflow else None})
    for context, status in sorted(latest.items()):
        if _IGNORED_STATUS.fullmatch(context):
            continue
        classification = {"success": "success", "pending": "pending"}.get(status["state"], "failure")
        outcomes.append(classification)
        receipt["checks"].append({"name": context, "id": status["id"], "url": status.get("target_url"),
                                  "head_sha": sha, "classification": classification, "conclusion": status["state"]})
    with phase("final re-read"):
        current = _api(f"repos/{repo}/pulls/{number}", profile_home=profile_home)
        moved = (current["head"]["sha"] != sha or current["base"]["ref"] != pr["base"]["ref"]
                 or (current["state"] == "closed" and not current.get("merged"))
                 or _api(f"repos/{repo}", profile_home=profile_home)["default_branch"] != default)
    if moved:
        receipt.update(classification="stale", detail="PR head/base changed while collecting evidence; retry.")
        return receipt
    failing = next((x for x in outcomes if x != "success"), None)
    if failing:
        receipt["classification"] = failing
    elif not qualifying:
        receipt.update(classification="missing", detail="No qualifying CI success on this exact head.")
    else:
        receipt.update(classification="success", ok=True)
    return receipt

"""Exact-head GitHub acceptance for explicitly declared PR tasks.

Network work happens outside SQLite transactions. The lifecycle owner persists
receipts only after rechecking the captured run/status/contract under its lock.

``gh`` runs as the card's assignee profile (``profile_home``), not the ambient
login: :func:`_gh_env` resolves that profile's own credentials/config for the
subprocess — a multi-profile host's default ``gh`` login cannot read another
org's private repos (#122689).
"""
from __future__ import annotations

import json
import re
import subprocess
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import quote

_REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
_PR = re.compile(r"https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)")


FLEET_PREFIX = "fleet-ci:"


def split_contract(contract: str) -> tuple[str, str]:
    """``(policy, target)``: ``fleet-ci:`` selects the fleet exact-head CI policy, else required checks."""
    if contract.startswith(FLEET_PREFIX):
        return "fleet-ci", contract[len(FLEET_PREFIX):]
    return "required-checks", contract


def validate_contract(value: str | None) -> str:
    if value is None or value == "local-only":
        return "local-only"
    target = split_contract(value)[1] if isinstance(value, str) else None
    if not isinstance(value, str) or not (_REPO.fullmatch(target) or _PR.fullmatch(target)):
        raise ValueError("completion_contract must be local-only, OWNER/REPO, an exact GitHub PR URL, "
                         "or either of those prefixed with fleet-ci:")
    return value


def _api(endpoint: str, *, query: str | None = None, paginate: bool = False,
         profile_home: str | None = None):
    command = ["gh", "api", endpoint, "--hostname", "github.com"]
    if query is not None:
        command += ["-f", "query=" + query]
    if paginate:
        command += ["--paginate"]
    path = endpoint.split("?")[0]
    try:
        result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True,
                                text=True, encoding="utf-8", errors="replace", timeout=30,
                                check=True, env=_gh_env(profile_home))
    except subprocess.CalledProcessError as exc:
        # 401/403/404 = the login cannot see this repository (wrong profile identity
        # or missing grant), not a transient API failure. Persist only the status
        # code + endpoint, never gh's stderr (credentials/host details).
        denied = re.search(r"HTTP (40[134])", exc.stderr or "")
        if denied:
            raise _GateAuthError(f"HTTP {denied[1]} on {path}") from None
        if exc.returncode == 4:  # gh's authentication-required exit: this profile has no login
            raise _GateAuthError(f"gh has no login for {path}") from None
        raise _GateInfraError(f"CalledProcessError (gh exited {exc.returncode} while reading {path})") from None
    except subprocess.TimeoutExpired:
        raise _GateInfraError(f"TimeoutExpired (gh timed out (30s) while reading {path})") from None
    try:
        value = decode_pages(result.stdout) if paginate else json.loads(result.stdout)
    except ValueError:
        raise _GateInfraError(f"JSONDecodeError (malformed JSON while reading {path})") from None
    if isinstance(value, dict) and value.get("errors"):
        raise ValueError("GitHub returned incomplete GraphQL evidence")
    return value


def decode_pages(text: str) -> list:
    """``gh api --paginate`` output as the page list ``--slurp`` gives; gh 2.46 has no ``--slurp``."""
    decoder, pages, index = json.JSONDecoder(), [], 0
    while (index := len(text) - len(text[index:].lstrip())) < len(text):
        value, index = decoder.raw_decode(text, index)
        pages.append(value)
    if not pages:
        raise ValueError("empty paginated response")
    return pages


class _GateInfraError(ValueError):
    """Evidence collection failed outside the auth cases; the message carries no gh stderr."""


_INFRA_ERRORS = (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError, IndexError)


@contextmanager
def phase(name: str):
    try:
        yield
    except _GateAuthError:
        raise
    except _INFRA_ERRORS as exc:
        if isinstance(exc, _GateInfraError):
            if " in phase " in str(exc):
                raise
            cause = str(exc)
        else:
            cause = f"{type(exc).__name__} ({exc})" if type(exc) is ValueError else type(exc).__name__
        raise _GateInfraError(f"{cause} in phase {name}") from None


class _GateAuthError(RuntimeError):
    """gh was refused at HTTP 401/403/404 (or GraphQL returned no repository):
    this profile's login cannot see the repo — an identity problem to fix, not
    an infrastructure blip to retry."""


# Every key gh can read a login from, github.com and GitHub Enterprise alike. All of them are
# dropped from the launcher's env for a routed child; only _GH_GITHUB_LOGIN_KEYS come back.
_GH_LOGIN_KEYS = (
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "GH_ENTERPRISE_TOKEN",
    "GITHUB_ENTERPRISE_TOKEN",
    "GH_HOST",
    "GH_CONFIG_DIR",
)
# Every call here targets github.com (`--hostname github.com`, github.com PR URLs), where gh
# ignores the enterprise token vars and GH_HOST. So only these are re-added from the profile, and
# only these prove a login: an enterprise-only profile must still get the fail-closed pin below,
# or gh falls through to the launcher's ~/.config/gh/hosts.yml for github.com.
_GH_GITHUB_LOGIN_KEYS = ("GH_TOKEN", "GITHUB_TOKEN", "GH_CONFIG_DIR")
# Not a login, but gh cannot reach github.com without them where the profile's .env sets them
# (a proxy in .env is documented; a routed child loses the launcher's .env copy).
_GH_TRANSPORT_KEYS = ("HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY", "https_proxy",
                      "http_proxy", "all_proxy", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR")


def _gh_env(profile_home: str | None) -> dict[str, str] | None:
    """Child env for ``gh``: the card's profile identity when one is resolvable.

    The completion boundary runs in the worker (assignee), the CLI, or a
    reviewer/dispatcher turn, so an ambient ``gh`` login is whichever process
    happened to call it (#122689). gh needs only its own login, so the env keeps
    the provider scrub — ``served_profile_child_env(inherit_credentials=False)``,
    its "caller re-adds the few keys the child needs" contract — and re-adds
    exactly gh's github.com login keys (``_GH_GITHUB_LOGIN_KEYS``) from the target profile's own secret scope
    instead of overlaying the whole scope (#134669: the gh child never needs
    the assignee's provider keys or adapter secrets).
    ``None`` keeps the ambient env — unassigned cards behave exactly as before.
    """
    if not profile_home:
        return None
    from agent.secret_scope import build_profile_secret_scope
    from tools.environments.local import _is_routed_home, hermes_subprocess_env, served_profile_child_env
    base = hermes_subprocess_env(inherit_credentials=False)
    routed = _is_routed_home(profile_home)
    if routed:
        # The launcher's own gh login must not reach the child: GH_TOKEN/GITHUB_TOKEN are
        # already scrubbed by hermes_subprocess_env, but the enterprise trio (GH_HOST,
        # GH_/GITHUB_ENTERPRISE_TOKEN) is on no strip list, and a surviving ambient token
        # would reach the child (#122689, the GHE case). The target's own github.com login keys
        # are re-added from its secret scope below.
        for key in _GH_LOGIN_KEYS:
            base.pop(key, None)
    env = served_profile_child_env(base=base, target_home=profile_home, inherit_credentials=False)
    scope = build_profile_secret_scope(Path(profile_home))
    env.update((key, scope[key]) for key in _GH_GITHUB_LOGIN_KEYS if scope.get(key))
    env.update((key, scope[key]) for key in _GH_TRANSPORT_KEYS if key in scope)  # NO_PROXY= clears
    if routed and not (env.keys() & set(_GH_GITHUB_LOGIN_KEYS)):
        # HOME/XDG_CONFIG_HOME are still the launch process's: without a login of its own the
        # child would fall through to ~/.config/gh/hosts.yml — the ambient login. Pin gh's config
        # to a profile-owned dir so it fails "not logged in" (exit 4 -> auth) instead.
        env["GH_CONFIG_DIR"] = str(Path(profile_home) / "gh")
    return env


def _assignee_profile_home(assignee: str | None) -> str | None:
    """Home whose ``gh`` login must read the contract repo — the assignee's, resolved
    exactly as the dispatcher resolves the worker's home — or None (unassigned) so the
    ambient login is used. An assigned card whose profile cannot be resolved is an
    identity failure (``auth``), never a silent fall-through to the ambient login."""
    if not assignee:
        return None
    from hermes_cli.profiles import normalize_profile_name, resolve_profile_env
    try:
        return resolve_profile_env(normalize_profile_name(assignee))
    except (FileNotFoundError, ValueError):
        raise _GateAuthError(f"assignee profile {assignee!r} cannot be resolved") from None


def _required_contexts(pr: dict, repo: str, branch: str, profile_home: str | None) -> set:
    protection = (pr.get("baseRef") or {}).get("branchProtectionRule") or {}
    required = {(r["context"], (r.get("app") or {}).get("databaseId")) for r in protection.get("requiredStatusChecks", [])}
    with phase("branch rules"):
        rules = _api(f"repos/{repo}/rules/branches/{quote(branch, safe='')}?per_page=100",
                     paginate=True, profile_home=profile_home)
    for page in rules:
        for rule in page:
            if rule["type"] == "required_status_checks":
                required.update((r["context"], r.get("integration_id"))
                                for r in rule["parameters"]["required_status_checks"])
    return required


def _required_outcomes(repo: str, sha: str, required: set, profile_home: str | None) -> tuple[list[str], list[dict]]:
    with phase("check runs"):
        pages = _api(f"repos/{repo}/commits/{sha}/check-runs?per_page=100&filter=latest",
                     paginate=True, profile_home=profile_home)
        runs = [run for page in pages for run in page["check_runs"]]
        if len({r["id"] for r in runs}) != pages[0]["total_count"]:
            raise ValueError("Incomplete check-run pagination")
    with phase("statuses"):
        statuses = [{**s, "sha": sha} for page in _api(f"repos/{repo}/commits/{sha}/statuses?per_page=100",
                                                       paginate=True, profile_home=profile_home) for s in page]
    outcomes, checks = [], []
    for context, app_id in sorted(required, key=str):
        matching = [r for r in runs if r["name"] == context and
                    (app_id in (None, -1) or r["app"]["id"] == app_id)]
        # A legacy status can satisfy an unpinned context, but never a check pinned to an app.
        legacy = [s for s in statuses if s["context"] == context] if app_id in (None, -1) else []
        selected = matching + ([max(legacy, key=lambda s: s["id"])] if legacy else [])
        if not selected:
            outcomes.append("missing")
            checks.append({"name": context, "classification": "missing", "head_sha": sha})
        for check in selected:
            is_run = "conclusion" in check
            outcome = check.get("conclusion") if is_run else check["state"]
            classification = _classify(check, sha, outcome, is_run)
            outcomes.append(classification)
            checks.append({"name": context, "id": check["id"],
                "url": check.get("html_url") or check.get("target_url"),
                "head_sha": check.get("head_sha", check.get("sha")),
                "classification": classification, "conclusion": outcome})
    return outcomes, checks


def ci_warning(sha: str, checks: list[dict]) -> str | None:
    names = {state: [c["name"] for c in checks if c["classification"] == state] for state in ("failure", "pending")}
    other = [f"{c['name']} ({c['classification']})" for c in checks if c["classification"] not in ("success", "failure", "pending")]
    if names["failure"]:
        return f"accepted; CI failed: {', '.join(names['failure'])} on {sha}"
    if names["pending"]:
        return f"accepted; CI pending: {', '.join(names['pending'])} on {sha}"
    if other:
        return f"accepted; CI not confirmed: {', '.join(other)} on {sha}"
    return None


def unreadable_ci_warning(sha: str, exc: Exception) -> str:
    cause = str(exc) if isinstance(exc, (_GateAuthError, _GateInfraError)) else type(exc).__name__
    return f"accepted; CI state unreadable on {sha}: {cause}"


def accept_merged(receipt: dict, warning: str | None) -> dict:
    receipt.update(ok=True, classification="merged", merged=True)
    if warning:
        receipt["warning"] = warning
    return receipt


def refuse_not_merged(receipt: dict, pr_url: str, state: str) -> dict:
    receipt.update(classification="not_merged",
                   detail=f"{pr_url} is {state} and was never merged; only a merged pull request, "
                          "or an open one whose required checks all succeeded, is accepted.")
    return receipt


def _merged_ci_warning(receipt: dict, repo: str, sha: str, branch: str, pr: dict, profile_home: str | None) -> str | None:
    try:
        required = _required_contexts(pr, repo, branch, profile_home)
        receipt["required"] = [{"context": c, "app_id": a} for c, a in sorted(required, key=str)]
        if not required:
            return None
        _, receipt["checks"] = _required_outcomes(repo, sha, required, profile_home)
    except (_GateAuthError, *_INFRA_ERRORS) as exc:
        return unreadable_ci_warning(sha, exc)
    return ci_warning(sha, receipt["checks"])


def collect_acceptance(contract: str, published_pr: str | None,
                       assignee: str | None = None) -> dict:
    receipt = {"ok": False, "classification": "missing", "head_sha": None,
               "pr_url": published_pr, "checks": [],
               "recovery": "Fix required failures, rerun infrastructure checks or wait, then retry completion. "
                           "Use kanban_block if human input is needed; receipts remain on the task event log."}
    try:
        policy, contract = split_contract(contract)
        if policy == "fleet-ci" and not assignee:
            raise _GateAuthError("fleet-ci acceptance needs an assigned profile; it never uses the ambient login")
        profile_home = _assignee_profile_home(assignee)
        if policy == "fleet-ci":
            from hermes_cli.kanban_pr_acceptance_fleet import collect
            return collect(receipt, contract, published_pr, profile_home)
        declared = _PR.fullmatch(contract)
        url = contract if declared else published_pr
        match = _PR.fullmatch(url or "")
        if not match or (not declared and match[1] != contract) or (declared and published_pr and published_pr != contract):
            receipt.update(classification="mismatch" if published_pr else "missing",
                           detail=binding_detail(contract, published_pr))
            return receipt
        repo, number = match[1], int(match[2])
        receipt["pr_url"] = url
        owner, name = repo.split("/")
        query = f'{{repository(owner:{json.dumps(owner)},name:{json.dumps(name)}){{pullRequest(number:{number:d}){{headRefOid baseRefName state\n            baseRef{{branchProtectionRule{{requiredStatusChecks{{context app{{databaseId}}}}}}}}}}}}}}'
        with phase("pull request read"):
            repository = _api("graphql", query=query, profile_home=profile_home)["data"]["repository"]
        if repository is None:
            # A private repo the login cannot read resolves to null, not an error.
            raise _GateAuthError(f"HTTP 404 on graphql {repo}")
        pr = repository["pullRequest"]
        sha, branch = pr["headRefOid"], pr["baseRefName"]
        receipt["head_sha"] = sha
        if pr["state"] == "CLOSED":
            return refuse_not_merged(receipt, url, "closed")
        if not re.fullmatch(r"[0-9a-f]{40}", sha) or pr["state"] not in {"OPEN", "MERGED"}:
            raise _GateInfraError("current head is unavailable in phase pull request read")
        if pr["state"] == "MERGED":
            return accept_merged(receipt, _merged_ci_warning(receipt, repo, sha, branch, pr, profile_home))
        required = _required_contexts(pr, repo, branch, profile_home)
        receipt["required"] = [{"context": c, "app_id": a} for c, a in sorted(required, key=str)]
        if not required:
            receipt["detail"] = "No repository-required checks are configured; explicitly use a local-only contract for non-CI tasks."
            return receipt
        outcomes, receipt["checks"] = _required_outcomes(repo, sha, required, profile_home)
        # Re-read after all pages: old-head successes are never transferable.
        with phase("final re-read"):
            current = _api(f"repos/{repo}/pulls/{number}", profile_home=profile_home)
        if current["head"]["sha"] != sha or current["base"]["ref"] != branch or (current["state"] == "closed" and not current.get("merged")):
            receipt.update(classification="stale", detail="PR head/base changed while collecting evidence; retry.")
            return receipt
        receipt["classification"] = next((x for x in outcomes if x != "success"), "missing" if not outcomes else "success")
        receipt["ok"] = receipt["classification"] == "success"
        return receipt
    except _GateAuthError as exc:
        login = f"assignee profile {assignee!r}'s gh login" if assignee else "the ambient gh login"
        receipt.update(classification="auth",
                       detail=f"GitHub refused the acceptance read ({exc}) as {login}; "
                              "fix that profile's GitHub credentials/access to the repository, then retry completion.")
        return receipt
    except _INFRA_ERRORS as exc:
        # Never persist gh stderr (credentials/host details); the failed phase is actionable.
        cause = str(exc) if isinstance(exc, _GateInfraError) else f"{type(exc).__name__} in phase acceptance"
        receipt.update(classification="infra", detail=f"infra: {cause}; GitHub acceptance evidence unavailable or "
                                                      "incomplete, check gh authentication/API access and retry.")
        return receipt


def binding_detail(contract: str, published_pr: str | None) -> str:
    expected = contract if _PR.fullmatch(contract) else f"a pull request in {contract}"
    found = published_pr or "no metadata.published_pr"
    return f"completion_contract {contract} expects {expected}; found {found}."


def refusal_detail(receipt: dict) -> str:
    if receipt.get("detail"):
        return receipt["detail"]
    sha, pr_url = receipt.get("head_sha") or "unknown head", receipt.get("pr_url") or "the published pull request"
    unmet = [f"{c['name']} ({c['classification']})" for c in receipt.get("checks", []) if c["classification"] != "success"]
    if unmet:
        return f"{pr_url} is not merged and required checks are not successful on {sha}: {', '.join(unmet)}."
    return f"{pr_url} is not merged and no successful required check was found on {sha} (classification {receipt['classification']})."


def _classify(check: dict, sha: str, outcome: str | None, is_run: bool) -> str:
    if check.get("head_sha", check.get("sha")) != sha:
        return "stale"
    if is_run and check.get("status") != "completed":
        return "pending"
    return {"success": "success", "failure": "failure", "error": "infra", "pending": "pending"}.get(outcome, "infra")

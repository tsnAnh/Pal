"""Typed outcome contracts and evidence for governed Kanban cards.

A card with an ``outcome_contract`` is governed: it can only reach ``done`` once attributable
evidence of the declared outcome verifies. Everything here is pure; persistence and the GitHub
read live in ``kanban_outcomes_store``.
"""
from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

CONTRACT_KINDS = ("merged_pr", "built_artifact", "installed_app", "other")

_REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
_PR_URL = re.compile(r"https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)")
_SHA1 = re.compile(r"[0-9a-f]{40}")
_SHA256 = re.compile(r"[0-9a-f]{64}")
_MAX_TEXT = 500


class OutcomeContractError(ValueError):
    pass


class EvidenceError(ValueError):
    """Evidence rejected at record time; ``code`` is malformed, mismatch or stale."""

    def __init__(self, code: str, detail: str):
        self.code, self.detail = code, detail
        super().__init__(f"evidence refused ({code}): {detail}")


class Unverifiable(Exception):
    """An external fact could not be read; the completion is refused, not guessed."""


@dataclass(frozen=True)
class OutcomeContract:
    kind: str
    repo: Optional[str] = None
    name: Optional[str] = None
    required_fields: tuple[str, ...] = ()

    def to_json(self) -> str:
        body: dict[str, Any] = {"kind": self.kind}
        if self.repo:
            body["repo"] = self.repo
        if self.name:
            body["name"] = self.name
        if self.required_fields:
            body["required_fields"] = list(self.required_fields)
        return json.dumps(body, sort_keys=True, separators=(",", ":"))


_CONTRACT_KEYS = {
    "merged_pr": {"kind", "repo"},
    "built_artifact": {"kind"},
    "installed_app": {"kind"},
    "other": {"kind", "name", "required_fields"},
}


def _text(value: Any, label: str, *, error=OutcomeContractError) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > _MAX_TEXT:
        raise error(f"{label} must be a non-empty string of at most {_MAX_TEXT} characters")
    return value.strip()


def parse_contract(value: Any) -> Optional[OutcomeContract]:
    """``None`` (ungoverned) passes through; a JSON string or dict is validated strictly."""
    if value is None or value == "":
        return None
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            raise OutcomeContractError("outcome_contract must be a JSON object") from None
    if not isinstance(value, dict) or value.get("kind") not in CONTRACT_KINDS:
        raise OutcomeContractError(f"outcome_contract.kind must be one of {', '.join(CONTRACT_KINDS)}")
    kind = value["kind"]
    extra = set(value) - _CONTRACT_KEYS[kind]
    if extra:
        raise OutcomeContractError(f"outcome_contract has unknown keys for {kind}: {', '.join(sorted(extra))}")
    if kind == "merged_pr":
        repo = _text(value.get("repo"), "outcome_contract.repo")
        if not _REPO.fullmatch(repo):
            raise OutcomeContractError("outcome_contract.repo must be OWNER/REPO")
        return OutcomeContract(kind, repo=repo)
    if kind == "other":
        fields = value.get("required_fields")
        if not isinstance(fields, list) or not fields:
            raise OutcomeContractError("outcome_contract.required_fields must be a non-empty list")
        cleaned = tuple(_text(f, "outcome_contract.required_fields entry") for f in fields)
        if len(set(cleaned)) != len(cleaned):
            raise OutcomeContractError("outcome_contract.required_fields must be unique")
        return OutcomeContract(kind, name=_text(value.get("name"), "outcome_contract.name"),
                               required_fields=cleaned)
    return OutcomeContract(kind)


def contract_json(value: Any) -> Optional[str]:
    contract = parse_contract(value)
    return contract.to_json() if contract else None


def _hex(length_re: re.Pattern, label: str):
    def check(value):
        if not isinstance(value, str) or not length_re.fullmatch(value.strip().lower()):
            raise EvidenceError("malformed", f"{label} must be {'40' if length_re is _SHA1 else '64'} hex characters")
        return value.strip().lower()
    return check


def _pr_url(value):
    if not isinstance(value, str) or not _PR_URL.fullmatch(value.strip()):
        raise EvidenceError("malformed", "pr_url must be https://github.com/OWNER/REPO/pull/N")
    return value.strip()


def _free_text(label: str):
    return lambda value: _text(value, label, error=lambda m: EvidenceError("malformed", m))


def _receipt(value):
    if not isinstance(value, dict) or not value:
        raise EvidenceError("malformed", "receipt must be a non-empty object")
    try:
        json.dumps(value, sort_keys=True)
    except (TypeError, ValueError):
        raise EvidenceError("malformed", "receipt must be JSON serializable") from None
    if len(json.dumps(value)) > 20_000:
        raise EvidenceError("malformed", "receipt exceeds 20000 bytes")
    return value


_SHA = _hex(_SHA1, "sha")
_SHA_256 = _hex(_SHA256, "sha256")

EVIDENCE_SCHEMAS: dict[str, dict[str, Callable[[Any], Any]]] = {
    "execution_ref": {"session_id": _free_text("session_id"), "runtime": _free_text("runtime")},
    "pr_published": {"pr_url": _pr_url, "head_sha": _hex(_SHA1, "head_sha")},
    "pr_merged": {"pr_url": _pr_url, "head_sha": _hex(_SHA1, "head_sha"),
                  "merge_commit": _hex(_SHA1, "merge_commit")},
    "artifact_built": {"sha256": _SHA_256, "name": _free_text("name")},
    "app_installed": {"app_id": _free_text("app_id"), "artifact_sha256": _SHA_256,
                      "readback_sha256": _SHA_256, "host": _free_text("host")},
    "other_result": {"name": _free_text("name"), "receipt": _receipt},
}

LEGAL_EVIDENCE = {
    "merged_pr": frozenset({"execution_ref", "pr_published", "pr_merged"}),
    "built_artifact": frozenset({"execution_ref", "artifact_built"}),
    "installed_app": frozenset({"execution_ref", "artifact_built", "app_installed"}),
    "other": frozenset({"execution_ref", "other_result"}),
}

EVIDENCE_SOURCE = {
    "pr_published": "github", "pr_merged": "github", "artifact_built": "local-file",
}


def validate_evidence(kind: str, payload: Any) -> dict:
    schema = EVIDENCE_SCHEMAS.get(kind)
    if schema is None:
        raise EvidenceError("malformed", f"unknown evidence kind {kind!r}; use one of {', '.join(sorted(EVIDENCE_SCHEMAS))}")
    if not isinstance(payload, dict):
        raise EvidenceError("malformed", "payload must be a JSON object")
    missing, extra = set(schema) - set(payload), set(payload) - set(schema)
    if missing or extra:
        raise EvidenceError(
            "malformed",
            f"{kind} takes exactly {', '.join(sorted(schema))}"
            + (f"; missing {', '.join(sorted(missing))}" if missing else "")
            + (f"; unexpected {', '.join(sorted(extra))}" if extra else ""))
    return {key: check(payload[key]) for key, check in schema.items()}


def payload_digest(payload: dict) -> str:
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def pr_parts(pr_url: str) -> tuple[str, int]:
    match = _PR_URL.fullmatch(pr_url)
    return match[1], int(match[2])


@dataclass(frozen=True)
class Evidence:
    id: int
    run_id: int
    kind: str
    digest: str
    payload: dict
    producer_profile: str
    producer_session: Optional[str]
    source: str
    observed_at: int


@dataclass(frozen=True)
class Verdict:
    ok: bool
    code: str = "ok"
    detail: str = ""
    receipt: dict = field(default_factory=dict)


def _refuse(code: str, detail: str) -> Verdict:
    return Verdict(False, code, detail)


def _attach_hint(evidence_kind: str, example: str) -> str:
    return f"Attach {evidence_kind} evidence for this run: hermes kanban evidence add <task> --run-id <run> --kind {evidence_kind} --json '{example}'"


def _eval_merged_pr(contract, latest, fetch_pr, attachments) -> Verdict:
    merged = latest.get("pr_merged")
    if merged is None:
        return _refuse("missing", "no pr_merged evidence for this run. An open or accepted PR, passing CI, a "
                       "PR-open event, a finished session or a prose summary does not complete this card. "
                       + _attach_hint("pr_merged",
                                      '{"pr_url":"https://github.com/O/R/pull/N","head_sha":"<40hex>","merge_commit":"<40hex>"}'))
    repo, number = pr_parts(merged.payload["pr_url"])
    if repo != contract.repo:
        return _refuse("mismatch", f"PR belongs to {repo}, the contract requires {contract.repo}")
    published = latest.get("pr_published")
    if published is not None and published.payload["pr_url"] != merged.payload["pr_url"]:
        return _refuse("mismatch", "pr_published and pr_merged name different pull requests; the card is bound to the published one")
    try:
        pr = fetch_pr(repo, number)
    except Unverifiable as exc:
        return _refuse("unverifiable", f"GitHub could not confirm the merge ({exc}); retry completion once access works")
    if pr.get("state") != "MERGED":
        return _refuse("mismatch", f"GitHub reports the PR {str(pr.get('state')).lower()}, not merged. Merge it first; completion never merges")
    if pr.get("head_sha") != merged.payload["head_sha"]:
        return _refuse("mismatch", "the PR head on GitHub differs from the head_sha in the evidence")
    if pr.get("merge_commit") != merged.payload["merge_commit"]:
        return _refuse("mismatch", "the merge commit on GitHub differs from the merge_commit in the evidence")
    return Verdict(True, receipt={"pr_url": merged.payload["pr_url"], "head_sha": pr["head_sha"],
                                  "merge_commit": pr["merge_commit"], "state": "MERGED"})


def _verified_build(latest, attachments):
    built = latest.get("artifact_built")
    if built is None:
        return None, _refuse("missing", "no artifact_built evidence for this run. "
                             + _attach_hint("artifact_built", '{"sha256":"<64hex>","name":"app.zip"}')
                             + " and attach the file with hermes kanban attach")
    sha, name = built.payload["sha256"], built.payload["name"]
    match = [a for a in attachments() if a["sha256"] == sha and a["filename"] == name]
    if not match:
        named = [a for a in attachments() if a["filename"] == name]
        if named:
            return None, _refuse("mismatch", f"attachment {name!r} does not hash to the evidence sha256")
        return None, _refuse("missing", f"no attachment named {name!r} on this card; attach the built file with hermes kanban attach")
    return {"sha256": sha, "name": name, "attachment_id": match[0]["id"]}, None


def _eval_built_artifact(contract, latest, fetch_pr, attachments) -> Verdict:
    build, refusal = _verified_build(latest, attachments)
    return refusal or Verdict(True, receipt=build)


def _eval_installed_app(contract, latest, fetch_pr, attachments) -> Verdict:
    built, installed = latest.get("artifact_built"), latest.get("app_installed")
    if installed is None:
        return _refuse("missing", "no app_installed evidence for this run; a build alone does not complete an installed-app card. "
                       + _attach_hint("app_installed",
                                      '{"app_id":"...","artifact_sha256":"<64hex>","readback_sha256":"<64hex>","host":"..."}'))
    if built is None:
        return _refuse("missing", "no artifact_built evidence for this run to bind the install to. "
                       + _attach_hint("artifact_built", '{"sha256":"<64hex>","name":"app.zip"}'))
    p = installed.payload
    if not (p["artifact_sha256"] == p["readback_sha256"] == built.payload["sha256"]):
        return _refuse("mismatch", "the installed readback hash must equal artifact_sha256 and the built artifact sha256")
    return Verdict(True, receipt={"app_id": p["app_id"], "host": p["host"], "sha256": p["readback_sha256"]})


def _eval_other(contract, latest, fetch_pr, attachments) -> Verdict:
    result = latest.get("other_result")
    if result is None:
        return _refuse("missing", f"no other_result evidence for contract {contract.name!r}. "
                       + _attach_hint("other_result",
                                      json.dumps({"name": contract.name, "receipt": {f: "..." for f in contract.required_fields}})))
    if result.payload["name"] != contract.name:
        return _refuse("mismatch", f"other_result is named {result.payload['name']!r}, the contract declares {contract.name!r}")
    receipt = result.payload["receipt"]
    empty = [f for f in contract.required_fields if receipt.get(f) in (None, "", [], {}) or
             (isinstance(receipt.get(f), str) and not receipt[f].strip())]
    if empty:
        return _refuse("malformed", f"receipt is missing required field(s): {', '.join(empty)}")
    return Verdict(True, receipt={"name": contract.name, "fields": list(contract.required_fields)})


_EVALUATORS = {
    "merged_pr": _eval_merged_pr, "built_artifact": _eval_built_artifact,
    "installed_app": _eval_installed_app, "other": _eval_other,
}


def evaluate(contract: OutcomeContract, evidence: list[Evidence], *,
             fetch_pr: Callable[[str, int], dict], attachments: Callable[[], list[dict]]) -> Verdict:
    """Latest evidence per kind for the subject run decides; only a verified outcome passes."""
    latest: dict[str, Evidence] = {}
    for item in sorted(evidence, key=lambda e: e.id):
        latest[item.kind] = item
    return _EVALUATORS[contract.kind](contract, latest, fetch_pr, attachments)

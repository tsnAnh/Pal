#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from websockets.exceptions import WebSocketException

REPO = Path(__file__).resolve().parents[1]
MARKER = ".kanban-isolated-probe"
COORDINATOR = "coordinator"
RIVAL = "rival"
SESSION = "kanban-isolated-probe"
PASSTHROUGH = (
    "PATH", "LANG", "LC_ALL", "TZ", "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE",
    "NODE_EXTRA_CA_CERTS", "GIT_SSL_CAINFO", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "ALL_PROXY",
    "https_proxy", "http_proxy", "no_proxy", "all_proxy", "HERMES_STATE_DB_GUARD_BYPASS",
)
SECRET_SHAPES = re.compile(
    r"gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|(?i:bearer)\s+[A-Za-z0-9._~+/=-]{8,}|sk-[A-Za-z0-9]{20,}")
GATEWAY_CONFIG = {
    "model": {"provider": "custom", "default": "local-wire-stub", "base_url": "http://127.0.0.1:1/v1"},
    "platform_toolsets": {"cli": []},
    "auxiliary": {"title_generation": {"enabled": False}},
}
ISOLATION_PROOF = (
    "import json;from pathlib import Path;from hermes_constants import get_hermes_home;"
    "from hermes_cli import kanban_db as kb;from hermes_cli.profiles import current_profile_name;"
    "print(json.dumps({'hermes_home':str(get_hermes_home().resolve()),'kanban_home':str(kb.kanban_home().resolve()),"
    "'profile':current_profile_name(None),'home':str(Path.home().resolve())}))"
)
READ_VERBS = ("kanban.boards.list", "kanban.board.snapshot", "kanban.card.get", "kanban.evidence.list", "kanban.events.since")


class IsolationError(RuntimeError):
    pass


class ProbeError(RuntimeError):
    pass


class _Missing:
    def __repr__(self) -> str:
        return "unknown"


MISSING = _Missing()


@dataclass(frozen=True)
class Check:
    name: str
    expected: Any
    observed: Any = MISSING


@dataclass(frozen=True)
class Step:
    key: str
    title: str
    status: str
    evidence: dict[str, Any]

    @classmethod
    def judged(cls, key: str, title: str, checks: Sequence[Check], notes: Mapping[str, Any] | None = None) -> Step:
        evidence = {check.name: check.observed for check in checks} | dict(notes or {})
        if any(c.observed is not MISSING and c.observed != c.expected for c in checks):
            status = "fail"
        elif any(c.observed is MISSING for c in checks):
            status = "unknown"
        else:
            status = "pass"
        return cls(key, title, status, evidence)

    @classmethod
    def unknown(cls, key: str, title: str, reason: str, notes: Mapping[str, Any] | None = None) -> Step:
        return cls(key, title, "unknown", {"reason": reason} | dict(notes or {}))

    @classmethod
    def failed(cls, key: str, title: str, reason: str, notes: Mapping[str, Any] | None = None) -> Step:
        return cls(key, title, "fail", {"reason": reason} | dict(notes or {}))


@dataclass
class Redactor:
    secrets: list[str] = field(default_factory=list)

    def add(self, value: str | None) -> None:
        if value and len(value) >= 8:
            self.secrets.append(value)

    def __call__(self, text: str) -> str:
        for value in self.secrets:
            text = text.replace(value, "[redacted]")
        return SECRET_SHAPES.sub("[redacted]", text)


def render_table(steps: Sequence[Step], redact: Redactor) -> str:
    def cell(value: Any) -> str:
        text = redact(value if isinstance(value, str) else "unknown" if value is MISSING else json.dumps(value, default=str))
        return (text if len(text) <= 160 else text[:157] + "...").replace("|", "\\|").replace("\n", " ")

    lines = ["| step | result | evidence |", "|---|---|---|"]
    for step in sorted(steps, key=lambda s: s.key):
        evidence = "; ".join(f"{name}={cell(value)}" for name, value in step.evidence.items())
        lines.append(f"| {step.key} {step.title} | {step.status} | {evidence} |")
    return "\n".join(lines)


def exit_code(steps: Sequence[Step]) -> int:
    if any(s.status == "fail" for s in steps):
        return 1
    return 3 if any(s.status == "unknown" for s in steps) else 0


def protected_roots(environ: Mapping[str, str], home: Path) -> dict[str, Path]:
    roots = {"default home": home / ".hermes"}
    for name in ("HERMES_HOME", "HERMES_KANBAN_HOME"):
        if environ.get(name, "").strip():
            roots[name] = Path(environ[name]).expanduser()
    return {label: path.resolve() for label, path in roots.items()}


@dataclass(frozen=True)
class Sandbox:
    root: Path

    @property
    def home(self) -> Path:
        return self.root / "home"

    @property
    def default_home(self) -> Path:
        return self.home / ".hermes"

    @property
    def kanban_home(self) -> Path:
        return self.root / "kanban"

    @property
    def logs(self) -> Path:
        return self.root / "logs"

    def profile_home(self, name: str) -> Path:
        return self.default_home / "profiles" / name

    def env(self, hermes_home: Path, extra: Mapping[str, str] | None = None) -> dict[str, str]:
        base = {name: os.environ[name] for name in PASSTHROUGH if name in os.environ}
        return base | {"HOME": str(self.home), "HERMES_HOME": str(hermes_home),
                       "HERMES_KANBAN_HOME": str(self.kanban_home)} | dict(extra or {})

    def created_paths(self) -> list[Path]:
        return [self.home, self.kanban_home, self.logs, self.root / MARKER]

    def prepare(self, protected: Mapping[str, Path]) -> None:
        self.assert_isolated(protected)
        self.root.mkdir(parents=True, exist_ok=True)
        for path in (self.home, self.default_home, self.kanban_home, self.logs):
            path.mkdir(parents=True, exist_ok=True)
        (self.root / MARKER).write_text(
            json.dumps({"probe": "kanban-isolated-probe", "created_at": int(time.time())}), encoding="utf-8")

    def assert_isolated(self, protected: Mapping[str, Path]) -> None:
        if self.root.exists():
            if not self.root.is_dir():
                raise IsolationError("scratch home exists and is not a directory")
            if any(self.root.iterdir()) and not self._probe_marked():
                raise IsolationError("scratch home is not empty and not probe-marked")
        for label, real in protected.items():
            if self.root == real or self.root.is_relative_to(real):
                raise IsolationError(f"scratch home is the real {label} or inside it")
            if real.is_relative_to(self.root):
                raise IsolationError(f"scratch home contains the real {label}")
            if self.kanban_home.resolve() == real:
                raise IsolationError(f"resolved Kanban home equals the real {label}")

    def _probe_marked(self) -> bool:
        try:
            return json.loads((self.root / MARKER).read_text(encoding="utf-8-sig")).get("probe") == "kanban-isolated-probe"
        except (OSError, ValueError, AttributeError):
            return False

    def cleanup(self) -> None:
        for path in self.created_paths():
            if path.is_dir():
                shutil.rmtree(path, ignore_errors=True)
            else:
                path.unlink(missing_ok=True)
        try:
            self.root.rmdir()
        except OSError:
            pass


@dataclass(frozen=True)
class Run:
    rc: int
    out: str
    err: str

    def json(self) -> Any:
        try:
            return json.loads(self.out)
        except ValueError:
            return MISSING

    def reason(self, label: str) -> Any:
        match = re.search(rf"{label} \((\w+)\)", self.err + self.out)
        return match[1] if match else MISSING

    @property
    def refused(self) -> bool:
        return self.rc != 0

    def refusal(self) -> str:
        match = re.search(r"((?:outcome|external claim) refused \(\w+\): .*?)(?:\. Status, dependents|$)", self.err + self.out, re.DOTALL)
        return match[1].strip()[:200] if match else (self.err.strip() or self.out.strip())[-200:]


def spawn(argv: Sequence[str], env: Mapping[str, str], timeout: float) -> Run:
    try:
        done = subprocess.run(list(argv), cwd=REPO, env=dict(env), stdin=subprocess.DEVNULL, capture_output=True,
                              text=True, encoding="utf-8", errors="replace", timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        return Run(124, "", f"timed out after {timeout:.0f}s")
    return Run(done.returncode, done.stdout, done.stderr)


@dataclass
class Gateway:
    sandbox: Sandbox
    token: str
    process: subprocess.Popen | None = None
    log: Any = None
    origin: str | None = None
    failure: str | None = None

    def start(self, timeout: float = 150.0) -> None:
        self.sandbox.default_home.joinpath("config.yaml").write_text(json.dumps(GATEWAY_CONFIG), encoding="utf-8")
        env = self.sandbox.env(self.sandbox.default_home, {"HERMES_DASHBOARD_SESSION_TOKEN": self.token})
        self.log = (self.sandbox.logs / "gateway.log").open("wb")
        self.process = subprocess.Popen([sys.executable, "-m", "hermes_cli.main", "gateway", "run"], cwd=REPO, env=env,
                                        stdin=subprocess.DEVNULL, stdout=self.log, stderr=subprocess.STDOUT)
        if str(REPO) not in sys.path:
            sys.path.insert(0, str(REPO))
        from gateway.control_socket import identify_gateway
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                self.failure = f"gateway exited with {self.process.returncode}"
                return
            found = identify_gateway(self.sandbox.default_home, timeout=2.0)
            if found and found.get("state") == "ready" and found.get("api_origin"):
                self.origin = found["api_origin"]
                return
            try:
                self.process.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                continue
        self.failure = f"gateway not ready after {timeout:.0f}s"

    def stop(self) -> None:
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        if self.log is not None:
            self.log.close()

    def call(self, calls: Sequence[tuple[str, dict]]) -> list[dict] | None:
        if self.origin is None:
            return None
        try:
            return asyncio.run(self._dial(calls))
        except (OSError, TimeoutError, ValueError, WebSocketException) as exc:
            self.failure = f"api/ws dial failed ({type(exc).__name__})"
            return None

    async def _dial(self, calls: Sequence[tuple[str, dict]]) -> list[dict]:
        from websockets.asyncio.client import connect
        url = self.origin.replace("http:", "ws:") + "/api/ws?token=" + self.token
        replies = []
        async with connect(url) as ws:
            for index, (method, params) in enumerate(calls, 1):
                await ws.send(json.dumps({"jsonrpc": "2.0", "id": index, "method": method, "params": params}))
                async with asyncio.timeout(30):
                    while True:
                        reply = json.loads(await ws.recv())
                        if reply.get("id") == index:
                            replies.append(reply)
                            break
        return replies


@dataclass(frozen=True)
class Target:
    pr_url: str
    head: str
    merge_commit: str

    @property
    def repo(self) -> str:
        return self.pr_url.removeprefix("https://github.com/").split("/pull/")[0]

    @property
    def wrong_head(self) -> str:
        return self.head[:-1] + ("0" if self.head[-1] != "0" else "1")


def _events(show: Any) -> list[dict]:
    return show.get("events", []) if isinstance(show, dict) else []


def _kinds(events: Sequence[dict]) -> list[str]:
    return [e.get("kind") for e in events]


def _last(events: Sequence[dict], kind: str) -> dict | None:
    return next((e for e in reversed(events) if e.get("kind") == kind), None)


class Probe:
    def __init__(self, sandbox: Sandbox, target: Target, redact: Redactor, github_token_env: str | None = None):
        self.sandbox, self.target, self.redact = sandbox, target, redact
        self.github_token_env = github_token_env
        self.slug = "probe-" + secrets.token_hex(4)
        self.gateway = Gateway(sandbox, secrets.token_urlsafe(24))
        redact.add(self.gateway.token)
        self.steps: list[Step] = []
        self.task_id: str | None = None
        self.run_id: int | None = None
        self.baseline_cursor: Any = MISSING
        self.evidence_digests: Any = MISSING

    def cli(self, *argv: str, profile: str = COORDINATOR, board: bool = True, timeout: float = 240.0) -> Run:
        env = self.sandbox.env(self.sandbox.profile_home(profile))
        prefix = ["--board", self.slug] if board else []
        return spawn([sys.executable, "-m", "hermes_cli.main", "kanban", *prefix, *argv], env, timeout)

    def hermes(self, *argv: str, home: Path, timeout: float = 240.0) -> Run:
        return spawn([sys.executable, "-m", "hermes_cli.main", *argv], self.sandbox.env(home), timeout)

    def show(self) -> Any:
        return self.cli("show", self.task_id, "--json").json()

    def add(self, step: Step) -> Step:
        self.steps.append(step)
        return step

    def setup_profiles(self) -> None:
        for name in (COORDINATOR, RIVAL):
            if self.sandbox.profile_home(name).exists():
                continue
            done = self.hermes("profile", "create", name, "--no-skills", home=self.sandbox.default_home)
            if done.refused:
                raise ProbeError(f"could not create scratch profile {name!r}: {self.redact(done.err.strip()[-200:])}")
        if self.github_token_env:
            self._install_github_login()

    def _install_github_login(self) -> None:
        token = os.environ.get(self.github_token_env or "", "").strip()
        if not token:
            raise ProbeError(f"--github-token-env {self.github_token_env} names an empty or unset variable")
        self.redact.add(token)
        fd = os.open(self.sandbox.profile_home(COORDINATOR) / ".env", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(f"GH_TOKEN={token}\n")

    def drop_github_login(self) -> None:
        (self.sandbox.profile_home(COORDINATOR) / ".env").unlink(missing_ok=True)

    def step_isolation(self, protected: Mapping[str, Path]) -> None:
        proof = spawn([sys.executable, "-c", ISOLATION_PROOF], self.sandbox.env(self.sandbox.profile_home(COORDINATOR)), 120)
        seen = proof.json() if isinstance(proof.json(), dict) else {}
        kanban = seen.get("kanban_home", MISSING)
        self.add(Step.judged("0", "isolation", [
            Check("hermes_home_in_scratch", str(self.sandbox.profile_home(COORDINATOR).resolve()), seen.get("hermes_home", MISSING)),
            Check("kanban_home_in_scratch", str(self.sandbox.kanban_home.resolve()), kanban),
            Check("home_in_scratch", str(self.sandbox.home.resolve()), seen.get("home", MISSING)),
            Check("bound_profile", COORDINATOR, seen.get("profile", MISSING)),
            Check("kanban_home_not_real", True, MISSING if kanban is MISSING else all(Path(kanban) != p for p in protected.values())),
        ]))

    def step_board(self) -> None:
        made = self.cli("boards", "create", self.slug, "--dispatch-mode", "external", "--name", "Kanban probe", board=False)
        listing = self.cli("boards", "list", "--json", board=False).json()
        row = next((b for b in listing if b.get("slug") == self.slug), {}) if isinstance(listing, list) else {}
        db_path = row.get("db_path")
        inside = MISSING if db_path is None else Path(db_path).resolve().is_relative_to(self.sandbox.kanban_home.resolve())
        self.add(Step.judged("1", "coordinator-owned board", [
            Check("created", 0, made.rc), Check("slug", self.slug, row.get("slug", MISSING)),
            Check("dispatch_mode", "external", row.get("dispatch_mode", MISSING)),
            Check("archived", False, row.get("archived", MISSING)), Check("db_inside_scratch", True, inside)]))

    def start_gateway(self) -> None:
        self.gateway.start()
        replies = self.gateway.call([("kanban.board.snapshot", {"board": self.slug})])
        if replies and "result" in replies[0]:
            self.baseline_cursor = replies[0]["result"].get("cursor", MISSING)

    def step_card(self) -> None:
        contract = json.dumps({"kind": "merged_pr", "repo": self.target.repo}, separators=(",", ":"))
        made = self.cli("create", "kanban probe card", "--assignee", COORDINATOR, "--outcome-contract", contract,
                        "--completion-contract", f"fleet-ci:{self.target.pr_url}", "--json")
        card = made.json() if isinstance(made.json(), dict) else {}
        self.task_id = card.get("id")
        try:
            stored = json.loads(card.get("outcome_contract") or "null")
        except ValueError:
            stored = None
        self.add(Step.judged("2", "governed card (merged PR outcome)", [
            Check("created", 0, made.rc), Check("task_id", True, MISSING if self.task_id is None else True),
            Check("status", "ready", card.get("status", MISSING)), Check("assignee", COORDINATOR, card.get("assignee", MISSING)),
            Check("outcome_contract", {"kind": "merged_pr", "repo": self.target.repo}, stored if stored else MISSING),
            Check("completion_contract", f"fleet-ci:{self.target.pr_url}", card.get("completion_contract", MISSING))],
            {"task_id": self.task_id or "unknown"}))

    def step_claim(self) -> None:
        claim = self.cli("claim", self.task_id, "--json", "--session", SESSION)
        body = claim.json() if isinstance(claim.json(), dict) else {}
        self.run_id = body.get("run_id")
        show = self.show()
        claimed = _last(_events(show), "claimed") or {}
        payload = claimed.get("payload") or {}
        lock = payload.get("lock", MISSING)
        lock_ok = MISSING if lock is MISSING else bool(re.fullmatch(rf"external:{COORDINATOR}:[0-9a-f]{{32}}", lock))
        self.add(Step.judged("3", "coordinator claim", [
            Check("claimed", 0, claim.rc), Check("run_id", True, MISSING if self.run_id is None else True),
            Check("executor", "external", payload.get("executor", MISSING)), Check("lock_shape", True, lock_ok),
            Check("profile", COORDINATOR, body.get("profile", MISSING)),
            Check("status", "running", (show.get("task") or {}).get("status", MISSING) if isinstance(show, dict) else MISSING)],
            {"run_id": self.run_id if self.run_id is not None else "unknown"}))

    def control_second_claimant(self) -> None:
        rival = self.cli("claim", self.task_id, "--json", profile=RIVAL)
        again = self.cli("claim", self.task_id, "--json")
        show = self.show()
        events = _events(show)
        self.add(Step.judged("3c", "control: second claimant loses", [
            Check("rival_refused", True, rival.refused), Check("rival_reason", "wrong_profile", rival.reason("external claim refused")),
            Check("same_profile_refused", True, again.refused),
            Check("claimed_events", 1, _kinds(events).count("claimed") if events else MISSING),
            Check("status", "running", (show.get("task") or {}).get("status", MISSING) if isinstance(show, dict) else MISSING)]))

    def complete(self, *extra: str) -> Run:
        return self.cli("complete", self.task_id, "--run-id", str(self.run_id), "--result", "kanban probe", *extra)

    def control_premature_complete(self) -> None:
        refused = self.complete()
        show = self.show()
        self.add(Step.judged("4a", "control: complete before evidence refused", [
            Check("refused", True, refused.refused), Check("code", "missing", refused.reason("outcome refused")),
            Check("status", "running", (show.get("task") or {}).get("status", MISSING) if isinstance(show, dict) else MISSING),
            Check("outcome_refused_events", True, MISSING if not isinstance(show, dict) else "outcome_refused" in _kinds(_events(show)))]))

    def attach(self, kind: str, payload: dict) -> int:
        return self.cli("evidence", "add", self.task_id, "--run-id", str(self.run_id), "--kind", kind,
                        "--json", json.dumps(payload, separators=(",", ":"))).rc

    def attach_wrong_head(self) -> list[int]:
        target = self.target
        return [self.attach("execution_ref", {"session_id": SESSION, "runtime": "kanban-isolated-probe"}),
                self.attach("pr_published", {"pr_url": target.pr_url, "head_sha": target.head}),
                self.attach("pr_merged", {"pr_url": target.pr_url, "head_sha": target.wrong_head,
                                          "merge_commit": target.merge_commit})]

    def control_wrong_head(self) -> None:
        refused = self.complete("--metadata", json.dumps({"published_pr": self.target.pr_url}))
        show = self.show()
        code = refused.reason("outcome refused")
        notes = {"detail": self.redact(refused.refusal())} if code == "unverifiable" else {}
        self.add(Step.judged("4b", "control: wrong head refused", [
            Check("refused", True, refused.refused),
            Check("code", "mismatch", MISSING if code == "unverifiable" else code),
            Check("status", "running", (show.get("task") or {}).get("status", MISSING) if isinstance(show, dict) else MISSING)], notes))

    def step_evidence(self, wrong_codes: Sequence[int]) -> None:
        target = self.target
        fixed = self.attach("pr_merged", {"pr_url": target.pr_url, "head_sha": target.head, "merge_commit": target.merge_commit})
        listed = self.cli("evidence", "list", self.task_id, "--json").json()
        rows = listed if isinstance(listed, list) else []
        self.evidence_digests = [r.get("digest") for r in rows] if rows else MISSING
        self.add(Step.judged("4", "evidence attached", [
            Check("recorded", [0, 0, 0, 0], [*wrong_codes, fixed]),
            Check("kinds", ["execution_ref", "pr_published", "pr_merged", "pr_merged"], [r.get("kind") for r in rows] if rows else MISSING),
            Check("producers", [COORDINATOR], sorted({r.get("producer_profile") for r in rows}) if rows else MISSING),
            Check("run_ids", [self.run_id], sorted({r.get("run_id") for r in rows}) if rows else MISSING)],
            {"digests": [d[:12] for d in self.evidence_digests] if rows else "unknown"}))

    def step_complete(self) -> None:
        done = self.complete("--metadata", json.dumps({"published_pr": self.target.pr_url}))
        show = self.show()
        events = _events(show)
        status = (show.get("task") or {}).get("status", MISSING) if isinstance(show, dict) else MISSING
        acceptance = (_last(events, "pr_acceptance") or {}).get("payload") or {}
        verified = ((_last(events, "outcome_verified") or {}).get("payload") or {}).get("verified") or {}
        ci_checks = acceptance.get("checks", [])
        notes = {"classification": acceptance.get("classification", "unknown"), "ci_checks": len(ci_checks),
                 "warning": self.redact(acceptance.get("warning") or "none"), "detail": self.redact(acceptance.get("detail") or done.refusal())}
        title = "completion accepted by CI-evidence policy"
        if done.refused and done.reason("outcome refused") == "unverifiable":
            return self._unknown_completion(title, "GitHub could not confirm the merge", notes)
        if done.refused and acceptance.get("classification") in ("auth", "infra"):
            return self._unknown_completion(title, f"GitHub acceptance read unavailable ({acceptance['classification']})", notes)
        self.add(Step.judged("5", title, [
            Check("completed", 0, done.rc), Check("status", "done", status),
            Check("verified_head", self.target.head, verified.get("head_sha", MISSING)),
            Check("verified_merge_commit", self.target.merge_commit, verified.get("merge_commit", MISSING)),
            Check("acceptance_ok", True, acceptance.get("ok", MISSING)),
            Check("ci_checks_read_at_least_1", True, len(ci_checks) >= 1 if acceptance else MISSING)], notes))

    def _unknown_completion(self, title: str, reason: str, notes: Mapping[str, Any]) -> None:
        self.add(Step.unknown("5", title, reason, {k: v for k, v in notes.items() if k == "detail"}))

    def step_rpc(self) -> None:
        title = "native read RPC over /api/ws"
        show = self.show()
        task = (show.get("task") or {}) if isinstance(show, dict) else {}
        cli_kinds = _kinds(_events(show))
        cli_evidence = self.cli("evidence", "list", self.task_id, "--json").json()
        cli_digests = [r.get("digest") for r in cli_evidence] if isinstance(cli_evidence, list) else MISSING
        base = {"board": self.slug}
        card = {**base, "task_id": self.task_id}
        calls = [("kanban.boards.list", {}), ("kanban.board.snapshot", base), ("kanban.card.get", card),
                 ("kanban.evidence.list", card), ("kanban.events.since", {**base, "cursor": self.baseline_cursor, "task_id": self.task_id}),
                 ("kanban.run", {**base, "task_id": self.task_id, "run_id": self.run_id or 1, "claim_lock": "probe"})]
        replies = self.gateway.call(calls) if self.baseline_cursor is not MISSING else None
        if replies is None or len(replies) != len(calls):
            reason = self.gateway.failure or "no baseline cursor from the gateway"
            self.add(Step.unknown("6", title, reason))
            self.add(Step.unknown("6w", "control: write verb kanban.run refused", reason))
            return
        results = [r.get("result", {}) for r in replies]
        boards = {b["scope"]["board"]: b for b in results[0].get("boards", [])}
        cards = {c["task_id"]: c for c in results[1].get("cards", [])}
        detail = results[2].get("detail") or {}
        events = results[4].get("events", [])
        self.add(Step.judged("6", title, [
            Check("board_listed_external", "external", (boards.get(self.slug) or {}).get("dispatch_mode", MISSING)),
            Check("snapshot_status", task.get("status", MISSING), (cards.get(self.task_id) or {}).get("status", MISSING)),
            Check("card_status", task.get("status", MISSING), (detail.get("lifecycle") or {}).get("status", MISSING)),
            Check("card_governed", True, (detail.get("card") or {}).get("governed", MISSING)),
            Check("evidence_digests", cli_digests, [e.get("digest") for e in results[3].get("evidence", [])] if results[3] else MISSING),
            Check("event_kinds", cli_kinds, [e.get("kind") for e in events] if results[4].get("state") == "ok" else MISSING)],
            {"status": task.get("status", "unknown"), "events": len(events)}))
        write = (replies[5].get("error") or {}).get("data") or {}
        self.add(Step.judged("6w", "control: write verb kanban.run refused", [
            Check("reason", "permission_denied", write.get("reason", MISSING))]))

    def run(self, protected: Mapping[str, Path]) -> list[Step]:
        self.setup_profiles()
        self.step_isolation(protected)
        self.step_board()
        self.start_gateway()
        self.step_card()
        if self.task_id is None:
            return self.steps
        self.step_claim()
        if self.run_id is None:
            return self.steps
        self.control_second_claimant()
        self.control_premature_complete()
        wrong_codes = self.attach_wrong_head()
        self.control_wrong_head()
        self.step_evidence(wrong_codes)
        self.step_complete()
        self.step_rpc()
        return self.steps


def _sha(value: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        raise argparse.ArgumentTypeError("must be 40 lowercase hex characters")
    return value


def _pr_url(value: str) -> str:
    if not re.fullmatch(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*", value):
        raise argparse.ArgumentTypeError("must be https://github.com/OWNER/REPO/pull/N")
    return value


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Exercise the Kanban provider end to end in an isolated scratch home and print a pass/fail table.",
        epilog="example: scripts/kanban_isolated_probe.py --home /path/to/scratch "
               "--pr-url https://github.com/tsnAnh/Pal/pull/139 "
               "--head 6e6a3d6204838fcddd47d5f479c47f390c562c94 "
               "--merge-commit b941dadad68e192698bf14dbf950da3af224f23e")
    parser.add_argument("--home", required=True, type=Path, help="scratch home: absent, empty or probe-marked")
    parser.add_argument("--pr-url", required=True, type=_pr_url, help="merged PR the card's outcome points at")
    parser.add_argument("--head", required=True, type=_sha, help="PR head sha")
    parser.add_argument("--merge-commit", required=True, type=_sha, help="PR merge commit sha")
    parser.add_argument("--github-token-env", metavar="NAME",
                        help="name of an env var holding a GitHub token, copied into the scratch coordinator profile's "
                             ".env for the run and removed afterwards; without it GitHub reads report unknown")
    parser.add_argument("--keep", action="store_true", help="leave the scratch home in place for inspection")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    sandbox = Sandbox(args.home.expanduser().resolve())
    protected = protected_roots(os.environ, Path.home())
    try:
        sandbox.prepare(protected)
    except IsolationError as exc:
        print(f"refused: {exc}", file=sys.stderr)
        return 2
    redact = Redactor()
    probe = Probe(sandbox, Target(args.pr_url, args.head, args.merge_commit), redact, args.github_token_env)
    try:
        steps = probe.run(protected)
    except ProbeError as exc:
        print(f"probe aborted: {redact(str(exc))}", file=sys.stderr)
        return 2
    finally:
        probe.gateway.stop()
        probe.drop_github_login()
        if not args.keep:
            sandbox.cleanup()
    print(render_table(steps, redact))
    if args.keep:
        print(f"scratch home kept: {sandbox.root}")
    return exit_code(steps)


if __name__ == "__main__":
    raise SystemExit(main())

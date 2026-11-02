from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable

import hermes_yaml as yaml

from tests.e2e.core.history._helpers import REPO_ROOT, child_env
from tests.fakes.fake_llm_provider import MODEL_ID, OFFER_VERSION

DEAD_URL = "http://127.0.0.1:9/mcp"
MARK_RE = re.compile(r"MARK_[A-Z0-9_]+")

SURFACES_PROBE = r"""
import json, os
from tools.skills_tool import skill_view, skills_list
from agent.prompt_builder import build_skills_system_prompt
from agent.skill_commands import build_skill_invocation_message
from cron.scheduler_prompt import _build_job_prompt

names = json.loads(os.environ["PROBE_NAMES"])
for n in names:
    skill_view(n)
listed = {s["name"] for s in json.loads(skills_list()).get("skills", [])}
index = build_skills_system_prompt() or ""
out = {}
for n in names:
    row = {"listed": n in listed, "indexed": n in index}
    row["view"] = json.loads(skill_view(n))
    row["view_file"] = json.loads(skill_view(n, file_path="references/notes.md"))
    try:
        row["slash"] = build_skill_invocation_message("/" + n, "go") or ""
    except Exception as exc:
        row["slash"] = ""
        row["slash_error"] = repr(exc)
    try:
        row["cron"] = _build_job_prompt({"id": "job1", "name": "j", "prompt": "run it", "skills": [n]})
    except Exception as exc:
        row["cron"] = ""
        row["cron_error"] = repr(exc)
    out[n] = row
emit(out)
"""

VISIBLE_PROBE = r"""
import json, re
from tools.skills_tool import skill_view, skills_list
rows = json.loads(skills_list()).get("skills", [])
out = {}
for r in rows:
    content = json.loads(skill_view(r["name"])).get("content", "")
    out[r["name"]] = sorted(set(re.findall(r"MARK_[A-Z0-9_]+", content)))
emit({k: v for k, v in out.items() if v})
"""

PRELUDE = "import json\ndef emit(o):\n    print('PROBE:' + json.dumps(o), flush=True)\n"


def marker_for(name: str) -> str:
    return "MARK_" + re.sub(r"[^A-Za-z0-9]", "_", name).upper()


def write_skill(
    skills_dir: Path, name: str, *, marker: str | None = None, connector: str | list[str] | None = None,
    dirname: str | None = None,
) -> str:
    marker = marker or marker_for(name)
    front: dict[str, Any] = {"name": name, "description": f"Use when probing {name}."}
    if connector is not None:
        front["connector"] = connector
    root = skills_dir / (dirname or name)
    (root / "references").mkdir(parents=True, exist_ok=True)
    (root / "SKILL.md").write_text(
        f"---\n{yaml.safe_dump(front, sort_keys=False)}---\n\n# {name}\n\nAlways follow {marker}.\n", encoding="utf-8")
    (root / "references" / "notes.md").write_text(f"REF_{marker}\n", encoding="utf-8")
    return marker


def tree_digest(root: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not root.exists():
        return out
    for p in sorted(root.rglob("*")):
        rel = p.relative_to(root).as_posix()
        if p.is_symlink():
            out[rel] = "link:" + os.readlink(p)
        elif p.is_dir():
            out[rel + "/"] = "dir"
        else:
            out[rel] = hashlib.sha256(p.read_bytes()).hexdigest()
    return out


def deep_merge(base: dict, patch: dict) -> dict:
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            deep_merge(base[key], value)
        else:
            base[key] = value
    return base


def base_config(base_url: str, model: str) -> dict[str, Any]:
    return {
        "model": {"provider": "custom", "base_url": base_url, "default": model, "context_length": 128000},
        "agent": {"api_max_retries": 1},
        "telemetry": {"shared_metrics": {"enabled": False, "send": False, "offer_version": OFFER_VERSION}},
        "updates": {"check": False},
        "models_dev": {"url": "http://127.0.0.1:9/api.json"},
        "skills": {"creation_nudge_interval": 0},
        "memory": {"nudge_interval": 0},
    }


ALL_WORLDS: list[World] = []


class World:
    def __init__(self, root: Path, base_url: str = "http://127.0.0.1:9/v1", *, adopt_default: bool = False) -> None:
        ALL_WORLDS.append(self)
        self.root = root
        self.home = root / "home"
        self.default = self.home / ".hermes"
        self.base_url = base_url
        self.workdir = root / "work"
        self.workdir.mkdir(parents=True, exist_ok=True)
        self.shim_dir = root / "shim"
        self.shim_dir.mkdir(parents=True, exist_ok=True)
        shim = self.shim_dir / "hermes"
        shim.write_text(
            f"#!/bin/sh\nPYTHONPATH={REPO_ROOT} exec {sys.executable} -m hermes_cli.main \"$@\"\n", encoding="utf-8")
        shim.chmod(0o755)
        if adopt_default:
            self.default.mkdir(parents=True, exist_ok=True)
        else:
            self.add_bot("default")

    @property
    def catalog(self) -> Path:
        return self.default / "shared" / "catalog"

    @property
    def shared_root(self) -> Path:
        return self.default / "shared"

    def home_of(self, bot: str) -> Path:
        return self.default if bot == "default" else self.default / "profiles" / bot

    def bots(self) -> list[str]:
        names = ["default"]
        profiles = self.default / "profiles"
        if profiles.is_dir():
            names += sorted(p.name for p in profiles.iterdir() if p.is_dir())
        return names

    def add_bot(
        self, name: str, *, skills: dict[str, dict[str, Any]] | None = None,
        mcp_servers: dict[str, dict[str, Any]] | None = None, disabled: Iterable[str] = (),
        model: str = MODEL_ID, extra: dict[str, Any] | None = None, tokens: Iterable[str] = (),
    ) -> Path:
        home = self.home_of(name)
        home.mkdir(parents=True, exist_ok=True)
        cfg = base_config(self.base_url, model)
        if disabled:
            cfg["skills"]["disabled"] = list(disabled)
        if mcp_servers:
            cfg["mcp_servers"] = mcp_servers
        if extra:
            deep_merge(cfg, extra)
        self.save_config(name, cfg)
        (home / ".env").write_text(
            f"OPENAI_API_KEY=sk-fake-e2e\nBOT_SECRET=secret-{name}\n", encoding="utf-8")
        (home / "auth.json").write_text(json.dumps({"bot": name, "refresh": f"refresh-{name}"}), encoding="utf-8")
        for skill_name, spec in (skills or {}).items():
            write_skill(home / "skills", skill_name, **spec)
        for server in tokens:
            self.write_token(name, server)
        return home

    def write_token(self, bot: str, server: str) -> None:
        tokens = self.home_of(bot) / "mcp-tokens"
        tokens.mkdir(parents=True, exist_ok=True)
        (tokens / f"{server}.json").write_text(json.dumps({"access_token": f"tok-{bot}-{server}"}), encoding="utf-8")

    def remove_token(self, bot: str, server: str) -> None:
        (self.home_of(bot) / "mcp-tokens" / f"{server}.json").unlink()

    def config(self, bot: str) -> dict[str, Any]:
        return yaml.safe_load((self.home_of(bot) / "config.yaml").read_text(encoding="utf-8")) or {}

    def save_config(self, bot: str, cfg: dict[str, Any]) -> None:
        (self.home_of(bot) / "config.yaml").write_text(yaml.safe_dump(cfg, sort_keys=False), encoding="utf-8")

    def update_config(self, bot: str, patch: dict[str, Any]) -> None:
        self.save_config(bot, deep_merge(self.config(bot), patch))

    def set_mcp_enabled(self, bot: str, server: str, enabled: bool) -> None:
        cfg = self.config(bot)
        cfg.setdefault("mcp_servers", {}).setdefault(server, {})["enabled"] = enabled
        self.save_config(bot, cfg)

    def disable_skill(self, bot: str, name: str) -> None:
        cfg = self.config(bot)
        disabled = cfg.setdefault("skills", {}).setdefault("disabled", [])
        if name not in disabled:
            disabled.append(name)
        self.save_config(bot, cfg)

    def enable_shared_layout(self) -> None:
        (self.catalog / "skills").mkdir(parents=True, exist_ok=True)
        (self.catalog / ".migrated").write_text("", encoding="utf-8")

    def catalog_skill(
        self, name: str, *, enabled_for: Iterable[str] = (), bundled: bool = False, **spec: Any,
    ) -> str:
        self.enable_shared_layout()
        marker = write_skill(self.catalog / "skills", name, **spec)
        if bundled:
            with (self.catalog / "skills" / ".bundled_manifest").open("a", encoding="utf-8") as handle:
                handle.write(f"{name}:e2e\n")
        for bot in enabled_for:
            self.enable_skill(bot, name)
        return marker

    def enable_skill(self, bot: str, name: str) -> None:
        cfg = self.config(bot)
        enabled = cfg.setdefault("skills", {}).setdefault("enabled", [])
        if name not in enabled:
            enabled.append(name)
        self.save_config(bot, cfg)

    def catalog_mcp(self) -> dict[str, Any]:
        path = self.catalog / "mcp_servers.yaml"
        return (yaml.safe_load(path.read_text(encoding="utf-8")) or {}) if path.exists() else {}

    def save_catalog_mcp(self, servers: dict[str, Any]) -> None:
        self.enable_shared_layout()
        (self.catalog / "mcp_servers.yaml").write_text(yaml.safe_dump(servers, sort_keys=False), encoding="utf-8")

    def env(self, bot: str, extra: dict[str, str] | None = None, cwd: Path | None = None) -> dict[str, str]:
        env = child_env(self.home, self.home_of(bot), cwd or self.workdir)
        env["PATH"] = f"{self.shim_dir}{os.pathsep}{os.environ.get('PATH', '')}"
        env.update(extra or {})
        return env

    def hermes(
        self, bot: str, *args: str, extra_env: dict[str, str] | None = None, timeout: float = 240.0,
        cwd: Path | None = None,
    ) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, "-m", "hermes_cli.main", *args], cwd=str(cwd or self.workdir),
            env=self.env(bot, extra_env, cwd), capture_output=True, text=True, timeout=timeout,
            stdin=subprocess.DEVNULL, check=False)

    def hermes_ok(self, bot: str, *args: str, **kw: Any) -> subprocess.CompletedProcess:
        proc = self.hermes(bot, *args, **kw)
        assert proc.returncode == 0, (
            f"hermes {' '.join(args)} rc={proc.returncode}\n{proc.stdout[-1500:]}\n{proc.stderr[-1500:]}")
        return proc

    def probe(self, bot: str, snippet: str, extra_env: dict[str, str] | None = None, timeout: float = 240.0) -> Any:
        proc = subprocess.run(
            [sys.executable, "-c", PRELUDE + snippet], cwd=str(self.workdir), env=self.env(bot, extra_env),
            capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL, check=False)
        assert proc.returncode == 0, f"probe as {bot} failed rc={proc.returncode}\n{proc.stderr[-3000:]}"
        lines = [ln for ln in proc.stdout.splitlines() if ln.startswith("PROBE:")]
        assert lines, f"probe as {bot} printed nothing\n{proc.stdout[-1500:]}\n{proc.stderr[-1500:]}"
        return json.loads(lines[-1][len("PROBE:"):])

    def surfaces(self, bot: str, names: Iterable[str], extra_env: dict[str, str] | None = None) -> dict[str, dict]:
        env = {"PROBE_NAMES": json.dumps(list(names)), **(extra_env or {})}
        return self.probe(bot, SURFACES_PROBE, env)

    def visible(self, bot: str) -> dict[str, list[str]]:
        return self.probe(bot, VISIBLE_PROBE)

    def visible_markers(self, bot: str) -> set[str]:
        return {m for marks in self.visible(bot).values() for m in marks}

    def owner_bots(self) -> list[str]:
        return [bot for bot in self.bots() if (self.home_of(bot) / "state.db").exists()]

    def profile_exists(self, name: str) -> bool:
        return (self.default / "profiles" / name).exists()


def view_text(row: dict) -> str:
    return json.dumps(row, ensure_ascii=False)


def allowed(row: dict, marker: str) -> list[str]:
    problems = []
    if not row["listed"]:
        problems.append("not listed")
    if not row["indexed"]:
        problems.append("not in system-prompt index")
    if not row["view"].get("success") or marker not in str(row["view"].get("content", "")):
        problems.append(f"skill_view denied: {view_text(row['view'])[:300]}")
    if not row["view_file"].get("success") or f"REF_{marker}" not in view_text(row["view_file"]):
        problems.append(f"skill_view file_path denied: {view_text(row['view_file'])[:300]}")
    if marker not in row["slash"]:
        problems.append(f"slash invocation did not load it ({row.get('slash_error', '')})")
    if marker not in row["cron"]:
        problems.append(f"cron prompt did not load it ({row.get('cron_error', '')})")
    return problems


def denied(row: dict, marker: str, connector_hint: str) -> list[str]:
    problems = []
    if row["listed"]:
        problems.append("listed")
    if row["indexed"]:
        problems.append("in system-prompt index")
    for key in ("view", "view_file"):
        body = row[key]
        if body.get("success") is not False:
            problems.append(f"{key} succeeded")
        if body.get("reason") != "connector_not_connected":
            problems.append(f"{key} reason={body.get('reason')!r}")
        if connector_hint not in str(body.get("error", "")):
            problems.append(f"{key} error does not mention {connector_hint!r}: {body.get('error')!r}")
        if marker in view_text(body):
            problems.append(f"{key} leaked the skill body")
    if marker in row["slash"]:
        problems.append("slash invocation loaded it")
    if marker in row["cron"]:
        problems.append("cron prompt loaded it")
    return problems

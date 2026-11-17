"""scripts/ci/swift_lint.py on real temp git repos with the real pinned SwiftLint."""

from __future__ import annotations

import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import threading
import zipfile
from functools import partial
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "swift_lint.py"
sys.path.insert(0, str(SCRIPT.parent))

import swift_lint as sl

CLEAN = "let greeting = \"hi\"\n"
BAD = "let greeting = \"hi\"   \n"


def _env() -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_") and k != "GITHUB_ACTIONS"}
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    return env


def _git(repo: Path, *args: str) -> str:
    proc = subprocess.run(["git", *args], cwd=repo, env=_env(), capture_output=True, text=True,
                          stdin=subprocess.DEVNULL, timeout=60, check=False)
    assert proc.returncode == 0, (args, proc.stderr)
    return proc.stdout.strip()


def _write(repo: Path, rel: str, text: str) -> None:
    path = repo / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


@pytest.fixture(scope="module")
def binary() -> Path:
    if (os.uname().sysname, os.uname().machine) not in sl.PINS:
        pytest.skip("no pinned SwiftLint build for this host")
    return sl.resolve_binary()


@pytest.fixture
def repo(tmp_path: Path, binary: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    for key in [k for k in os.environ if k.startswith("GIT_")] + ["GITHUB_ACTIONS"]:
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    root = tmp_path / "repo"
    root.mkdir()
    _git(root, "init", "-q", "-b", "main")
    _git(root, "config", "user.email", "t@example.invalid")
    _git(root, "config", "user.name", "t")
    for guard in (*sl.GUARDS, "scripts/ci/swift_fault_details_allowlist.txt"):
        _write(root, guard, (REPO / guard).read_text(encoding="utf-8"))
    _write(root, f"{sl.IOS}/{sl.CONFIG}", (REPO / sl.IOS / sl.CONFIG).read_text(encoding="utf-8"))
    _write(root, f"{sl.IOS}/App/Legacy.swift", BAD)
    _write(root, f"{sl.IOS}/App/Other.swift", CLEAN)
    subprocess.run([str(binary), "lint", "--quiet", "--strict", "--no-cache", "--config", sl.CONFIG,
                    "--write-baseline", sl.BASELINE, "."], cwd=root / sl.IOS, capture_output=True,
                   env={**os.environ, "SWIFTLINT_DISABLE_SOURCEKIT": "1"}, timeout=120, check=False)
    assert "Legacy.swift" in (root / sl.IOS / sl.BASELINE).read_text(encoding="utf-8")
    _git(root, "add", "-A")
    _git(root, "commit", "-qm", "base")
    _git(root, "checkout", "-qb", "feature")
    return root


@pytest.mark.allow_network
def test_new_violation_fails_and_its_fix_passes(repo: Path, binary: Path) -> None:
    _write(repo, f"{sl.IOS}/App/New.swift", BAD)
    code, report = sl.run(repo, None, None, binary)
    assert code == 1 and "New.swift" in report and "trailing_whitespace" in report
    _write(repo, f"{sl.IOS}/App/New.swift", CLEAN)
    assert sl.run(repo, None, None, binary)[0] == 0


@pytest.mark.allow_network
def test_baselined_violation_in_unchanged_file_does_not_fail(repo: Path, binary: Path) -> None:
    _write(repo, f"{sl.IOS}/App/Other.swift", CLEAN + "let other = 1\n")
    code, report = sl.run(repo, None, None, binary)
    assert code == 0, report


@pytest.mark.allow_network
def test_new_violation_in_changed_baselined_file_fails(repo: Path, binary: Path) -> None:
    _write(repo, f"{sl.IOS}/App/Legacy.swift", BAD + "let x = 1;\n")
    code, report = sl.run(repo, None, None, binary)
    assert code == 1 and "Legacy.swift" in report


@pytest.mark.allow_network
def test_committed_head_is_judged_against_base(repo: Path, binary: Path) -> None:
    _write(repo, f"{sl.IOS}/App/New.swift", BAD)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "bad")
    head = _git(repo, "rev-parse", "HEAD")
    assert sl.run(repo, None, head, binary)[0] == 1
    assert sl.run(repo, head, head, binary)[0] == 0


@pytest.mark.allow_network
def test_swift_guard_failure_fails_the_gate(repo: Path, binary: Path) -> None:
    _write(repo, f"{sl.IOS}/App/Brand.swift", 'let title = "Hermes"\n')
    code, report = sl.run(repo, None, None, binary)
    assert code == 1 and "Brand.swift" in report


@pytest.mark.allow_network
def test_stop_hook_blocks_on_red_and_honours_stop_hook_active(repo: Path, capsys: pytest.CaptureFixture[str],
                                                                monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(sl, "resolve_binary", lambda: sl._cache_dir() / sl.PINS[(os.uname().sysname,
                                                                                  os.uname().machine)][2])
    assert sl.stop_hook("{}", repo) == 0
    _write(repo, f"{sl.IOS}/App/New.swift", BAD)
    assert sl.stop_hook(json.dumps({"stop_hook_active": False}), repo) == 2
    assert "New.swift" in capsys.readouterr().err
    assert sl.stop_hook(json.dumps({"stop_hook_active": True}), repo) == 0
    _write(repo, f"{sl.IOS}/App/New.swift", CLEAN)
    assert sl.stop_hook("{}", repo) == 0


@pytest.mark.allow_network
def test_missing_binary_is_not_run_and_non_zero(repo: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _write(repo, f"{sl.IOS}/App/New.swift", CLEAN)
    monkeypatch.setattr(sl, "PINS", {})
    code, report = sl.run(repo, None, None)
    assert code == 2 and report.startswith("swift-lint NOT RUN")


def _serve(directory: Path) -> tuple[HTTPServer, str]:
    server = HTTPServer(("127.0.0.1", 0), partial(SimpleHTTPRequestHandler, directory=str(directory)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_port}/"


def test_download_is_checked_by_sha256(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("swiftlint-static", "#!/bin/sh\n")
    (tmp_path / "a.zip").write_bytes(buf.getvalue())
    server, url = _serve(tmp_path)
    try:
        key = (os.uname().sysname, os.uname().machine)
        monkeypatch.setattr(sl, "_RELEASE", url)
        monkeypatch.setattr(sl, "PINS", {key: ("a.zip", "0" * 64, "swiftlint-static")})
        with pytest.raises(sl.NotRun, match="sha256"):
            sl.resolve_binary(tmp_path / "bad")
        assert not (tmp_path / "bad" / "swiftlint-static").exists()
        good = hashlib.sha256(buf.getvalue()).hexdigest()
        monkeypatch.setattr(sl, "PINS", {key: ("a.zip", good, "swiftlint-static")})
        binary = sl.resolve_binary(tmp_path / "good")
        assert binary.is_file() and os.access(binary, os.X_OK)
    finally:
        server.shutdown()
    shutil.rmtree(tmp_path / "good")

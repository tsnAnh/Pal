import os
import shutil
import subprocess
import sys
from pathlib import Path


def _native_tool(name: str) -> str:
    """Resolve *name* to an executable CreateProcess can actually start.

    run_tests.sh / conftest blank SystemRoot/ComSpec for hermeticity, and on
    this host PATH can point ``git``/``bash`` at the MSIX payload copy under
    ``C:\\Program Files\\WindowsApps\\...`` — a store-app location that
    fails CreateProcess with WinError 5 outside its package context. Prefer
    a conventional install; give children a complete environment too.
    """
    candidates = [hit for hit in (shutil.which(name),) if hit]
    if sys.platform == "win32":
        git_base = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Git"
        for rel in (("cmd", f"{name}.exe"), ("bin", f"{name}.exe"), ("usr", "bin", f"{name}.exe")):
            p = git_base.joinpath(*rel)
            if p.exists():
                candidates.append(str(p))
    for cand in candidates:
        if "windowsapps" not in cand.lower():
            return cand
    return candidates[0]


def _child_env(**overrides: str) -> dict:
    env = os.environ.copy()
    if sys.platform == "win32":
        env.setdefault("SystemRoot", r"C:\Windows")
        env.setdefault("ComSpec", r"C:\Windows\system32\cmd.exe")
        env.setdefault("PATHEXT", ".COM;.EXE;.BAT;.CMD")
    env.update(overrides)
    return env


_GIT = _native_tool("git")
_BASH = _native_tool("bash")


def _git(*args: str, cwd: Path) -> str:
    out = subprocess.run(
        [_GIT, *args], cwd=cwd, capture_output=True, text=True, check=True,
        env=_child_env(),
    )
    return out.stdout.strip()


def _seed_repo(root: Path) -> tuple[Path, Path]:
    """origin (upstream) + clone (where releases are tagged from)."""
    origin = root / "origin"
    origin.mkdir()
    _git("init", "-b", "main", cwd=origin)
    _git("config", "user.email", "ci@example.com", cwd=origin)
    _git("config", "user.name", "ci", cwd=origin)
    (origin / "pyproject.toml").write_text('[project]\nname = "x"\nversion = "0.1.2"\n', encoding="utf-8")
    (origin / "README.md").write_text("seed\n", encoding="utf-8")
    _git("add", "-A", cwd=origin)
    _git("commit", "-m", "seed", cwd=origin)

    clone = root / "clone"
    _git("clone", str(origin), str(clone), cwd=root)
    _git("config", "user.email", "ci@example.com", cwd=clone)
    _git("config", "user.name", "ci", cwd=clone)
    return origin, clone

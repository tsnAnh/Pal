#!/usr/bin/env python3
"""Lint the Swift files a change touches: the pinned SwiftLint plus the Swift guards.

Only files changed against the merge-base are judged, and SwiftLint reads
``apps/ios/.swiftlint-baseline.json``, so violations already on main never fail; a new one in a
changed file does. The pinned binary is found in the cache or downloaded and checked by sha256.

    python scripts/ci/swift_lint.py                          # working tree vs merge-base with origin/main
    python scripts/ci/swift_lint.py --base A --head B        # any two revisions (scripts/check passes these)
    python scripts/ci/swift_lint.py --stop-hook              # Claude Code Stop hook: exit 2 blocks finishing
    python scripts/ci/swift_lint.py --write-baseline         # re-baseline (owner review only)

Exit codes: 0 = clean or no Swift change, 1 = violations, 2 = SwiftLint not run (see message).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

from scripts.code_health import gitio

VERSION = "0.63.2"
_RELEASE = f"https://github.com/realm/SwiftLint/releases/download/{VERSION}/"
# (os, machine) -> (asset, sha256, member). The Linux static build needs no Swift toolchain.
PINS = {
    ("Linux", "x86_64"): ("swiftlint_linux_amd64.zip",
                          "dd1017cfd20a1457f264590bcb5875a6ee06cd75b9a9d4f77cd43a552499143b",
                          "swiftlint-static"),
    ("Linux", "aarch64"): ("swiftlint_linux_arm64.zip",
                           "104dedff762157f5cff7752f1cc2a289b60f3ea677e72d651c6f3a3287fdd948",
                           "swiftlint-static"),
    ("Darwin", "x86_64"): ("portable_swiftlint.zip",
                           "c59a405c85f95b92ced677a500804e081596a4cae4a6a485af76065557d6ed29", "swiftlint"),
    ("Darwin", "arm64"): ("portable_swiftlint.zip",
                          "c59a405c85f95b92ced677a500804e081596a4cae4a6a485af76065557d6ed29", "swiftlint"),
}
IOS = "apps/ios"
CONFIG = ".swiftlint.yml"
BASELINE = ".swiftlint-baseline.json"
GUARDS = ("scripts/ci/check_swift_brand.py", "scripts/ci/check_swift_nav_chrome.py",
          "scripts/ci/check_swift_bot_tint.py", "scripts/ci/check_swift_chat_drop.py", "scripts/ci/check_swift_chat_scroll.py", "scripts/ci/check_swift_chat_row_alignment.py", "scripts/ci/check_swift_mac_layout.py", "scripts/ci/check_swift_glass.py",
          "scripts/ci/check_swift_image_viewer.py", "scripts/ci/check_swift_media_preview.py", "scripts/ci/check_swift_connection_card.py", "scripts/ci/check_swift_bot_settings.py", "scripts/ci/check_swift_perf.py", "scripts/ci/check_swift_fault_details.py",
          "scripts/ci/check_swift_icon_tint.py", "scripts/ci/check_swift_connect_palette.py", "scripts/ci/check_swift_glass_input.py")
FIX = "python scripts/ci/swift_lint.py --fetch"


class NotRun(RuntimeError):
    pass


def _cache_dir() -> Path:
    if sys.platform == "darwin":
        root = Path.home() / "Library" / "Caches"
    else:
        root = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    return root / "pal-swiftlint" / VERSION


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_binary(cache: Path | None = None) -> Path:
    key = (platform.system(), platform.machine())
    if key not in PINS:
        raise NotRun(f"no pinned SwiftLint {VERSION} build for {key[0]} {key[1]}")
    asset, sha, member = PINS[key]
    binary = (cache or _cache_dir()) / member
    if binary.is_file():
        return binary
    binary.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=binary.parent) as tmp:
        archive = Path(tmp) / asset
        try:
            with urllib.request.urlopen(_RELEASE + asset, timeout=120) as resp, archive.open("wb") as out:
                shutil.copyfileobj(resp, out)
        except OSError as exc:
            raise NotRun(f"could not download SwiftLint {VERSION} ({exc}); retry with `{FIX}`") from exc
        if _sha256(archive) != sha:
            raise NotRun(f"SwiftLint {VERSION} download failed its sha256 check; retry with `{FIX}`")
        with zipfile.ZipFile(archive) as zf:
            extracted = Path(zf.extract(member, tmp))
        extracted.chmod(0o755)
        os.replace(extracted, binary)
    return binary


def changed_swift(root: Path, base: str | None, head: str | None) -> list[str]:
    base = base or gitio.default_base(root, head if head and gitio.commit_or_none(root, head) else "HEAD")
    paths = {c.new for c in gitio.changed_files(root, base, head) if c.new}
    return sorted(p for p in paths if p.startswith(IOS + "/") and p.endswith(".swift")
                  and (root / p).is_file() and "/.build/" not in p)


def _swiftlint(binary: Path, root: Path, args: list[str]) -> subprocess.CompletedProcess[str]:
    # SourceKit exists only on a Mac; turning it off everywhere makes every host run one rule set.
    env = {**os.environ, "SWIFTLINT_DISABLE_SOURCEKIT": "1"}
    return subprocess.run([str(binary), "lint", "--quiet", "--strict", "--no-cache", "--config", CONFIG, *args],
                          cwd=root / IOS, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", stdin=subprocess.DEVNULL,
                          timeout=600, check=False)


def lint(root: Path, files: list[str], binary: Path) -> tuple[int, str]:
    rel = [p[len(IOS) + 1:] for p in files]
    proc = _swiftlint(binary, root, ["--baseline", BASELINE, *rel])
    report = [proc.stdout.strip()]
    failed = proc.returncode != 0
    if proc.returncode not in (0, 2):
        report.append(proc.stderr.strip())
    for guard in GUARDS:
        argv = [sys.executable, str(root / guard), str(root / IOS)]
        g = subprocess.run(argv, capture_output=True, text=True, encoding="utf-8", errors="replace",
                           stdin=subprocess.DEVNULL, timeout=300, check=False)
        if g.returncode != 0:
            failed = True
            report.append((g.stdout + g.stderr).strip())
    return (1 if failed else 0), "\n".join(r for r in report if r)


def run(root: Path, base: str | None, head: str | None, binary: Path | None = None) -> tuple[int, str]:
    if os.environ.get("GITHUB_ACTIONS") == "true":
        return 0, "swift-lint: not run in CI by design; the session-end gate and pre-push hook own SwiftLint"
    files = changed_swift(root, base, head)
    if not files:
        return 0, "swift-lint: no changed Swift files"
    try:
        binary = binary or resolve_binary()
    except NotRun as exc:
        return 2, f"swift-lint NOT RUN: {exc}"
    code, report = lint(root, files, binary)
    head_line = f"swift-lint: {len(files)} changed Swift file(s), SwiftLint {VERSION}"
    return code, f"{head_line}: {'ok' if code == 0 else 'FAILED'}\n{report}".rstrip()


def stop_hook(stdin: str, root: Path) -> int:
    try:
        payload = json.loads(stdin or "{}")
    except json.JSONDecodeError:
        payload = {}
    if payload.get("stop_hook_active"):
        return 0
    code, report = run(root, None, None)
    if code == 0:
        return 0
    print(f"{report}\nFix these before finishing, then rerun `python scripts/check --only swift-lint`.",
          file=sys.stderr)
    return 2


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base")
    parser.add_argument("--head")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--stop-hook", action="store_true")
    mode.add_argument("--fetch", action="store_true", help="download and verify the pinned binary")
    mode.add_argument("--write-baseline", action="store_true")
    args = parser.parse_args(argv)
    root = Path(gitio.git(Path.cwd(), "rev-parse", "--show-toplevel").strip())
    if args.stop_hook:
        return stop_hook(sys.stdin.read(), root)
    try:
        if args.fetch:
            print(resolve_binary())
            return 0
        if args.write_baseline:
            proc = _swiftlint(resolve_binary(), root, ["--write-baseline", BASELINE, "."])
            return 0 if proc.returncode in (0, 2) else proc.returncode
    except NotRun as exc:
        print(f"swift-lint NOT RUN: {exc}", file=sys.stderr)
        return 2
    code, report = run(root, args.base, args.head)
    print(report)
    return code


if __name__ == "__main__":
    raise SystemExit(main())

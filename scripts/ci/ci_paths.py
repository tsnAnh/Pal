"""Which CI jobs a change selects, and which paths each check reads.

Run: python3 scripts/ci/ci_paths.py --base REV [--head REV]   # key=value lines for $GITHUB_OUTPUT
     python3 scripts/ci/ci_paths.py --checks ios-guards        # the --only list for scripts/check

Globs use fnmatch, so ``*`` also matches ``/``. A job's rules are read in order and the last
matching rule wins; a path no rule matches does not select the job.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from fnmatch import fnmatchcase

Rule = tuple[str, bool]

_RUN_EVERYTHING: tuple[Rule, ...] = ((".github/*", True), ("scripts/check", True))
_OUTSIDE_IOS: tuple[Rule, ...] = (("*", True), ("apps/ios/*", False))

JOB_RULES: dict[str, tuple[Rule, ...]] = {
    "python": (*_OUTSIDE_IOS, ("apps/ios/*.py", True), *_RUN_EVERYTHING),
    "tooling-tests": (*_OUTSIDE_IOS, *_RUN_EVERYTHING),
    "ios-guards": (("apps/ios/*", True), *_RUN_EVERYTHING),
    "swift": (("apps/ios/*", True), (".github/workflows/swift.yml", True)),
    "faker-kit": ((".claude/skills/*", True), (".agents/skills/*", True),
                  ("scripts/link-skills.sh", True), *_RUN_EVERYTHING),
}

_PY = ("*.py", "*.pyi", "*.pyw")
CHECK_READS: dict[str, tuple[Rule, ...]] = {
    **{name: tuple((g, True) for g in _PY) for name in (
        "footguns", "detached-spawns", "install-root", "config-writers", "config-readers",
        "os-marker-fakes", "lazy-deps", "ruff", "health",
        # Upstream guards merged by the sync that read Python sources only.
        "backend-imports", "tool-discovery", "profile-create-entry")},
    "packaged-imports": (*((g, True) for g in _PY), ("pyproject.toml", True)),
    "shims": (*((g, True) for g in _PY), ("pyproject.toml", True), (".gitattributes", True)),
    "line-endings": (("*", True),),
    "dockerfile-downloads": (("Dockerfile", True), ("*/Dockerfile", True), ("*.Dockerfile", True)),
    "shebangs": (("*", True),),
    "no-tmp": tuple((f"*.{ext}", True) for ext in (
        "py", "sh", "bash", "ts", "tsx", "js", "mjs", "cjs", "md", "mdx", "txt", "yaml", "yml",
        "json", "toml")),
    "agents-md": (("AGENTS.md", True), ("*/AGENTS.md", True)),
    "case-collisions": (("*", True),),
    "profile-archives": (("*", True),),
    "blob-size": (("*", True),),
    "swift-brand": (("apps/ios/*.swift", True),),
    "swift-nav-chrome": (("apps/ios/*.swift", True),),
    "swift-bot-tint": (("apps/ios/*.swift", True),),
    "swift-chat-drop": (("apps/ios/*.swift", True),),
    "swift-chat-scroll": (("apps/ios/*.swift", True),),
    "swift-chat-row-alignment": (("apps/ios/*.swift", True),),
    "swift-mac-layout": (("apps/ios/*.swift", True),),
    "swift-modal-size": (("apps/ios/*.swift", True),),
    "swift-glass": (("apps/ios/*.swift", True), ("apps/ios/.glass-lint-baseline.json", True)),
    "swift-icon-tint": (("apps/ios/*.swift", True), ("scripts/ci/swift_icon_tint_allowlist.txt", True)),
    "swift-image-viewer": (("apps/ios/*.swift", True),),
    "swift-perf": (("apps/ios/*.swift", True), ("apps/ios/.perf-lint-*.json", True)),
    "swift-fault-details": (("apps/ios/*.swift", True), ("scripts/ci/swift_fault_details_allowlist.txt", True)),
    "swift-lint": (("apps/ios/*.swift", True), ("apps/ios/.swiftlint*", True)),
    "tooling-tests": _OUTSIDE_IOS,
}

ALL_CHECKS = tuple(name for name in CHECK_READS if name != "tooling-tests")
JOB_CHECKS: dict[str, tuple[str, ...]] = {
    "python": ALL_CHECKS,
    "tooling-tests": ("tooling-tests",),
    "ios-guards": ("shebangs", "no-tmp", "agents-md", "case-collisions", "profile-archives", "line-endings",
                   "blob-size", "swift-brand", "swift-nav-chrome", "swift-bot-tint", "swift-chat-drop", "swift-chat-scroll", "swift-chat-row-alignment", "swift-mac-layout", "swift-modal-size", "swift-glass",
                   "swift-icon-tint", "swift-image-viewer", "swift-perf", "swift-fault-details", "swift-lint"),
    "swift": (),
    "faker-kit": (),
}


def matches(rules: tuple[Rule, ...], path: str) -> bool:
    selected = False
    for glob, include in rules:
        if fnmatchcase(path, glob):
            selected = include
    return selected


def selected_jobs(paths: list[str] | None) -> dict[str, bool]:
    """``None`` means the change set is unknown, which runs everything."""
    if paths is None:
        return dict.fromkeys(JOB_RULES, True)
    return {job: any(matches(rules, p) for p in paths) for job, rules in JOB_RULES.items()}


def changed_paths(base: str, head: str) -> list[str] | None:
    if not base or set(base) == {"0"}:
        return None
    proc = subprocess.run(["git", "diff", "--name-only", f"{base}...{head}"],
                          capture_output=True, text=True, timeout=120, check=False)
    if proc.returncode != 0:
        print(f"ci_paths: git diff failed, running everything: {proc.stderr.strip()}",
              file=sys.stderr)
        return None
    return proc.stdout.splitlines() or None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ci_paths", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--base", help="base revision; empty or all zeros runs everything")
    mode.add_argument("--checks", choices=sorted(JOB_CHECKS), help="print a job's check list")
    parser.add_argument("--head", default="HEAD")
    args = parser.parse_args(argv)
    if args.checks:
        print(",".join(JOB_CHECKS[args.checks]))
        return 0
    for job, run in selected_jobs(changed_paths(args.base, args.head)).items():
        print(f"{job.replace('-', '_')}={str(run).lower()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

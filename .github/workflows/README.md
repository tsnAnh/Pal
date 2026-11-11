# GitHub Actions workflows

Three workflows, all on GitHub-hosted runners. The YAML is the source of truth.

| Workflow | Runs on | Starts on | Check name |
|---|---|---|---|
| `python.yml` | `ubuntu-latest` | every pull request, push to `main` | `python` |
| `swift.yml` | `macos-15` | pull requests and pushes to `main` that touch `apps/ios/**` or this workflow | `swift` |
| `faker-kit-checks.yml` | `ubuntu-latest` | every pull request | `kit` |

- `python`: `python scripts/check` (guards, pinned ruff, code-health ratchet) plus
  `scripts/run_tests.sh tests/ci tests/scripts`. The full pytest suite is not run: it is sized for
  32-vCPU runners. Two tests that are red on `main` and one 5-minute-plus test
  (`test_code_health_identity.py`) are excluded in the workflow.
- `swift`: XcodeGen, `xcodebuild build-for-testing` for the iOS Simulator and macOS, and
  `swift build --build-tests` for `Packages/HermesKit`. Builds only; the packages target macOS 26,
  which a `macos-15` host cannot launch.
- `kit`: `scripts/link-skills.sh --check .`.

Composite actions used: `.github/actions/setup-pm`, `.github/actions/retry`.

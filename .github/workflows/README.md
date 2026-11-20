# GitHub Actions workflows

Three workflows, all on GitHub-hosted runners. `python.yml` (named CI) holds one job graph: `changes` → `ios-guards` → `swift`, plus `python`, all gathered by the `ci` aggregator. The YAML is the source of truth.

| Workflow | Runs on | Starts on | Check name |
|---|---|---|---|
| `python.yml` | `ubuntu-latest`, `xcode-27` | every pull request, push to `main` | `changes`, `ios-guards`, `python`, `swift` (only when `apps/ios/**` or this workflow changed, and only after `ios-guards` passes), `ci` |
| `faker-kit-checks.yml` | `ubuntu-latest` | every pull request | `kit` |

- `python`: `python scripts/check` (guards, pinned ruff, code-health ratchet) plus
  `scripts/run_tests.sh tests/ci tests/scripts`. The full pytest suite is not run: it is sized for
  32-vCPU runners. Two tests that are red on `main` and one 5-minute-plus test
  (`test_code_health_identity.py`) are excluded in the workflow.
- `swift` (job in `python.yml`, needs `ios-guards`): XcodeGen, `xcodebuild build-for-testing` for the iOS Simulator and macOS, and
  `swift build --build-tests` for `Packages/HermesKit`. Builds only; the packages target macOS 26,
  which a `macos-15` host cannot launch.
- `kit`: `scripts/link-skills.sh --check .`.

Composite actions used: `.github/actions/setup-pm`, `.github/actions/retry`.

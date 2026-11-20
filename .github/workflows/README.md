# GitHub Actions workflows

Three workflows, all on GitHub-hosted runners. `python.yml` (named CI) holds one job graph: `changes` → `swift-build` (iOS Simulator, macOS, HermesKit in parallel) and `swift-variant`, alongside `ios-guards`, plus `python` (lint) and `tests` (8 slices of `tests/ci` and `tests/scripts`) and `gateway-harness`, all gathered by the `ci` aggregator. The YAML is the source of truth.

| Workflow | Runs on | Starts on | Check name |
|---|---|---|---|
| `python.yml` | `ubuntu-latest`, `xcode-27` | every pull request, push to `main` | `changes`, `ios-guards`, `python`, `swift` (the aggregator of `swift-build` and `swift-variant`, only when `apps/ios/**` or this workflow changed; it fails when `ios-guards` fails), `ci` |
| `faker-kit-checks.yml` | `ubuntu-latest` | every pull request | `kit` |

- `python`: `python scripts/check` (guards, pinned ruff, code-health ratchet); `tests`: eight parallel slices of
  `scripts/run_tests.sh tests/ci tests/scripts`; `gateway-harness`: the device and bot harness tests. The full pytest suite is not run: it is sized for
  32-vCPU runners. Two tests that are red on `main` and one 5-minute-plus test
  (`test_code_health_identity.py`) are excluded in the workflow.
- `swift-build`: XcodeGen, `xcodebuild build-for-testing` for the iOS Simulator and macOS, and
  `xcodebuild build-for-testing -scheme PalKit-Package` for `Packages/PalKit`; every Swift build reads and writes
  Xcode's content-addressed compile cache (`COMPILATION_CACHE_CAS_PATH`, restored from the latest cache of the week,
  saved on pushes to `main`), which needs the fixed `-derivedDataPath` the jobs pass. Builds only; the packages target macOS 26,
  which a `macos-15` host cannot launch.
- `kit`: `scripts/link-skills.sh --check .`.

Composite actions used: `.github/actions/setup-pm`, `.github/actions/retry`.

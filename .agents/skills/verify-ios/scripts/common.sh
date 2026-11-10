#!/usr/bin/env bash
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$SKILL_DIR/../../.." && pwd)"
IOS_DIR="$REPO/apps/ios"
EVIDENCE_ROOT="$IOS_DIR/Artifacts/verify-ios"
STATE_ROOT="${VERIFY_IOS_STATE_ROOT:-/tmp/verify-ios-state-$(id -u)/$(printf %s "$REPO" | shasum | cut -c1-12)}"
RUN_ENV="$STATE_ROOT/run.env"
BACKEND_ENV="$STATE_ROOT/backend.env"
OWNER="${VERIFY_IOS_OWNER:-verify-ios}"
LEDGER="$HOME/.claude/hooks/device-ledger.sh"
BUNDLE_ID="dev.tsnanh.hermes.bot"
RUNNER_ID="dev.tsnanh.hermes.bot.uitests.xctrunner"
LOG_SUBSYSTEM="dev.tsnanh.hermes.bot"
DERIVED="$IOS_DIR/build/DerivedData"
PYTHON="${HERMES_IOS_PYTHON:-$REPO/.venv/bin/python}"
MAX_SIMS="${CLAUDE_MAX_DEVICES:-4}"
JQ="$(command -v jq || echo /usr/bin/jq)"
SIM_DEVICES_DIR="$HOME/Library/Developer/CoreSimulator/Devices"
XCTEST_DEVICES_DIR="$HOME/Library/Developer/XCTestDevices"

say() { printf '%s\n' "$*"; }
die() { printf 'verify-ios: %s\n' "$*" >&2; exit 1; }

set_state() {
  local key="$1" value="$2" tmp
  mkdir -p "$STATE_ROOT"
  chmod 700 "$STATE_ROOT"
  tmp="$(mktemp "$STATE_ROOT/.run.XXXXXX")"
  { [ -f "$RUN_ENV" ] && grep -v "^$key=" "$RUN_ENV"; printf '%s=%q\n' "$key" "$value"; } >"$tmp" || true
  mv "$tmp" "$RUN_ENV"
  chmod 600 "$RUN_ENV"
}

load_run() {
  [ -f "$RUN_ENV" ] || die "no active run; start one with scripts/launch"
  set -a
  . "$RUN_ENV"
  set +a
}

load_backend() {
  [ -f "$BACKEND_ENV" ] || die "backend is not up; run scripts/launch"
  . "$BACKEND_ENV"
}

pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

stop_pid() {
  local pid="${1:-}" _
  pid_alive "$pid" || return 0
  kill "$pid" 2>/dev/null || return 0
  for _ in $(seq 40); do pid_alive "$pid" || return 0; sleep 0.5; done
  kill -9 "$pid" 2>/dev/null || true
}

strip_env_names() {
  local name
  while IFS= read -r name; do
    case "$name" in
      HERMES_IOS_*|HERMES_VERIFY_IOS_*) continue ;;
      HERMES_*|*_API_KEY|*_TOKEN|*_SECRET|*_PASSWORD|*_CREDENTIALS|*_ACCESS_KEY|*_PRIVATE_KEY|*_OAUTH_TOKEN) printf '%s\n' "$name" ;;
      ANTHROPIC_BASE_URL|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|CUSTOM_API_KEY|GEMINI_BASE_URL|OPENAI_BASE_URL|OPENROUTER_BASE_URL|OLLAMA_BASE_URL|GROQ_BASE_URL|XAI_BASE_URL) printf '%s\n' "$name" ;;
    esac
  done < <(compgen -e)
}

sandbox_profile_config() {
  if [ "$2" = "default" ]; then printf '%s/config.yaml\n' "$1"; else printf '%s/profiles/%s/config.yaml\n' "$1" "$2"; fi
}

clean_exec() {
  local args=() name
  while IFS= read -r name; do args+=(-u "$name"); done < <(strip_env_names)
  exec env ${args[@]+"${args[@]}"} "$@"
}

sim_state() {
  xcrun simctl list devices -j | "$JQ" -r --arg u "$1" '[.devices[][] | select(.udid == $u) | .state][0] // "Missing"'
}

booted_sims() {
  xcrun simctl list devices booted -j | "$JQ" -r '.devices[][] | select(.state == "Booted") | "\(.name) (\(.udid))"'
}

booted_count() { booted_sims | grep -c . || true; }

owned_udids() {
  bash "$LEDGER" mine --owner "$OWNER" 2>/dev/null | grep -Eo '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | sort -u
}

pick_sim() {
  local owned
  if [ -n "${VERIFY_IOS_UDID:-}" ]; then printf '%s\n' "$VERIFY_IOS_UDID"; return; fi
  owned="$(owned_udids | head -1)"
  if [ -n "$owned" ]; then printf '%s\n' "$owned"; return; fi
  xcrun simctl list devices available -j | "$JQ" -r '
    [ .devices | to_entries[] | select(.key | test("iOS")) | .key as $rt
      | .value[] | select(.name | test("iPhone")) | select(.name | test("Duo|Air|e$") | not)
      | select(.state == "Shutdown") | {udid, name, rt: $rt} ]
    | sort_by(.rt) | reverse
    | (map(select(.name | test("iPhone 17$"))) + .)[0].udid // empty'
}

disk_report() {
  du -sh "$SIM_DEVICES_DIR" "$XCTEST_DEVICES_DIR" 2>&1
}

disk_kb() {
  du -sk "$1" 2>/dev/null | awk '{print $1}'
}

xctest_clone_udids() {
  xcrun simctl --set "$XCTEST_DEVICES_DIR" list devices -j 2>/dev/null | "$JQ" -r '.devices[][] | .udid' | sort -u
}

#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
DEST=${1:?"usage: run.sh <sim-udid|macos> [test]"}
ONLY=${2:-}
xcodegen generate -q
OUT="$PWD/results/$([ "$DEST" = macos ] && echo macos || echo ios)"
mkdir -p "$OUT"
if [ "$DEST" = macos ]; then D='platform=macOS,arch=arm64'; else D="id=$DEST"; fi
FILTER=()
[ -n "$ONLY" ] && FILTER=(-only-testing:"ScrollSpikeUITests/SpikeUITests/$ONLY")
SPIKE_DIR="$OUT" TEST_RUNNER_SPIKE_DIR="$OUT" xcodebuild -scheme ScrollSpike -destination "$D" -derivedDataPath "/tmp/ss2-dd-$([ "$DEST" = macos ] && echo mac || echo ios)" \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -allowProvisioningUpdates \
  "${FILTER[@]}" test > "$OUT/xcodebuild.log" 2>&1
echo "xcodebuild exit $?"
grep -E "Test Case .* (passed|failed)" "$OUT/xcodebuild.log"
python3 -I analyze.py "$OUT"/spike-*.jsonl

#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
VARIANT=${1:?variant}
MODE=${2:-drive}
APP=${TMPDIR:?}/ss2-dd-mac/Build/Products/Debug/ScrollSpike.app
OUT="$PWD/../results/macos"
mkdir -p "$OUT"
[ wheel -nt wheel.swift ] || swiftc -O wheel.swift -o wheel
EXTRA=()
NAME="spike-$VARIANT"
if [ "$MODE" = stream ]; then EXTRA=(-appends YES); NAME="$NAME-stream"; fi
rm -f "$OUT/$NAME.jsonl" "$OUT/$NAME.jsonl.win"
open -n "$APP" --args -variant "$VARIANT" -total 400 -out "$OUT/$NAME.jsonl" ${EXTRA[@]+"${EXTRA[@]}"}
sleep 3
for i in $(seq 1 20); do [ -s "$OUT/$NAME.jsonl.win" ] && break; sleep 0.5; done
read -r CX CY < "$OUT/$NAME.jsonl.win"
echo "window center $CX $CY"
if [ "$MODE" = stream ]; then
  for i in $(seq 1 5); do ./wheel $CX $CY 20 12; sleep 6; done
else
  for i in $(seq 1 400); do
    grep -q '"event": *"done"' "$OUT/$NAME.jsonl" 2>/dev/null && break
    grep -q '"done"' "$OUT/$NAME.jsonl" 2>/dev/null && break
    if [ $((i % 3)) -eq 2 ]; then ./wheel $CX $CY 6 40 fling; else ./wheel $CX $CY 30 8; fi
    sleep 0.3
  done
fi
sleep 2
killall ScrollSpike 2>/dev/null
echo "lines: $(wc -l < "$OUT/$NAME.jsonl")"

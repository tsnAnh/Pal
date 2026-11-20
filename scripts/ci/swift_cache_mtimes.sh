#!/usr/bin/env bash
set -euo pipefail

cache_dir="${1:?usage: swift_cache_mtimes.sh <cache dir>}"
stamp="$cache_dir/.built-from"
old=202001010000

git ls-files -z | xargs -0 touch -c -t "$old"

[ -f "$stamp" ] || { echo "no cached build: building from scratch"; exit 0; }

from="$(cat "$stamp")"
if ! git fetch --no-tags --depth=1 --filter=blob:none origin "$from"; then
  echo "cached commit $from is gone: building from scratch"
  rm -rf "$cache_dir"
  exit 0
fi

git diff --name-only --no-renames -z "$from" HEAD | xargs -0 -r touch -c
echo "cached build from ${from:0:12}: $(git diff --name-only --no-renames "$from" HEAD | wc -l | tr -d ' ') changed paths marked newer"

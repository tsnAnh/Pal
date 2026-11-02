#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: link-skills.sh [--check] [REPO_DIR]

Make every project skill visible from both skill folders. A skill is a
directory holding SKILL.md in .claude/skills or .agents/skills.
Each real skill directory gets a relative symlink of the same name in the other
location. Existing links are kept; a real directory is never replaced.

  --check   Change nothing. Exit 1 and list what is missing or conflicting.

Examples:
  link-skills.sh                 # link skills in the current repo
  link-skills.sh --check .       # CI: fail when a skill is not linked
USAGE
}

check=0 repo=.
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) printf 'link-skills: unknown option %s. Run --help for usage.\n' "$1" >&2; exit 2 ;;
    *) repo=$1; shift ;;
  esac
done
cd "$repo"

locations=(.claude/skills .agents/skills)
problems=0 linked=0

for source_root in "${locations[@]}"; do
  [ -d "$source_root" ] || continue
  for skill in "$source_root"/*/; do
    skill=${skill%/}
    [ -f "$skill/SKILL.md" ] || continue
    [ -L "$skill" ] && continue
    name=${skill##*/}
    for target_root in "${locations[@]}"; do
      [ "$target_root" = "$source_root" ] && continue
      target="$target_root/$name"
      relative="../../$source_root/$name"
      if [ -L "$target" ]; then
        continue
      elif [ -e "$target" ]; then
        printf 'conflict: %s and %s are both real directories; keep one and delete the other\n' "$skill" "$target" >&2
        problems=$((problems + 1))
      elif [ "$check" -eq 1 ]; then
        printf 'missing: %s -> %s\n' "$target" "$relative" >&2
        problems=$((problems + 1))
      else
        mkdir -p "$target_root"
        ln -s "$relative" "$target"
        printf 'linked %s -> %s\n' "$target" "$relative"
        linked=$((linked + 1))
      fi
    done
  done
done

if [ "$problems" -gt 0 ]; then
  printf 'link-skills: %d problem(s). Run link-skills.sh without --check to fix missing links.\n' "$problems" >&2
  exit 1
fi
[ "$check" -eq 1 ] && printf 'link-skills: all skills linked\n' || printf 'link-skills: %d link(s) created\n' "$linked"

#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: install-kit-skills.sh [--ref REF] [--source URL_OR_DIR] [--checkout DIR] [--dest DIR]

Make faker-kit's skills available where plugins do not load, such as the
Hermes machine. Fetches the kit at REF into a checkout outside any repository and
symlinks every plugin skill into DEST. Nothing is written inside a repository, so
a task's diff stays clean.

hermes/install.sh runs it to keep the machine's kit checkout at the pinned commit.
Running it again moves the links to the new REF. A real directory, or a link
that points somewhere else, is never replaced.

  --ref REF          Branch, tag, or commit of the kit (default: main; pin a commit)
  --source SRC       Kit repository (default: https://github.com/tsnAnh/faker-kit.git)
  --checkout DIR     Where to keep the kit (default: $HOME/.faker-kit; a link into
                     any other folder counts as a conflict)
  --dest DIR         Where to link skills (default: $HOME/.agents/skills)

Examples:
  install-kit-skills.sh --ref 3ebb4e4
  install-kit-skills.sh --source ../faker-kit --dest /tmp/skills
USAGE
}

ref=main
source=https://github.com/tsnAnh/faker-kit.git
checkout="$HOME/.faker-kit"
dest="$HOME/.agents/skills"
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) ref=$2; shift 2 ;;
    --source) source=$2; shift 2 ;;
    --checkout) checkout=$2; shift 2 ;;
    --dest) dest=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'install-kit-skills: unknown argument %s. Run --help for usage.\n' "$1" >&2; exit 2 ;;
  esac
done

[ -d "$source" ] && source=$(cd "$source" && pwd)
mkdir -p "$checkout" "$dest"
checkout=$(cd "$checkout" && pwd)
[ -d "$checkout/.git" ] || git -C "$checkout" init -q
git -C "$checkout" fetch -q --depth 1 "$source" "$ref"
git -C "$checkout" checkout -q -f FETCH_HEAD
printf 'install-kit-skills: kit at %s\n' "$(git -C "$checkout" rev-parse --short HEAD)"

# trust-ladder first; team-workflows last, so thermos's copy of the review skill
# they share wins, as docs/catalog.json prefers.
plugins=(trust-ladder)
for dir in "$checkout"/plugins/*/; do
  name=${dir%/}; name=${name##*/}
  case "$name" in trust-ladder|team-workflows) ;; *) plugins+=("$name") ;; esac
done
[ -d "$checkout/plugins/team-workflows" ] && plugins+=(team-workflows)

linked=0 problems=0
# Parallel indexed arrays work on macOS's system Bash 3 as well as newer Bash.
seen_names=() seen_plugins=()
for plugin in "${plugins[@]}"; do
  for skill in "$checkout/plugins/$plugin/skills"/*/; do
    skill=${skill%/}
    [ -f "$skill/SKILL.md" ] || continue
    name=${skill##*/}
    provider=''
    for ((i = 0; i < ${#seen_names[@]}; i++)); do
      if [ "${seen_names[$i]}" = "$name" ]; then
        provider=${seen_plugins[$i]}
        break
      fi
    done
    if [ -n "$provider" ]; then
      printf 'skipped %s from %s: %s already provides it\n' "$name" "$plugin" "$provider"
      continue
    fi
    seen_names+=("$name")
    seen_plugins+=("$plugin")
    target="$dest/$name"
    if [ -L "$target" ]; then
      case "$(readlink "$target")" in
        "$checkout"/*) rm "$target" ;;
        *) printf 'conflict: %s links elsewhere; left as is\n' "$target" >&2; problems=$((problems + 1)); continue ;;
      esac
    elif [ -e "$target" ]; then
      printf 'conflict: %s is a real directory; left as is\n' "$target" >&2
      problems=$((problems + 1))
      continue
    fi
    ln -s "$skill" "$target"
    linked=$((linked + 1))
  done
done

for target in "$dest"/*; do
  [ -L "$target" ] || continue
  case "$(readlink "$target")" in
    "$checkout"/*) [ -e "$target" ] || { rm "$target"; printf 'removed stale %s\n' "$target"; } ;;
  esac
done

printf 'install-kit-skills: %d skill(s) linked into %s\n' "$linked" "$dest"
[ "$problems" -eq 0 ] || exit 1

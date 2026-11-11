#!/usr/bin/env bash
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ios_dir="$(cd "$package_dir/../.." && pwd)"
out="${1:-$ios_dir/Artifacts/avatar-loading}"
reference="$ios_dir/Design/avatar-loading-reference.mp4"
crop="crop=150:150:44:10,scale=160:160"

command -v ffmpeg >/dev/null || { echo "ffmpeg is required" >&2; exit 1; }
mkdir -p "$out"

(cd "$package_dir" && AVATAR_MOTION_ARTIFACTS="$out" swift test --filter AvatarMotionArtifacts)

for folder in "$out"/frames/*; do
  name="$(basename "$folder")"
  count="$(find "$folder" -name '*.png' | wc -l | tr -d ' ')"
  step=$((count / 12))
  ffmpeg -v error -y -framerate 30 -i "$folder/%04d.png" \
    -vf "select='not(mod(n\,$step))',scale=160:160,tile=12x1" -frames:v 1 "$out/$name-sheet.png"
  ffmpeg -v error -y -framerate 30 -i "$folder/%04d.png" \
    -c:v libx264 -pix_fmt yuv420p -crf 18 -movflags +faststart "$out/$name.mp4"
done

reference_sheet() {
  local start="$1" length="$2" target="$3"
  ffmpeg -v error -y -ss "$start" -t "$length" -i "$reference" \
    -vf "fps=12/$length,$crop,tile=12x1" -frames:v 1 "$target"
}

if [[ -f "$reference" ]]; then
  reference_sheet 6.1 11.5 "$out/reference-loading-sheet.png"
  reference_sheet 19.3 6.7 "$out/reference-done-sheet.png"
  for motion in loading done; do
    ffmpeg -v error -y \
      -i "$out/reference-$motion-sheet.png" \
      -i "$out/blob-$motion-sheet.png" \
      -i "$out/classic-$motion-sheet.png" \
      -i "$out/sigil-$motion-sheet.png" \
      -filter_complex "vstack=inputs=4" "$out/compare-$motion.png"
  done
fi

ls -1 "$out"

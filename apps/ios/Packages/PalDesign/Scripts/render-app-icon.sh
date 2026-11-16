#!/usr/bin/env bash
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
icon="$(cd "$package_dir/../.." && pwd)/App/AppIcon.icon"

(cd "$package_dir" && APP_ICON_OUTPUT="$icon" swift test --filter AppIconArtifact)
sips -g pixelWidth -g pixelHeight "$icon/Assets/pal.png"

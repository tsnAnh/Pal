#!/usr/bin/env bash
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ios_dir="$(cd "$package_dir/../.." && pwd)"
iconset="$ios_dir/App/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$iconset"

(cd "$package_dir" && APP_ICON_OUTPUT="$iconset/AppIcon.png" swift test --filter AppIconArtifact)

cat > "$ios_dir/App/Assets.xcassets/Contents.json" <<'JSON'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
cat > "$iconset/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "AppIcon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
sips -g pixelWidth -g pixelHeight -g hasAlpha "$iconset/AppIcon.png"

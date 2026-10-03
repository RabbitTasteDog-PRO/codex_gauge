#!/bin/bash
set -euo pipefail

# Build the standalone personal app without dependencies or installer permissions.
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
mkdir -p "$project_dir/.build/module-cache" "$project_dir/.build/cache"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.build/module-cache"
swift build -c release --disable-sandbox \
  --cache-path "$project_dir/.build/cache" \
  --config-path "$project_dir/.build/config" \
  --security-path "$project_dir/.build/security"
bin_dir="$(swift build -c release --show-bin-path --disable-sandbox --cache-path "$project_dir/.build/cache" --config-path "$project_dir/.build/config" --security-path "$project_dir/.build/security")"
app_dir="$project_dir/dist/Codex Gauge.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/CodexGauge" "$app_dir/Contents/MacOS/CodexGauge"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
mkdir -p "$app_dir/Contents/Resources/IdleCats"
cp "$project_dir/Resources/IdleCats/"*.png "$app_dir/Contents/Resources/IdleCats/"
if [ -f "$project_dir/Resources/AppIcon.icns" ]; then
  cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
fi
# Finder can add metadata to a previously opened generated bundle; it prevents signing.
xattr -dr com.apple.FinderInfo "$app_dir" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$app_dir" 2>/dev/null || true
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
printf 'Built: %s\n' "$app_dir"

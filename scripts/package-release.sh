#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

# The current build script uses an ad-hoc signature, not Developer ID notarization.
bash scripts/build-app.sh
app_dir="$project_dir/dist/Codex Gauge.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
case "$version" in
  ''|*[!0-9A-Za-z.+-]*) printf 'Invalid app version\n' >&2; exit 1 ;;
esac
architectures="$(/usr/bin/lipo -archs "$app_dir/Contents/MacOS/CodexGauge")"
case "$architectures" in
  arm64) architecture=arm64 ;;
  x86_64) architecture=x86_64 ;;
  'arm64 x86_64'|'x86_64 arm64') architecture=universal ;;
  *) printf 'Unsupported architectures: %s\n' "$architectures" >&2; exit 1 ;;
esac

release_dir="$project_dir/dist/releases/v$version"
mkdir -p "$release_dir"
archive_name="CodexGauge-$version-macos-$architecture.zip"
archive="$release_dir/$archive_name"
/usr/bin/codesign --verify --strict "$app_dir"
# Preserve bundle metadata and permissions; include only the app, never user credentials.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive"
(
  cd "$release_dir"
  /usr/bin/shasum -a 256 "$archive_name" > SHA256SUMS.txt
  /usr/bin/shasum -a 256 -c SHA256SUMS.txt
)

# Check the copy users actually extract, without launching it or changing any login.
verification_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-gauge-release-verify.XXXXXX")"
trap 'rm -rf "$verification_dir"' EXIT
/usr/bin/ditto -x -k "$archive" "$verification_dir"
extracted="$verification_dir/Codex Gauge.app"
test -x "$extracted/Contents/MacOS/CodexGauge"
test -s "$extracted/Contents/Resources/CatSpriteSheet.png"
extracted_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$extracted/Contents/Info.plist")"
test "$extracted_version" = "$version"
/usr/bin/codesign --verify --strict "$extracted"

printf '\nRelease ZIP: %s\nChecksum: %s\n' "$archive" "$release_dir/SHA256SUMS.txt"
printf 'Ad-hoc signed app; Codex CLI is required separately.\n'

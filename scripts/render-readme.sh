#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
mkdir -p .build/module-cache .build/cache docs/images
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.build/module-cache"
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
bin_dir="$(swift build --show-bin-path --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security)"
swiftc -parse-as-library -I "$bin_dir/Modules" \
  Sources/CodexGauge/UsageStore.swift Sources/CodexGauge/GaugeViews.swift Sources/CodexGauge/CatStatusRenderer.swift \
  scripts/render-readme.swift "$bin_dir"/UsageCore.build/*.o \
  -o .build/render-readme
.build/render-readme "$project_dir/docs/images"

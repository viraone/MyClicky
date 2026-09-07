#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
build_dir="$project_dir/.build"
app_dir="$build_dir/MyClicky.app"
cache_dir="${TMPDIR:-/private/tmp}/myclicky-module-cache"

cd "$project_dir"
SWIFTPM_MODULECACHE_OVERRIDE="$cache_dir" CLANG_MODULE_CACHE_PATH="$cache_dir" \
  swift build -c release --disable-sandbox

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/release/MyClicky" "$app_dir/Contents/MacOS/MyClicky"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
xattr -cr "$app_dir"
sign_identity=$(security find-identity -v -p codesigning | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/')
codesign --force --deep --sign "${sign_identity:--}" "$app_dir"

installed_app="/Applications/MyClicky.app"
# Quit any running copy first: `open` on an app that is already running only
# activates the old process, so a rebuild would otherwise never take effect.
osascript -e 'tell application id "com.local.MyClicky" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq MyClicky || break; sleep 0.3; done
rm -rf "$installed_app"
cp -R "$app_dir" "$installed_app"
open "$installed_app"

echo "$installed_app"

#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
build_dir="$project_dir/.build"
app_dir="$build_dir/MyClicky.app"
cache_dir="${TMPDIR:-/private/tmp}/myclicky-module-cache"

cd "$project_dir"

# On a `main` checkout, bring it up to date first so a rebuild never ships
# yesterday's code. Fast-forward only, and skipped if there are local edits
# to tracked files — never touch work in progress. Feature branches are left
# alone: they're built on purpose, at whatever commit they're at.
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ "$branch" == "main" ]] && git remote get-url origin >/dev/null 2>&1; then
  if git diff --quiet && git diff --cached --quiet; then
    before=$(git rev-parse --short HEAD)
    if git pull -q --ff-only origin main; then
      after=$(git rev-parse --short HEAD)
      if [[ "$before" != "$after" ]]; then
        echo "Pulled main: $before → $after"
      fi
    else
      echo "warning: couldn't fast-forward main; building $before as-is" >&2
    fi
  else
    echo "warning: main has uncommitted changes; skipping pull and building as-is" >&2
  fi
fi

# Xcode 26's default package build system ("swiftbuild") compiles SwiftTerm's
# Metal shader, which needs the separately downloaded Metal Toolchain and
# fails without it. The classic build system skips the shader, as every
# earlier build did. If `--build-system native` is ever removed, install the
# toolchain instead: `xcodebuild -downloadComponent MetalToolchain`.
SWIFTPM_MODULECACHE_OVERRIDE="$cache_dir" CLANG_MODULE_CACHE_PATH="$cache_dir" \
  swift build --build-system native -c release --disable-sandbox

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/release/MyClicky" "$app_dir/Contents/MacOS/MyClicky"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
sign_identity=$(security find-identity -v -p codesigning | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/')
# Finder (and iCloud-synced folders like Desktop) can re-tag files with
# metadata between the strip and the sign; one more strip-and-retry covers it.
for attempt in 1 2; do
  xattr -cr "$app_dir"
  if codesign --force --deep --sign "${sign_identity:--}" "$app_dir"; then break; fi
  [[ $attempt == 2 ]] && exit 1
  sleep 0.5
done

installed_app="/Applications/MyClicky.app"
# Quit any running copy first: `open` on an app that is already running only
# activates the old process, so a rebuild would otherwise never take effect.
osascript -e 'tell application id "com.local.MyClicky" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq MyClicky || break; sleep 0.3; done
rm -rf "$installed_app"
cp -R "$app_dir" "$installed_app"
open "$installed_app"

echo "$installed_app"

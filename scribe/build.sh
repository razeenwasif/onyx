#!/usr/bin/env bash
# Builds Scribe.app: the Rust core as a static library, the app icon (drawn by
# the Rust ink engine), then the SwiftUI app, assembled into a bundle.
#
#   ./build.sh              # writes dist/Scribe.app
#   ./build.sh out/dir      # or choose the output folder
#   ./build.sh --test       # run the Rust and Swift test suites, then build
#
# Needs Rust (cargo) and Xcode 16 or newer.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"

RUN_TESTS=0
OUT_DIR="dist"
for arg in "$@"; do
  case "$arg" in
    --test) RUN_TESTS=1 ;;
    *) OUT_DIR="$arg" ;;
  esac
done

# Keep Rust output inside the repo regardless of any global CARGO_TARGET_DIR,
# because Package.swift links target/release/libscribe_core.a from here.
export CARGO_TARGET_DIR="$ROOT/target"
# The app's deployment target. Applied to the Swift build only: exporting it
# for cargo makes the current Apple linker emit broken proc-macro dylibs.
DEPLOYMENT_TARGET=15.0

if [[ $RUN_TESTS == 1 ]]; then
  echo "==> Testing the Rust core"
  cargo test -p scribe-core
fi

echo "==> Building the Rust core"
cargo build --release -p scribe-core

echo "==> Drawing the app icon"
cargo run --release -q -p scribe-icon -- macos/Resources
iconutil -c icns macos/Resources/AppIcon.iconset -o macos/Resources/AppIcon.icns
rm -rf macos/Resources/AppIcon.iconset

if [[ $RUN_TESTS == 1 ]]; then
  echo "==> Testing the app"
  MACOSX_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET swift test
fi

echo "==> Building the app"
MACOSX_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET swift build -c release --arch arm64
BIN="$(MACOSX_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET swift build -c release --arch arm64 --show-bin-path)"

echo "==> Assembling Scribe.app"
APP="$OUT_DIR/Scribe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Scribe" "$APP/Contents/MacOS/Scribe"
cp macos/Resources/Info.plist "$APP/Contents/Info.plist"
cp macos/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftMath's fonts and maths tables.
for bundle in "$BIN"/*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# Ad-hoc signature so Gatekeeper treats the bundle as one unit locally.
codesign --force --deep --sign - "$APP" >/dev/null

echo
echo "==> Done: $APP"
du -sh "$APP" | cut -f1 | sed 's/^/    size: /'
cat <<'NOTE'

Open it with:  open dist/Scribe.app
Or copy it to /Applications. Notebooks live in ~/Documents/Scribe Notebooks.
NOTE

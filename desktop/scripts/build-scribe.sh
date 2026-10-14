#!/usr/bin/env bash
# Build Scribe for embedding in the desktop app (macOS only).
#
# Stages everything the app loads at runtime in desktop/scribe-embed/:
#   libScribeEmbed.dylib   Scribe's interface (../scribe), with its Rust core
#   *.bundle               its fonts and SwiftMath's maths tables
#   scribe-icon.png        for the app switcher
#   scribe_bridge.node     the addon that puts Scribe's view in the window
#
# Dev runs load from there; packaging copies it into the app (package.json).
# Needs Rust (cargo) and Xcode 16 or newer.

set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Scribe is macOS-only; skipping."
  exit 0
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scribe="$(cd "$here/../scribe" && pwd)"
out="$here/scribe-embed"

# Same settings as scribe/build.sh: Rust output stays in scribe/target (the
# Swift package links it from there), and the deployment target applies to
# the Swift build only.
export CARGO_TARGET_DIR="$scribe/target"
DEPLOYMENT_TARGET=15.0

echo "==> Building Scribe's Rust core"
(cd "$scribe" && cargo build --release -p scribe-core)

echo "==> Building libScribeEmbed"
(cd "$scribe" && MACOSX_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET swift build -c release --arch arm64 --product ScribeEmbed)
bin="$(cd "$scribe" && MACOSX_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET swift build -c release --arch arm64 --show-bin-path)"

echo "==> Building the scribe-bridge addon"
(cd "$here/native/scribe-bridge" && "$here/node_modules/.bin/node-gyp" rebuild --loglevel=warn)

echo "==> Staging in $out"
rm -rf "$out"
mkdir -p "$out"
cp "$bin/libScribeEmbed.dylib" "$out/"
for bundle in "$bin"/*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$out/"
done
cp "$scribe/docs/icon.png" "$out/scribe-icon.png"
cp "$here/native/scribe-bridge/build/Release/scribe_bridge.node" "$out/"

echo "Scribe staged."

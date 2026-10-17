#!/usr/bin/env bash
# Builds Scribe's Rust core for whatever the Xcode build targets (iPad or
# the simulator). Xcode runs this before compiling the app.
set -euo pipefail

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.."
export CARGO_TARGET_DIR="$PWD/target"
# Xcode exports its own deployment-target variables; the core only needs iOS's.
unset MACOSX_DEPLOYMENT_TARGET
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-18.0}"

case "${PLATFORM_NAME:-iphonesimulator}" in
  iphoneos) target=aarch64-apple-ios ;;
  *) target=aarch64-apple-ios-sim ;;
esac
cargo build --release -p scribe-core --target "$target"

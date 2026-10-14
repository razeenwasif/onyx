#!/usr/bin/env bash
# Install Electron Desktop for macOS.
# Copies Electron.app into /Applications (or ~/Applications), clears quarantine flags,
# and symlinks the CLI launcher 'electron-desktop' into ~/.local/bin or /usr/local/bin.
#
# Usage:
#   ./scripts/install-mac.sh             # Install to /Applications (or ~/Applications)
#   ./scripts/install-mac.sh --build     # Force rebuild first, then install
#   ./scripts/install-mac.sh --user      # Force install to ~/Applications
#   ./scripts/install-mac.sh --uninstall # Remove Electron.app and the CLI launcher

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Detect architecture
ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
  APP_BUILD_DIR="$here/release/mac-arm64/Electron.app"
elif [[ "$ARCH" == "x86_64" ]]; then
  APP_BUILD_DIR="$here/release/mac/Electron.app"
else
  APP_BUILD_DIR="$here/release/mac/Electron.app"
fi

# Fallback paths if universal or different directory structure
if [[ ! -d "$APP_BUILD_DIR" ]]; then
  if [[ -d "$here/release/mac-universal/Electron.app" ]]; then
    APP_BUILD_DIR="$here/release/mac-universal/Electron.app"
  elif [[ -d "$here/release/mac/Electron.app" ]]; then
    APP_BUILD_DIR="$here/release/mac/Electron.app"
  elif [[ -d "$here/release/mac-arm64/Electron.app" ]]; then
    APP_BUILD_DIR="$here/release/mac-arm64/Electron.app"
  fi
fi

# Determine target directory
TARGET_DIR="/Applications"
if [[ "${1:-}" == "--user" ]] || ! [ -w "/Applications" ]; then
  TARGET_DIR="$HOME/Applications"
fi

DEST_APP="$TARGET_DIR/Electron.app"

# Determine symlink directory for CLI
BIN_DIR="$HOME/.local/bin"
if [[ -w "/usr/local/bin" ]]; then
  BIN_DIR="/usr/local/bin"
fi
BIN_LINK="$BIN_DIR/electron-desktop"

uninstall() {
  echo "Uninstalling Electron Desktop..."
  rm -rf "/Applications/Electron.app" "$HOME/Applications/Electron.app"
  rm -f "$HOME/.local/bin/electron-desktop" "/usr/local/bin/electron-desktop"
  echo "Electron Desktop removed."
}

if [[ "${1:-}" == "--uninstall" ]]; then
  uninstall
  exit 0
fi

# Build if requested or if app doesn't exist
if [[ "${1:-}" == "--build" ]] || [[ ! -d "$APP_BUILD_DIR" ]]; then
  echo "Building Electron Desktop for macOS..."
  (cd "$here" && npm run build:scribe && npm run build && npx electron-builder --mac --dir)
  if [[ ! -d "$APP_BUILD_DIR" ]]; then
    if [[ -d "$here/release/mac-arm64/Electron.app" ]]; then
      APP_BUILD_DIR="$here/release/mac-arm64/Electron.app"
    elif [[ -d "$here/release/mac/Electron.app" ]]; then
      APP_BUILD_DIR="$here/release/mac/Electron.app"
    elif [[ -d "$here/release/mac-universal/Electron.app" ]]; then
      APP_BUILD_DIR="$here/release/mac-universal/Electron.app"
    fi
  fi
fi

if [[ ! -d "$APP_BUILD_DIR" ]]; then
  echo "Error: Built app not found at $APP_BUILD_DIR." >&2
  echo "Run 'npm run pack:mac' or './scripts/install-mac.sh --build' first." >&2
  exit 1
fi

mkdir -p "$TARGET_DIR" "$BIN_DIR"

echo "Installing Electron.app to $TARGET_DIR..."
# If Electron is currently running, warn or terminate
if pgrep -f "$DEST_APP/Contents/MacOS/Electron" >/dev/null 2>&1; then
  echo "Notice: Electron appears to be running. Closing it before replacing..."
  pkill -f "$DEST_APP/Contents/MacOS/Electron" || true
  sleep 1
fi

rm -rf "$DEST_APP"
cp -R "$APP_BUILD_DIR" "$DEST_APP"

# Clear quarantine and extended attributes for Gatekeeper
echo "Clearing quarantine attributes..."
xattr -cr "$DEST_APP" 2>/dev/null || true
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
touch "$DEST_APP"

# Link CLI
echo "Creating CLI shortcut at $BIN_LINK..."
ln -sf "$DEST_APP/Contents/MacOS/Electron" "$BIN_LINK"

echo ""
echo "============================================="
echo "  Electron Desktop installed successfully!"
echo "  Location: $DEST_APP"
echo "  CLI:      $BIN_LINK"
echo "============================================="
echo "Launch options:"
echo "  1. Open from Spotlight: Cmd+Space -> Electron"
echo "  2. Open from Launchpad or Finder -> Applications"
echo "  3. Open from Terminal:  electron-desktop [path/to/vault]"
echo ""

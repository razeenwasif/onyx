#!/usr/bin/env bash
# Install Electron Desktop for the current user — no root, no FUSE.
#
# The .deb needs sudo and the AppImage needs FUSE (which WSL doesn't have), so
# this copies the unpacked build into ~/.local and registers a desktop entry.
# Undo with --uninstall.

set -euo pipefail

APP_DIR="$HOME/.local/lib/Electron"
BIN_LINK="$HOME/.local/bin/electron-desktop"
ENTRY="$HOME/.local/share/applications/electron-desktop.desktop"
ICON_ROOT="$HOME/.local/share/icons/hicolor"
SIZES=(16 24 32 48 64 128 256 512)

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

uninstall() {
  rm -rf "$APP_DIR"
  rm -f "$BIN_LINK" "$ENTRY"
  for s in "${SIZES[@]}"; do rm -f "$ICON_ROOT/${s}x${s}/apps/electron-desktop.png"; done
  command -v update-desktop-database >/dev/null && update-desktop-database "$(dirname "$ENTRY")" || true
  echo "Electron Desktop removed."
}

if [[ "${1:-}" == "--uninstall" ]]; then
  uninstall
  exit 0
fi

if [[ ! -d "$here/release/linux-unpacked" ]]; then
  echo "No build found. Run 'npm run pack:linux' in $here first." >&2
  exit 1
fi

mkdir -p "$HOME/.local/bin" "$(dirname "$ENTRY")"
rm -rf "$APP_DIR"
cp -r "$here/release/linux-unpacked" "$APP_DIR"
ln -sf "$APP_DIR/electron-desktop" "$BIN_LINK"

for s in "${SIZES[@]}"; do
  mkdir -p "$ICON_ROOT/${s}x${s}/apps"
  cp "$here/build/icons/${s}x${s}.png" "$ICON_ROOT/${s}x${s}/apps/electron-desktop.png"
done

# `--enable-unsafe-swiftshader` only *permits* the software WebGL fallback;
# hardware GL is still used when it's available. Without it the graph view
# can't start on WSL or a VM.
cat > "$ENTRY" <<EOF
[Desktop Entry]
Type=Application
Name=Electron
GenericName=Markdown vault
Comment=Obsidian-style markdown vault with a graph view, canvas and local AI
Exec=$APP_DIR/electron-desktop --enable-unsafe-swiftshader %U
Icon=electron-desktop
Terminal=false
Categories=Office;TextEditor;
Keywords=notes;markdown;vault;graph;obsidian;electron;onyx;
MimeType=text/markdown;
StartupWMClass=Electron
StartupNotify=true
EOF
chmod +x "$ENTRY"

command -v update-desktop-database >/dev/null && update-desktop-database "$(dirname "$ENTRY")" || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -f -t "$ICON_ROOT" >/dev/null 2>&1 || true

echo "Installed to $APP_DIR"
echo "Launch from your application menu, or run: electron-desktop"

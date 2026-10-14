#!/usr/bin/env bash
# Unified macOS installer for Electron (Desktop App + Terminal TUI)
#
# Usage:
#   ./scripts/install-mac.sh              # Installs both Electron Desktop and Electron CLI
#   ./scripts/install-mac.sh --desktop    # Installs Electron Desktop (/Applications/Electron.app)
#   ./scripts/install-mac.sh --cli        # Installs Electron CLI (electron)
#   ./scripts/install-mac.sh --uninstall  # Uninstalls Electron Desktop and CLI
#
# Options:
#   --user     Install Desktop app to ~/Applications instead of /Applications
#   --build    Force rebuild before installing

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

INSTALL_DESKTOP=true
INSTALL_CLI=true
DO_UNINSTALL=false
FORCE_BUILD=false
USER_MODE=false

for arg in "$@"; do
  case "$arg" in
    --desktop)
      INSTALL_DESKTOP=true
      INSTALL_CLI=false
      ;;
    --cli)
      INSTALL_CLI=true
      INSTALL_DESKTOP=false
      ;;
    --uninstall)
      DO_UNINSTALL=true
      ;;
    --build)
      FORCE_BUILD=true
      ;;
    --user)
      USER_MODE=true
      ;;
    -h|--help)
      echo "Usage: ./scripts/install-mac.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --desktop    Install only Electron Desktop to /Applications"
      echo "  --cli        Install only Electron Terminal TUI to ~/.local/bin or ~/.cargo/bin"
      echo "  --user       Install Electron Desktop to ~/Applications instead of /Applications"
      echo "  --build      Force rebuild from source before installing"
      echo "  --uninstall  Uninstall Electron Desktop and CLI"
      echo "  --help       Show this help message"
      exit 0
      ;;
  esac
done

# Uninstall workflow
if [[ "$DO_UNINSTALL" == true ]]; then
  echo "==> Uninstalling Electron on macOS..."
  if [[ "$INSTALL_DESKTOP" == true ]]; then
    bash "$root/desktop/scripts/install-mac.sh" --uninstall
  fi
  if [[ "$INSTALL_CLI" == true ]]; then
    rm -f "$HOME/.local/bin/electron" "/usr/local/bin/electron" "$HOME/.cargo/bin/electron"
    echo "Removed Electron CLI binary."
  fi
  echo "Uninstall complete."
  exit 0
fi

echo "============================================="
echo "        Installing Electron on macOS"
echo "============================================="

# 1. Install CLI
if [[ "$INSTALL_CLI" == true ]]; then
  echo ""
  echo "==> Installing Electron Terminal TUI (CLI)..."
  if [[ "$FORCE_BUILD" == true ]] || [[ ! -f "$root/target/release/electron" ]]; then
    echo "Compiling electron with full features..."
    (cd "$root" && cargo build --release --features full)
  fi

  BIN_DIR="$HOME/.local/bin"
  if [[ -w "/usr/local/bin" ]]; then
    BIN_DIR="/usr/local/bin"
  fi
  mkdir -p "$BIN_DIR"

  cp "$root/target/release/electron" "$BIN_DIR/electron"
  chmod +x "$BIN_DIR/electron"
  echo "Installed 'electron' CLI to $BIN_DIR/electron"
fi

# 2. Install Desktop
if [[ "$INSTALL_DESKTOP" == true ]]; then
  echo ""
  echo "==> Installing Electron Desktop..."
  DESKTOP_FLAGS=()
  if [[ "$USER_MODE" == true ]]; then
    DESKTOP_FLAGS+=(--user)
  fi
  if [[ "$FORCE_BUILD" == true ]]; then
    DESKTOP_FLAGS+=(--build)
  fi
  bash "$root/desktop/scripts/install-mac.sh" "${DESKTOP_FLAGS[@]}"
fi

echo ""
echo "============================================="
echo "       Electron installation complete!"
echo "============================================="
if [[ "$INSTALL_DESKTOP" == true ]]; then
  echo " • Desktop app: Spotlight (Cmd+Space -> Electron) or /Applications/Electron.app"
  echo " • Desktop CLI: electron-desktop"
fi
if [[ "$INSTALL_CLI" == true ]]; then
  echo " • Terminal TUI: electron"
fi
echo "============================================="

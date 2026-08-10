#!/usr/bin/env bash
# Build the Windows installer from Linux.
#
# electron-builder patches the .exe's icon and version info with rcedit, which
# needs Wine. Rather than installing Wine system-wide, this runs the build in
# electron-builder's own image, which ships it. Artifacts land in ./release
# exactly as a native build would leave them.
#
# Runs as the invoking user so nothing in the repo ends up owned by root.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="electronuserland/builder:wine"
cache="$here/.docker-cache"

mkdir -p "$cache/electron" "$cache/electron-builder" "$cache/home"

# Each cache is mounted at its own top-level path rather than nested inside the
# HOME mount: Docker creates missing intermediate directories as root, which
# would leave root-owned junk in the working tree.
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp/ebhome \
  -e ELECTRON_CACHE=/tmp/ecache \
  -e ELECTRON_BUILDER_CACHE=/tmp/ebcache \
  -v "$here":/project \
  -v "$cache/home":/tmp/ebhome \
  -v "$cache/electron":/tmp/ecache \
  -v "$cache/electron-builder":/tmp/ebcache \
  -w /project \
  "$image" \
  /bin/bash -c "npx electron-vite build && npx electron-builder --win --publish never"

echo
echo "Windows artifacts:"
ls -la "$here/release"/*.exe "$here/release"/*.zip 2>/dev/null || echo "  (none found)"

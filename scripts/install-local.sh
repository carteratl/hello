#!/bin/bash
# install-local.sh — install the built package locally for testing.
# Equivalent to what the MDM/Blueprint does on a managed Mac.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/dist/StartupMovie.pkg"

[ -f "$PKG" ] || { echo "No package at $PKG. Run ./build.sh first." >&2; exit 1; }

echo "Installing $PKG (requires admin)..."
sudo installer -pkg "$PKG" -target /
echo
echo "Installed. To activate now without rebooting, log out and back in, or run:"
echo "    ./scripts/reset-state.sh   # so this boot counts as 'not yet played'"
echo "    launchctl bootstrap gui/\$(id -u) '/Library/LaunchAgents/com.principledproductions.startupmovie.plist'"
echo
echo "For a true boot test: restart the Mac and log in."

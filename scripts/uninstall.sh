#!/bin/bash
# uninstall.sh — remove Startup Movie from the local machine (development/testing).
set -euo pipefail

APP_NAME="Startup Movie"
LABEL="com.example.startupmovie"
APP_PATH="/Applications/${APP_NAME}.app"
AGENT_PLIST="/Library/LaunchAgents/${LABEL}.plist"
STATE_DIR="/Library/Application Support/${APP_NAME}"
PKG_ID="com.example.startupmovie.pkg"

echo "Unloading LaunchAgent for the current GUI user (if loaded)..."
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true

echo "Removing files (requires admin)..."
sudo rm -rf "$APP_PATH"
sudo rm -f  "$AGENT_PLIST"
sudo rm -rf "$STATE_DIR"
sudo rm -f "$HOME/Library/Application Support/${APP_NAME}/last-played-boot" 2>/dev/null || true

echo "Forgetting package receipt..."
sudo pkgutil --forget "$PKG_ID" 2>/dev/null || true

echo "Done. Startup Movie has been removed."

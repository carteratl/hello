#!/bin/bash
#
# install.sh — install Startup Movie on this Mac (manual deployment, no MDM).
#
# Copy this script and StartupMovie.pkg to the target Mac (same folder), then:
#
#     ./install.sh                # install; movie plays at the next restart + login
#     ./install.sh --play-now     # install and also run it right now (demo/verify)
#     ./install.sh /path/to.pkg   # install a pkg from a specific path
#     ./install.sh --uninstall    # remove everything this installed
#
# Run it in Terminal (do NOT double-click the .pkg — that triggers a Gatekeeper
# prompt for the unsigned package; the `installer` command used here does not).
# You'll be asked for an admin password once.

set -euo pipefail

APP_NAME="Startup Movie"
LABEL="com.principledproductions.startupmovie"
APP_PATH="/Applications/${APP_NAME}.app"
AGENT_PLIST="/Library/LaunchAgents/${LABEL}.plist"
STATE_FILE="/Library/Application Support/${APP_NAME}/last-played-boot"
PKG_ID="${LABEL}.pkg"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "This installer only runs on macOS."

# --- Uninstall path --------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
    info "Uninstalling ${APP_NAME}..."
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    sudo rm -rf "$APP_PATH" "$AGENT_PLIST" "/Library/Application Support/${APP_NAME}"
    sudo pkgutil --forget "$PKG_ID" 2>/dev/null || true
    ok "Removed."
    exit 0
fi

# --- Locate the package ----------------------------------------------------
PLAY_NOW=0
PKG=""
for arg in "$@"; do
    case "$arg" in
        --play-now) PLAY_NOW=1 ;;
        -h|--help)
            awk 'NR>2 && /^#/ {sub(/^# ?/,""); print; next} NR>2 {exit}' "${BASH_SOURCE[0]}"
            exit 0 ;;
        --*)        die "Unknown option: $arg" ;;
        *)          PKG="$arg" ;;
    esac
done
if [ -z "$PKG" ]; then
    for cand in "$SCRIPT_DIR/StartupMovie.pkg" "$SCRIPT_DIR/dist/StartupMovie.pkg" "./StartupMovie.pkg"; do
        [ -f "$cand" ] && { PKG="$cand"; break; }
    done
fi
[ -n "$PKG" ] && [ -f "$PKG" ] || die "Could not find StartupMovie.pkg. Put it next to this script, or pass its path: ./install.sh /path/to/StartupMovie.pkg"

info "Installing $PKG"

# Clear the download quarantine flag if the pkg was AirDropped/emailed/downloaded.
xattr -d com.apple.quarantine "$PKG" 2>/dev/null || true

# --- Install (this places the app, the LaunchAgent, and the state file) -----
sudo installer -pkg "$PKG" -target /

# --- Verify ----------------------------------------------------------------
[ -d "$APP_PATH" ]     || die "Install finished but $APP_PATH is missing."
[ -f "$AGENT_PLIST" ]  || die "Install finished but the LaunchAgent is missing."
ok "App installed at: $APP_PATH"
ok "LaunchAgent at:    $AGENT_PLIST"
ok "State file at:     $STATE_FILE"

# --- Arm --------------------------------------------------------------------
if [ "$PLAY_NOW" = "1" ]; then
    info "Arming for an immediate run (this boot)..."
    # Treat this boot as "not yet played", then load the agent now. RunAtLoad
    # fires immediately, so the movie plays right away.
    sudo sh -c ": > '$STATE_FILE'"
    launchctl bootout  "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
    ok "Launched now. (Press Esc to dismiss.) It will also play once at each future restart."
else
    echo
    ok "Done. The movie will play automatically at the next restart, right after login."
    echo "    (To see it immediately without rebooting, re-run: ./install.sh --play-now)"
fi

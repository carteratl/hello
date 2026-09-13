#!/bin/bash
# reset-state.sh — clear the once-per-boot guard so the movie will play again
# on the next launch/login WITHOUT needing to reboot. For development/testing.
set -euo pipefail

APP_NAME="Startup Movie"
MACHINE_STATE="/Library/Application Support/${APP_NAME}/last-played-boot"
USER_STATE="$HOME/Library/Application Support/${APP_NAME}/last-played-boot"

reset_one() {
    local f="$1"
    if [ -e "$f" ]; then
        if : > "$f" 2>/dev/null; then
            echo "cleared: $f"
        else
            echo "need sudo to clear: $f"
            sudo sh -c ": > '$f'" && echo "cleared (sudo): $f"
        fi
    fi
}

reset_one "$MACHINE_STATE"
reset_one "$USER_STATE"
echo "Done. The next launch will treat this boot as 'not yet played'."

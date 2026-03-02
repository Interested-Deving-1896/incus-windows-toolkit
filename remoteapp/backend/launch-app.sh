#!/usr/bin/env bash
# Launch a Windows application as a seamless Linux window via RemoteApp.
#
# Usage:
#   launch-app.sh <app-name-or-exe-path> [freerdp-args...]
#
# Examples:
#   launch-app.sh notepad
#   launch-app.sh "C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE"
#   launch-app.sh excel /drive:home,/home/user

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/incus-backend.sh"

APP="${1:?Usage: launch-app.sh <app-name-or-exe-path>}"
shift

# Ensure VM is running
if ! vm_is_running; then
    echo "VM not running. Starting..."
    vm_start
fi

# Wait for RDP
vm_wait_for_rdp

# If the argument doesn't look like a path, try to find the exe
if [[ "$APP" != *\\* && "$APP" != */* ]]; then
    # Try common exe names
    if [[ "$APP" != *.exe ]]; then
        APP="${APP}.exe"
    fi
    echo "Looking up: $APP"
    local_path=$(vm_find_exe "$APP" 2>/dev/null || true)
    if [[ -n "$local_path" ]]; then
        APP="$local_path"
        echo "Found: $APP"
    fi
fi

echo "Launching: $APP"
rdp_launch_remoteapp "$APP" "$@"

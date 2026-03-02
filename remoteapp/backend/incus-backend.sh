#!/usr/bin/env bash
# Incus backend for RemoteApp integration.
# Provides functions to query VM state, get RDP connection info,
# and manage the Windows VM lifecycle through Incus.
#
# Sourced by the remoteapp launcher -- not run directly.

set -euo pipefail

# --- Configuration ---

IWT_VM_NAME="${IWT_VM_NAME:-windows}"
IWT_RDP_PORT="${IWT_RDP_PORT:-3389}"
IWT_RDP_USER="${IWT_RDP_USER:-User}"
IWT_RDP_PASS="${IWT_RDP_PASS:-}"

# --- VM lifecycle ---

vm_exists() {
    incus info "$IWT_VM_NAME" &>/dev/null
}

vm_is_running() {
    local status
    status=$(incus info "$IWT_VM_NAME" 2>/dev/null | grep "^Status:" | awk '{print $2}')
    [[ "$status" == "RUNNING" ]]
}

vm_start() {
    if ! vm_is_running; then
        echo "Starting VM: $IWT_VM_NAME"
        incus start "$IWT_VM_NAME"
        vm_wait_for_agent
    fi
}

vm_stop() {
    if vm_is_running; then
        echo "Stopping VM: $IWT_VM_NAME"
        incus stop "$IWT_VM_NAME"
    fi
}

vm_wait_for_agent() {
    echo "Waiting for incus-agent..."
    local attempts=0
    while ! incus exec "$IWT_VM_NAME" -- cmd /c "echo ready" &>/dev/null; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 60 ]]; then
            echo "ERROR: Timed out waiting for agent after 60s" >&2
            return 1
        fi
        sleep 1
    done
    echo "Agent ready."
}

# --- Network info ---

vm_get_ip() {
    # Get the first IPv4 address from the VM
    incus info "$IWT_VM_NAME" 2>/dev/null | \
        grep -A1 "inet:" | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1
}

vm_wait_for_rdp() {
    local ip
    ip=$(vm_get_ip)
    [[ -n "$ip" ]] || { echo "ERROR: Cannot determine VM IP" >&2; return 1; }

    echo "Waiting for RDP on ${ip}:${IWT_RDP_PORT}..."
    local attempts=0
    while ! timeout 1 bash -c "echo >/dev/tcp/$ip/$IWT_RDP_PORT" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 120 ]]; then
            echo "ERROR: RDP not available after 120s" >&2
            return 1
        fi
        sleep 1
    done
    echo "RDP ready at ${ip}:${IWT_RDP_PORT}"
}

# --- RDP connection ---

rdp_connect_full() {
    local ip
    ip=$(vm_get_ip)
    [[ -n "$ip" ]] || { echo "ERROR: Cannot determine VM IP" >&2; return 1; }

    xfreerdp3 /v:"$ip":"$IWT_RDP_PORT" \
        /u:"$IWT_RDP_USER" \
        ${IWT_RDP_PASS:+/p:"$IWT_RDP_PASS"} \
        /dynamic-resolution \
        /gfx:AVC444 \
        /sound:sys:pulse \
        /microphone:sys:pulse \
        /clipboard \
        +auto-reconnect \
        "$@"
}

rdp_launch_remoteapp() {
    # Launch a single Windows application as a seamless Linux window
    local app_name="$1"
    shift
    local ip
    ip=$(vm_get_ip)
    [[ -n "$ip" ]] || { echo "ERROR: Cannot determine VM IP" >&2; return 1; }

    xfreerdp3 /v:"$ip":"$IWT_RDP_PORT" \
        /u:"$IWT_RDP_USER" \
        ${IWT_RDP_PASS:+/p:"$IWT_RDP_PASS"} \
        /app:"||$app_name" \
        /dynamic-resolution \
        /gfx:AVC444 \
        /sound:sys:pulse \
        /clipboard \
        +auto-reconnect \
        "$@"
}

# --- App discovery ---

vm_list_installed_apps() {
    # Query installed programs from the Windows registry via incus exec
    incus exec "$IWT_VM_NAME" -- powershell -Command '
        $paths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        Get-ItemProperty $paths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and $_.DisplayName -notmatch "Update|Hotfix" } |
            Select-Object DisplayName, InstallLocation |
            Sort-Object DisplayName |
            ForEach-Object { "$($_.DisplayName)|$($_.InstallLocation)" }
    '
}

vm_find_exe() {
    # Find an executable path inside the VM
    local exe_name="$1"
    incus exec "$IWT_VM_NAME" -- powershell -Command "
        \$paths = @(
            'C:\\Program Files',
            'C:\\Program Files (x86)',
            'C:\\Windows\\System32'
        )
        foreach (\$p in \$paths) {
            \$found = Get-ChildItem -Path \$p -Filter '$exe_name' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if (\$found) { Write-Output \$found.FullName; break }
        }
    "
}

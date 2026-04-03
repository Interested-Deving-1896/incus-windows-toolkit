#!/usr/bin/env bash
# Incus backend for RemoteApp integration.
# Provides functions to query VM state, get RDP connection info,
# and manage the Windows VM lifecycle through Incus.
#
# Sourced by the remoteapp launcher and CLI -- not run directly.

set -euo pipefail

# Source shared library if not already loaded
if [[ -z "${IWT_ROOT:-}" ]]; then
    IWT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
if ! declare -f info &>/dev/null; then
    source "$IWT_ROOT/cli/lib.sh"
fi

# --- Configuration ---

IWT_VM_NAME="${IWT_VM_NAME:-windows}"
IWT_RDP_PORT="${IWT_RDP_PORT:-3389}"
IWT_RDP_USER="${IWT_RDP_USER:-User}"
IWT_RDP_PASS="${IWT_RDP_PASS:-}"
IWT_RDP_TIMEOUT="${IWT_RDP_TIMEOUT:-120}"
IWT_AGENT_TIMEOUT="${IWT_AGENT_TIMEOUT:-60}"

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
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist. Create it with: iwt vm create --name $IWT_VM_NAME"
    fi

    if vm_is_running; then
        info "VM '$IWT_VM_NAME' is already running"
        return 0
    fi

    info "Starting VM: $IWT_VM_NAME"
    incus start "$IWT_VM_NAME"
    vm_wait_for_agent
}

vm_stop() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    if ! vm_is_running; then
        info "VM '$IWT_VM_NAME' is already stopped"
        return 0
    fi

    info "Stopping VM: $IWT_VM_NAME"
    incus stop "$IWT_VM_NAME"
    ok "VM stopped"
}

vm_wait_for_agent() {
    info "Waiting for incus-agent (timeout: ${IWT_AGENT_TIMEOUT}s)..."
    local attempts=0
    while ! incus exec "$IWT_VM_NAME" -- cmd /c "echo ready" &>/dev/null; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge $IWT_AGENT_TIMEOUT ]]; then
            die "Timed out waiting for agent after ${IWT_AGENT_TIMEOUT}s"
        fi
        sleep 1
    done
    ok "Agent ready"
}

# --- Network info ---

vm_get_ip() {
    # Get the first IPv4 address from the VM (skip loopback)
    local ip
    ip=$(incus info "$IWT_VM_NAME" 2>/dev/null | \
        grep -A1 "inet:" | grep -oP '\d+\.\d+\.\d+\.\d+' | \
        grep -v '^127\.' | head -1)

    if [[ -z "$ip" ]]; then
        # Fallback: try the network leases
        ip=$(incus network list-leases incusbr0 2>/dev/null | \
            grep "$IWT_VM_NAME" | awk '{print $3}' | head -1)
    fi

    echo "$ip"
}

vm_wait_for_rdp() {
    local ip
    ip=$(vm_get_ip)
    [[ -n "$ip" ]] || die "Cannot determine VM IP address. Is the VM running?"

    info "Waiting for RDP on ${ip}:${IWT_RDP_PORT} (timeout: ${IWT_RDP_TIMEOUT}s)..."
    local attempts=0
    while ! timeout 1 bash -c "echo >/dev/tcp/$ip/$IWT_RDP_PORT" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge $IWT_RDP_TIMEOUT ]]; then
            die "RDP not available after ${IWT_RDP_TIMEOUT}s. Check that RDP is enabled in the VM."
        fi
        # Print progress every 10 seconds
        if [[ $((attempts % 10)) -eq 0 ]]; then
            info "  Still waiting... (${attempts}s)"
        fi
        sleep 1
    done
    ok "RDP ready at ${ip}:${IWT_RDP_PORT}"
}

# --- RDP connection ---

# Detect available FreeRDP binary
_freerdp_cmd() {
    if command -v xfreerdp3 &>/dev/null; then
        echo "xfreerdp3"
    elif command -v xfreerdp &>/dev/null; then
        echo "xfreerdp"
    else
        die "FreeRDP not found. Install xfreerdp3 or xfreerdp."
    fi
}

rdp_connect_full() {
    local ip
    ip=$(vm_get_ip)
    [[ -n "$ip" ]] || die "Cannot determine VM IP"

    local rdp_cmd
    rdp_cmd=$(_freerdp_cmd)

    info "Connecting to $ip via $rdp_cmd"
    "$rdp_cmd" /v:"$ip":"$IWT_RDP_PORT" \
        /u:"$IWT_RDP_USER" \
        ${IWT_RDP_PASS:+/p:"$IWT_RDP_PASS"} \
        /dynamic-resolution \
        /gfx:AVC444 \
        /sound:sys:pulse \
        /microphone:sys:pulse \
        /clipboard \
        +auto-reconnect \
        /auto-reconnect-max-retries:5 \
        "$@"
}

rdp_launch_remoteapp() {
    # Launch a single Windows application as a seamless Linux window
    local app_name="$1"
    shift
    local ip
    ip=$(vm_get_ip)
    [[ -n "$ip" ]] || die "Cannot determine VM IP"

    local rdp_cmd
    rdp_cmd=$(_freerdp_cmd)

    info "Launching RemoteApp: $app_name"
    "$rdp_cmd" /v:"$ip":"$IWT_RDP_PORT" \
        /u:"$IWT_RDP_USER" \
        ${IWT_RDP_PASS:+/p:"$IWT_RDP_PASS"} \
        /app:"||$app_name" \
        /dynamic-resolution \
        /gfx:AVC444 \
        /sound:sys:pulse \
        /clipboard \
        +auto-reconnect \
        /auto-reconnect-max-retries:5 \
        "$@"
}

# --- App discovery ---

vm_list_installed_apps() {
    if ! vm_is_running; then
        die "VM '$IWT_VM_NAME' is not running. Start it first."
    fi

    incus exec "$IWT_VM_NAME" -- powershell -Command '
        $paths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        Get-ItemProperty $paths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and $_.DisplayName -notmatch "Update|Hotfix|KB\d+" } |
            Select-Object DisplayName, InstallLocation |
            Sort-Object DisplayName |
            ForEach-Object {
                $loc = if ($_.InstallLocation) { $_.InstallLocation } else { "(unknown)" }
                "$($_.DisplayName)|$loc"
            }
    '
}

vm_find_exe() {
    local exe_name="$1"

    if ! vm_is_running; then
        die "VM '$IWT_VM_NAME' is not running. Start it first."
    fi

    incus exec "$IWT_VM_NAME" -- powershell -Command "
        \$paths = @(
            'C:\\Program Files',
            'C:\\Program Files (x86)',
            'C:\\Windows\\System32',
            'C:\\Windows\\SysWOW64'
        )
        foreach (\$p in \$paths) {
            \$found = Get-ChildItem -Path \$p -Filter '$exe_name' -Recurse -ErrorAction SilentlyContinue -Depth 3 | Select-Object -First 1
            if (\$found) { Write-Output \$found.FullName; return }
        }
    "
}

# --- Icon extraction ---

vm_extract_icon() {
    # Extract an application icon from the VM and save it locally.
    # Returns the local path to the extracted icon.
    local exe_path="$1"
    local output_dir="${2:-$HOME/.local/share/icons/iwt}"

    mkdir -p "$output_dir"

    local icon_name
    icon_name=$(basename "$exe_path" .exe | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    local icon_file="$output_dir/${icon_name}.png"

    if [[ -f "$icon_file" ]]; then
        echo "$icon_file"
        return 0
    fi

    if ! vm_is_running; then
        warn "VM not running; cannot extract icon"
        echo ""
        return 1
    fi

    # Use PowerShell to extract the icon and base64 encode it
    local b64
    b64=$(incus exec "$IWT_VM_NAME" -- powershell -Command "
        Add-Type -AssemblyName System.Drawing
        try {
            \$icon = [System.Drawing.Icon]::ExtractAssociatedIcon('$exe_path')
            if (\$icon) {
                \$bmp = \$icon.ToBitmap()
                \$ms = New-Object System.IO.MemoryStream
                \$bmp.Save(\$ms, [System.Drawing.Imaging.ImageFormat]::Png)
                [Convert]::ToBase64String(\$ms.ToArray())
            }
        } catch {}
    " 2>/dev/null || true)

    if [[ -n "$b64" ]]; then
        echo "$b64" | base64 -d > "$icon_file"
        echo "$icon_file"
    else
        echo ""
    fi
}

# --- Snapshot management ---

snapshot_create() {
    local name="${1:-}"
    local stateful="${2:-false}"

    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    local args=()
    if [[ "$stateful" == true ]]; then
        if ! vm_is_running; then
            die "VM must be running for stateful snapshots"
        fi
        args+=(--stateful)
    fi

    if [[ -n "$name" ]]; then
        info "Creating snapshot: $IWT_VM_NAME/$name"
        incus snapshot create "$IWT_VM_NAME" "$name" "${args[@]}"
    else
        info "Creating snapshot of $IWT_VM_NAME (auto-named)"
        incus snapshot create "$IWT_VM_NAME" "${args[@]}"
    fi

    ok "Snapshot created"
}

snapshot_restore() {
    local name="$1"
    local stateful="${2:-false}"

    [[ -n "$name" ]] || die "Snapshot name required"

    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    local args=()
    if [[ "$stateful" == true ]]; then
        args+=(--stateful)
    fi

    # Warn if VM is running -- restore will stop it
    if vm_is_running; then
        warn "VM is running. It will be stopped before restore."
        incus stop "$IWT_VM_NAME" --force
    fi

    info "Restoring snapshot: $IWT_VM_NAME/$name"
    incus snapshot restore "$IWT_VM_NAME" "$name" "${args[@]}"
    ok "Snapshot restored: $name"
}

snapshot_delete() {
    local name="$1"

    [[ -n "$name" ]] || die "Snapshot name required"

    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    info "Deleting snapshot: $IWT_VM_NAME/$name"
    incus snapshot delete "$IWT_VM_NAME" "$name"
    ok "Snapshot deleted: $name"
}

snapshot_list() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    # Parse snapshot info from incus info output
    local snap_info
    snap_info=$(incus info "$IWT_VM_NAME" 2>/dev/null)

    local in_snapshots=false
    local snap_count=0

    while IFS= read -r line; do
        if [[ "$line" == "Snapshots:" ]]; then
            in_snapshots=true
            continue
        fi

        if [[ "$in_snapshots" == true ]]; then
            # End of snapshots section (next top-level key)
            if [[ "$line" =~ ^[A-Z] && "$line" != "  "* ]]; then
                break
            fi
            if [[ -n "$line" ]]; then
                echo "$line"
                snap_count=$((snap_count + 1))
            fi
        fi
    done <<< "$snap_info"

    if [[ $snap_count -eq 0 ]]; then
        info "No snapshots for $IWT_VM_NAME"
    fi
}

snapshot_schedule_set() {
    local schedule="$1"
    local expiry="${2:-}"
    local pattern="${3:-iwt-snap%d}"

    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    info "Setting snapshot schedule: $schedule"
    incus config set "$IWT_VM_NAME" snapshots.schedule "$schedule"
    incus config set "$IWT_VM_NAME" snapshots.pattern "$pattern"
    incus config set "$IWT_VM_NAME" snapshots.schedule.stopped false

    if [[ -n "$expiry" ]]; then
        info "Setting snapshot expiry: $expiry"
        incus config set "$IWT_VM_NAME" snapshots.expiry "$expiry"
    fi

    ok "Auto-snapshot configured"
}

snapshot_schedule_show() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    local schedule expiry pattern
    schedule=$(incus config get "$IWT_VM_NAME" snapshots.schedule 2>/dev/null || echo "(not set)")
    expiry=$(incus config get "$IWT_VM_NAME" snapshots.expiry 2>/dev/null || echo "(not set)")
    pattern=$(incus config get "$IWT_VM_NAME" snapshots.pattern 2>/dev/null || echo "(not set)")

    echo "VM:        $IWT_VM_NAME"
    echo "Schedule:  $schedule"
    echo "Expiry:    $expiry"
    echo "Pattern:   $pattern"
}

snapshot_schedule_disable() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    incus config unset "$IWT_VM_NAME" snapshots.schedule
    ok "Auto-snapshot disabled for $IWT_VM_NAME"
}

# --- Shared folder management ---

# Device name prefix for IWT-managed shares
_IWT_SHARE_PREFIX="iwt-share-"

share_add() {
    local host_path="$1"
    local share_name="${2:-}"
    local drive_letter="${3:-}"

    [[ -n "$host_path" ]] || die "Host path required"
    [[ -d "$host_path" ]] || die "Host path does not exist: $host_path"

    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    # Resolve to absolute path
    host_path=$(realpath "$host_path")

    # Auto-generate share name from directory basename if not provided
    if [[ -z "$share_name" ]]; then
        share_name=$(basename "$host_path" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
    fi

    local device_name="${_IWT_SHARE_PREFIX}${share_name}"

    # Check if device already exists
    if incus config device show "$IWT_VM_NAME" 2>/dev/null | grep -q "^${device_name}:"; then
        die "Share '$share_name' already exists on $IWT_VM_NAME. Remove it first."
    fi

    info "Adding shared folder: $host_path -> $share_name"
    incus config device add "$IWT_VM_NAME" "$device_name" disk \
        source="$host_path" \
        path="/shared/${share_name}"

    ok "Share added: $share_name ($host_path)"

    # If VM is running and a drive letter was requested, mount it now
    if [[ -n "$drive_letter" ]] && vm_is_running; then
        share_mount_in_guest "$share_name" "$drive_letter"
    elif [[ -n "$drive_letter" ]]; then
        info "Drive letter $drive_letter will be mapped when the VM starts."
        info "Run 'iwt vm share mount $share_name $drive_letter' after starting."
    fi
}

share_remove() {
    local share_name="$1"

    [[ -n "$share_name" ]] || die "Share name required"

    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    local device_name="${_IWT_SHARE_PREFIX}${share_name}"

    if ! incus config device show "$IWT_VM_NAME" 2>/dev/null | grep -q "^${device_name}:"; then
        die "Share '$share_name' not found on $IWT_VM_NAME"
    fi

    # Unmount in guest first if VM is running
    if vm_is_running; then
        share_unmount_in_guest "$share_name" || true
    fi

    info "Removing shared folder: $share_name"
    incus config device remove "$IWT_VM_NAME" "$device_name"
    ok "Share removed: $share_name"
}

share_list() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    local devices
    devices=$(incus config device show "$IWT_VM_NAME" 2>/dev/null)

    local found=false
    local current_device=""
    local current_source=""
    local current_path=""

    # Parse YAML output for iwt-share- devices
    while IFS= read -r line; do
        if [[ "$line" =~ ^${_IWT_SHARE_PREFIX}(.+):$ ]]; then
            # Print previous device if any
            if [[ -n "$current_device" ]]; then
                printf "  %-15s %-40s %s\n" "$current_device" "$current_source" "$current_path"
            fi
            current_device="${BASH_REMATCH[1]}"
            current_source=""
            current_path=""
            found=true
        elif [[ "$line" =~ ^[[:space:]]+source:[[:space:]]+(.+)$ ]]; then
            current_source="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]+path:[[:space:]]+(.+)$ ]]; then
            current_path="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[a-zA-Z] && ! "$line" =~ ^${_IWT_SHARE_PREFIX} ]]; then
            # New non-share device -- print last share if pending
            if [[ -n "$current_device" ]]; then
                printf "  %-15s %-40s %s\n" "$current_device" "$current_source" "$current_path"
                current_device=""
            fi
        fi
    done <<< "$devices"

    # Print last device
    if [[ -n "$current_device" ]]; then
        printf "  %-15s %-40s %s\n" "$current_device" "$current_source" "$current_path"
    fi

    if [[ "$found" == false ]]; then
        info "No shared folders on $IWT_VM_NAME"
    fi
}

share_mount_in_guest() {
    local share_name="$1"
    local drive_letter="$2"

    [[ -n "$share_name" ]] || die "Share name required"
    [[ -n "$drive_letter" ]] || die "Drive letter required (e.g. S)"

    if ! vm_is_running; then
        die "VM '$IWT_VM_NAME' must be running to mount shares"
    fi

    # Normalize drive letter to uppercase single char
    drive_letter=$(echo "$drive_letter" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z' | head -c1)
    [[ -n "$drive_letter" ]] || die "Invalid drive letter"

    info "Mounting share '$share_name' as ${drive_letter}: in guest"

    # Try virtiofs mount via WinFsp first, fall back to net use for 9p/agent shares
    incus exec "$IWT_VM_NAME" -- powershell -Command "
        \$ErrorActionPreference = 'Stop'

        # Method 1: Check if virtiofs tag is visible and WinFsp is installed
        \$winfspDir = 'C:\Program Files\WinFsp'
        \$virtiofsExe = 'C:\Program Files\VirtIO-FS\virtiofs.exe'

        if ((Test-Path \$winfspDir) -and (Test-Path \$virtiofsExe)) {
            Write-Host 'IWT: Mounting via VirtIO-FS + WinFsp'
            # Create a WinFsp mount using virtiofs
            & \$virtiofsExe -o uid=-1,gid=-1 -o volname=${share_name} ${drive_letter}:
            if (\$LASTEXITCODE -eq 0) {
                Write-Host 'IWT: Mounted ${share_name} as ${drive_letter}:'
                exit 0
            }
        }

        # Method 2: Use net use with the incus-agent share
        \$agentShare = '\\\\localhost\\${share_name}'
        try {
            net use ${drive_letter}: \$agentShare /persistent:yes 2>\$null
            Write-Host 'IWT: Mounted via net use as ${drive_letter}:'
            exit 0
        } catch {}

        # Method 3: Use subst as a last resort (maps a local path)
        \$localPath = 'C:\shared\\${share_name}'
        if (Test-Path \$localPath) {
            subst ${drive_letter}: \$localPath
            Write-Host 'IWT: Mounted via subst as ${drive_letter}:'
            exit 0
        }

        Write-Host 'IWT: WARNING - Could not mount share. WinFsp or VirtIO-FS may not be installed.'
        exit 1
    " || warn "Mount may have failed. Ensure WinFsp and VirtIO-FS are installed in the guest."

    ok "Share '$share_name' mapped to ${drive_letter}: in guest"
}

share_unmount_in_guest() {
    local share_name="$1"

    if ! vm_is_running; then
        return 0
    fi

    # Try to find and remove the drive mapping
    incus exec "$IWT_VM_NAME" -- powershell -Command "
        # Try net use removal
        \$drives = net use 2>\$null | Select-String '${share_name}'
        foreach (\$d in \$drives) {
            \$letter = (\$d -split '\s+')[1]
            if (\$letter -match '^[A-Z]:$') {
                net use \$letter /delete /yes 2>\$null
                Write-Host \"IWT: Unmounted \$letter\"
            }
        }

        # Try subst removal
        \$substs = subst 2>\$null | Select-String '${share_name}'
        foreach (\$s in \$substs) {
            \$letter = (\$s -split '=>')[0].Trim()
            subst \$letter /d 2>\$null
            Write-Host \"IWT: Removed subst \$letter\"
        }
    " 2>/dev/null || true
}

share_mount_all() {
    # Mount all configured shares using the drive map config
    local map_file="$IWT_ROOT/remoteapp/freedesktop/shares.conf"

    if [[ ! -f "$map_file" ]]; then
        info "No shares.conf found. Create one with 'iwt vm share config'."
        return 0
    fi

    if ! vm_is_running; then
        die "VM '$IWT_VM_NAME' must be running"
    fi

    local mounted=0
    while IFS='|' read -r name drive_letter; do
        [[ "$name" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$name" ]] && continue

        share_mount_in_guest "$name" "$drive_letter"
        mounted=$((mounted + 1))
    done < "$map_file"

    ok "Mounted $mounted shares"
}

# --- GPU management ---

gpu_list_host() {
    # List GPUs available on the host via incus info --resources
    if command -v incus &>/dev/null; then
        incus info --resources 2>/dev/null | awk '
            /^  GPUs:/,/^  [A-Z]/ {
                if (/^  GPUs:/) next
                if (/^  [A-Z]/ && !/GPU/) exit
                print
            }
        '
    fi

    # Fallback: lspci
    if command -v lspci &>/dev/null; then
        info "PCI GPU devices:"
        lspci -nn | grep -iE 'vga|3d|display' | sed 's/^/  /'
    fi
}

gpu_list_vm() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    info "GPUs attached to '$IWT_VM_NAME':"
    echo ""
    printf "  %-20s %-12s %s\n" "DEVICE" "TYPE" "PCI"
    printf "  %-20s %-12s %s\n" "------" "----" "---"

    local found=false
    while IFS= read -r dev; do
        [ -n "$dev" ] || continue
        local gtype pci
        gtype=$(incus config device get "$IWT_VM_NAME" "$dev" gputype 2>/dev/null || echo "physical")
        pci=$(incus config device get   "$IWT_VM_NAME" "$dev" pci     2>/dev/null || echo "")
        found=true
        printf "  %-20s %-12s %s\n" "$dev" "$gtype" "$pci"
    done < <(incus config device list "$IWT_VM_NAME" 2>/dev/null \
             | grep "gpu" | awk '{print $1}' || true)

    if ! $found; then
        info "  No GPU devices attached"
    fi
}

gpu_attach() {
    local gpu_type="${1:-physical}"
    local pci_addr="${2:-}"
    local vendor_id="${3:-}"
    local product_id="${4:-}"
    local mdev_profile="${5:-}"

    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    if vm_is_running; then
        die "VM must be stopped to attach a GPU (no hotplug support)"
    fi

    # Remove existing GPU device if present
    if incus config device show "$IWT_VM_NAME" 2>/dev/null | grep -q "^iwt-gpu:"; then
        info "Removing existing GPU device"
        incus config device remove "$IWT_VM_NAME" iwt-gpu
    fi

    local args=(type=gpu "gputype=$gpu_type")

    case "$gpu_type" in
        physical)
            [[ -n "$pci_addr" ]] && args+=("pci=$pci_addr")
            [[ -n "$vendor_id" ]] && args+=("vendorid=$vendor_id")
            [[ -n "$product_id" ]] && args+=("productid=$product_id")
            ;;
        mdev)
            [[ -n "$mdev_profile" ]] || die "mdev profile required (--mdev)"
            args+=("mdev=$mdev_profile")
            [[ -n "$pci_addr" ]] && args+=("pci=$pci_addr")
            ;;
        sriov)
            [[ -n "$pci_addr" ]] && args+=("pci=$pci_addr")
            [[ -n "$vendor_id" ]] && args+=("vendorid=$vendor_id")
            [[ -n "$product_id" ]] && args+=("productid=$product_id")
            ;;
        *)
            die "Unknown GPU type: $gpu_type (use physical, mdev, or sriov)"
            ;;
    esac

    info "Attaching $gpu_type GPU to $IWT_VM_NAME"
    incus config device add "$IWT_VM_NAME" iwt-gpu "${args[@]}"
    ok "GPU attached. Install GPU drivers in the guest after starting."
}

gpu_detach() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    if vm_is_running; then
        die "VM must be stopped to detach a GPU"
    fi

    if ! incus config device show "$IWT_VM_NAME" 2>/dev/null | grep -q "^iwt-gpu:"; then
        die "No IWT-managed GPU device on $IWT_VM_NAME"
    fi

    info "Detaching GPU from $IWT_VM_NAME"
    incus config device remove "$IWT_VM_NAME" iwt-gpu
    ok "GPU detached"
}

gpu_status() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    local devices
    devices=$(incus config device show "$IWT_VM_NAME" 2>/dev/null)

    # Check for any GPU device (IWT-managed or from profile)
    if echo "$devices" | grep -q "gputype:"; then
        echo "VM:       $IWT_VM_NAME"
        echo ""
        echo "$devices" | awk '
            /gputype:|type: gpu|pci:|vendorid:|productid:|mdev:/ { print "  " $0 }
            /^[a-z].*:$/ && /gpu/ { print $0 }
        '
    else
        info "No GPU device attached to $IWT_VM_NAME"
    fi
}

gpu_check_iommu() {
    info "Checking IOMMU status..."

    # Check kernel command line
    if grep -qE '(intel_iommu=on|amd_iommu=on)' /proc/cmdline 2>/dev/null; then
        ok "IOMMU enabled in kernel command line"
    else
        warn "IOMMU not found in kernel command line"
        warn "Add intel_iommu=on (Intel) or amd_iommu=on (AMD) to GRUB_CMDLINE_LINUX"
    fi

    # Check for IOMMU groups
    if [[ -d /sys/kernel/iommu_groups ]]; then
        local group_count
        group_count=$(find /sys/kernel/iommu_groups -maxdepth 1 -mindepth 1 -type d | wc -l)
        if [[ $group_count -gt 0 ]]; then
            ok "IOMMU active: $group_count groups found"
        else
            warn "IOMMU directory exists but no groups found"
        fi
    else
        err "No IOMMU groups found (/sys/kernel/iommu_groups missing)"
    fi

    # Check for vfio-pci module
    if lsmod 2>/dev/null | grep -q vfio_pci; then
        ok "vfio-pci module loaded"
    else
        warn "vfio-pci module not loaded (modprobe vfio-pci)"
    fi
}

gpu_show_iommu_groups() {
    # Show IOMMU groups with their devices -- helps identify which GPU to pass through
    if [[ ! -d /sys/kernel/iommu_groups ]]; then
        die "No IOMMU groups found. Enable IOMMU first."
    fi

    for group_dir in /sys/kernel/iommu_groups/*/devices/*; do
        [[ -e "$group_dir" ]] || continue
        local group
        group=$(echo "$group_dir" | grep -oP 'iommu_groups/\K[0-9]+')
        local pci_addr
        pci_addr=$(basename "$group_dir")
        local desc
        desc=$(lspci -nns "$pci_addr" 2>/dev/null || echo "unknown")
        printf "  Group %3s: %s %s\n" "$group" "$pci_addr" "$desc"
    done | sort -t: -k1 -n
}

looking_glass_check() {
    info "Checking looking-glass prerequisites..."

    local ok_count=0
    local fail_count=0

    # Check KVMFR module
    if [[ -c /dev/kvmfr0 ]]; then
        ok "KVMFR device (/dev/kvmfr0)"
        ok_count=$((ok_count + 1))
    elif [[ -f /dev/shm/looking-glass ]]; then
        ok "Shared memory file (/dev/shm/looking-glass)"
        ok_count=$((ok_count + 1))
    else
        err "No IVSHMEM device found (/dev/kvmfr0 or /dev/shm/looking-glass)"
        fail_count=$((fail_count + 1))
    fi

    # Check looking-glass client
    if command -v looking-glass-client &>/dev/null; then
        ok "looking-glass-client found"
        ok_count=$((ok_count + 1))
    else
        err "looking-glass-client not found"
        fail_count=$((fail_count + 1))
    fi

    # Check IOMMU
    gpu_check_iommu

    echo ""
    info "Results: $ok_count passed, $fail_count failed"
}

looking_glass_launch() {
    # Launch the looking-glass client
    if ! command -v looking-glass-client &>/dev/null; then
        die "looking-glass-client not found. Install from https://looking-glass.io"
    fi

    local lg_args=(
        -f /dev/kvmfr0
        -s
        -F
    )

    # Use /dev/shm fallback if kvmfr0 doesn't exist
    if [[ ! -c /dev/kvmfr0 ]] && [[ -f /dev/shm/looking-glass ]]; then
        lg_args=(-f /dev/shm/looking-glass -s -F)
    fi

    info "Launching looking-glass client"
    looking-glass-client "${lg_args[@]}" "$@"
}

# --- USB device management ---

# Device name prefix for IWT-managed USB devices
_IWT_USB_PREFIX="iwt-usb-"

usb_list_host() {
    # List USB devices on the host
    if command -v lsusb &>/dev/null; then
        lsusb | while IFS= read -r line; do
            # Format: Bus 001 Device 003: ID 046d:c52b Logitech, Inc. Unifying Receiver
            local bus dev vid pid desc
            bus=$(echo "$line" | grep -oP 'Bus \K[0-9]+')
            dev=$(echo "$line" | grep -oP 'Device \K[0-9]+')
            vid=$(echo "$line" | grep -oP 'ID \K[0-9a-f]{4}')
            pid=$(echo "$line" | grep -oP 'ID [0-9a-f]{4}:\K[0-9a-f]{4}')
            desc=$(echo "$line" | sed 's/.*ID [0-9a-f:]\+ //')
            printf "  %-4s:%-4s  Bus %s Dev %s  %s\n" "$vid" "$pid" "$bus" "$dev" "$desc"
        done
    else
        warn "lsusb not found. Install usbutils."
        # Fallback: read from sysfs
        for dev_dir in /sys/bus/usb/devices/[0-9]*-[0-9]*; do
            [[ -f "$dev_dir/idVendor" ]] || continue
            local vid pid product manufacturer
            vid=$(cat "$dev_dir/idVendor" 2>/dev/null || echo "????")
            pid=$(cat "$dev_dir/idProduct" 2>/dev/null || echo "????")
            product=$(cat "$dev_dir/product" 2>/dev/null || echo "unknown")
            manufacturer=$(cat "$dev_dir/manufacturer" 2>/dev/null || echo "")
            printf "  %s:%s  %s %s\n" "$vid" "$pid" "$manufacturer" "$product"
        done
    fi
}

usb_list_vm() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    local devices
    devices=$(incus config device show "$IWT_VM_NAME" 2>/dev/null)

    local found=false
    local current_device=""
    local current_vid=""
    local current_pid=""
    local current_required=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^${_IWT_USB_PREFIX}(.+):$ ]]; then
            if [[ -n "$current_device" ]]; then
                local req_str="required"
                [[ "$current_required" == "false" ]] && req_str="optional"
                printf "  %-20s %s:%s  (%s)\n" "$current_device" "$current_vid" "$current_pid" "$req_str"
            fi
            current_device="${BASH_REMATCH[1]}"
            current_vid=""
            current_pid=""
            current_required="true"
            found=true
        elif [[ "$line" =~ ^[[:space:]]+vendorid:[[:space:]]+(.+)$ ]]; then
            current_vid="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]+productid:[[:space:]]+(.+)$ ]]; then
            current_pid="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]+required:[[:space:]]+(.+)$ ]]; then
            current_required="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[a-zA-Z] && ! "$line" =~ ^${_IWT_USB_PREFIX} ]]; then
            if [[ -n "$current_device" ]]; then
                local req_str="required"
                [[ "$current_required" == "false" ]] && req_str="optional"
                printf "  %-20s %s:%s  (%s)\n" "$current_device" "$current_vid" "$current_pid" "$req_str"
                current_device=""
            fi
        fi
    done <<< "$devices"

    # Print last device
    if [[ -n "$current_device" ]]; then
        local req_str="required"
        [[ "$current_required" == "false" ]] && req_str="optional"
        printf "  %-20s %s:%s  (%s)\n" "$current_device" "$current_vid" "$current_pid" "$req_str"
    fi

    if [[ "$found" == false ]]; then
        info "No USB devices attached to $IWT_VM_NAME"
    fi
}

usb_attach() {
    local vendor_id="${1:-}"
    local product_id="${2:-}"
    local device_name="${3:-}"
    local required="${4:-true}"

    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    [[ -n "$vendor_id" ]] || die "Vendor ID required (e.g. 046d)"
    [[ -n "$product_id" ]] || die "Product ID required (e.g. c52b)"

    # Normalize: strip 0x prefix if present
    vendor_id="${vendor_id#0x}"
    product_id="${product_id#0x}"

    # Auto-generate device name if not provided
    if [[ -z "$device_name" ]]; then
        device_name="${vendor_id}-${product_id}"
    fi

    local full_name="${_IWT_USB_PREFIX}${device_name}"

    # Check if already attached
    if incus config device show "$IWT_VM_NAME" 2>/dev/null | grep -q "^${full_name}:"; then
        die "USB device '$device_name' already attached. Detach first or use a different --name."
    fi

    info "Attaching USB device ${vendor_id}:${product_id} as '$device_name'"

    incus config device add "$IWT_VM_NAME" "$full_name" usb \
        vendorid="$vendor_id" \
        productid="$product_id" \
        required="$required"

    if vm_is_running; then
        ok "USB device hotplugged into running VM"
    else
        ok "USB device attached (will connect when VM starts)"
    fi
}

usb_detach() {
    local device_name="$1"

    [[ -n "$device_name" ]] || die "Device name required"

    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    local full_name="${_IWT_USB_PREFIX}${device_name}"

    if ! incus config device show "$IWT_VM_NAME" 2>/dev/null | grep -q "^${full_name}:"; then
        die "USB device '$device_name' not found on $IWT_VM_NAME"
    fi

    info "Detaching USB device: $device_name"
    incus config device remove "$IWT_VM_NAME" "$full_name"

    if vm_is_running; then
        ok "USB device hot-removed from running VM"
    else
        ok "USB device detached"
    fi
}

usb_detach_all() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    local devices
    devices=$(incus config device show "$IWT_VM_NAME" 2>/dev/null)
    local removed=0

    while IFS= read -r line; do
        if [[ "$line" =~ ^(${_IWT_USB_PREFIX}.+):$ ]]; then
            local full_name="${BASH_REMATCH[1]}"
            info "Removing: $full_name"
            incus config device remove "$IWT_VM_NAME" "$full_name"
            removed=$((removed + 1))
        fi
    done <<< "$devices"

    if [[ $removed -eq 0 ]]; then
        info "No IWT USB devices to remove"
    else
        ok "Removed $removed USB device(s)"
    fi
}

# --- Networking ---

_IWT_FWD_PREFIX="iwt-fwd-"

net_forward_add() {
    local listen_port="$1"
    local connect_port="${2:-$listen_port}"
    local protocol="${3:-tcp}"
    local listen_addr="${4:-0.0.0.0}"
    local fwd_name="${5:-}"

    [[ -n "$listen_port" ]] || die "Listen port required"

    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    local vm_ip
    vm_ip=$(vm_get_ip)
    [[ -n "$vm_ip" ]] || die "Cannot determine VM IP. Is the VM running?"

    if [[ -z "$fwd_name" ]]; then
        fwd_name="${protocol}-${listen_port}"
    fi

    local device_name="${_IWT_FWD_PREFIX}${fwd_name}"

    if incus config device show "$IWT_VM_NAME" 2>/dev/null | grep -q "^${device_name}:"; then
        die "Forward '$fwd_name' already exists. Remove it first."
    fi

    info "Forwarding ${listen_addr}:${listen_port} -> ${vm_ip}:${connect_port} (${protocol})"

    incus config device add "$IWT_VM_NAME" "$device_name" proxy \
        "listen=${protocol}:${listen_addr}:${listen_port}" \
        "connect=${protocol}:${vm_ip}:${connect_port}" \
        nat=true

    ok "Port forward added: $fwd_name"
}

net_forward_remove() {
    local fwd_name="$1"

    [[ -n "$fwd_name" ]] || die "Forward name required"

    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    local device_name="${_IWT_FWD_PREFIX}${fwd_name}"

    if ! incus config device show "$IWT_VM_NAME" 2>/dev/null | grep -q "^${device_name}:"; then
        die "Forward '$fwd_name' not found on $IWT_VM_NAME"
    fi

    info "Removing port forward: $fwd_name"
    incus config device remove "$IWT_VM_NAME" "$device_name"
    ok "Port forward removed: $fwd_name"
}

net_forward_remove_all() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    local devices
    devices=$(incus config device show "$IWT_VM_NAME" 2>/dev/null)
    local removed=0

    while IFS= read -r line; do
        if [[ "$line" =~ ^(${_IWT_FWD_PREFIX}.+):$ ]]; then
            local full_name="${BASH_REMATCH[1]}"
            info "Removing: $full_name"
            incus config device remove "$IWT_VM_NAME" "$full_name"
            removed=$((removed + 1))
        fi
    done <<< "$devices"

    if [[ $removed -eq 0 ]]; then
        info "No IWT port forwards to remove"
    else
        ok "Removed $removed port forward(s)"
    fi
}

net_forward_list() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    local devices
    devices=$(incus config device show "$IWT_VM_NAME" 2>/dev/null)

    local found=false
    local current_name=""
    local current_listen=""
    local current_connect=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^${_IWT_FWD_PREFIX}(.+):$ ]]; then
            if [[ -n "$current_name" ]]; then
                printf "  %-20s %-30s -> %s\n" "$current_name" "$current_listen" "$current_connect"
            fi
            current_name="${BASH_REMATCH[1]}"
            current_listen=""
            current_connect=""
            found=true
        elif [[ "$line" =~ ^[[:space:]]+listen:[[:space:]]+(.+)$ ]]; then
            current_listen="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]+connect:[[:space:]]+(.+)$ ]]; then
            current_connect="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[a-zA-Z] && ! "$line" =~ ^${_IWT_FWD_PREFIX} ]]; then
            if [[ -n "$current_name" ]]; then
                printf "  %-20s %-30s -> %s\n" "$current_name" "$current_listen" "$current_connect"
                current_name=""
            fi
        fi
    done <<< "$devices"

    if [[ -n "$current_name" ]]; then
        printf "  %-20s %-30s -> %s\n" "$current_name" "$current_listen" "$current_connect"
    fi

    if [[ "$found" == false ]]; then
        info "No port forwards on $IWT_VM_NAME"
    fi
}

net_status() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    echo "VM:     $IWT_VM_NAME"

    if vm_is_running; then
        local ip
        ip=$(vm_get_ip 2>/dev/null || echo "unknown")
        echo "Status: running"
        echo "IP:     $ip"
    else
        echo "Status: stopped"
    fi

    # Show NIC devices
    echo ""
    echo "Network interfaces:"
    local devices
    devices=$(incus config device show "$IWT_VM_NAME" 2>/dev/null)

    local in_nic=false
    local nic_name=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^([a-zA-Z0-9_-]+):$ ]]; then
            in_nic=false
            nic_name="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]+type:[[:space:]]+nic$ ]]; then
            in_nic=true
            echo "  $nic_name:"
        elif [[ "$in_nic" == true && "$line" =~ ^[[:space:]]+(.+):[[:space:]]+(.+)$ ]]; then
            printf "    %-15s %s\n" "${BASH_REMATCH[1]}:" "${BASH_REMATCH[2]}"
        fi
    done <<< "$devices"

    # Show port forwards
    echo ""
    echo "Port forwards:"
    net_forward_list
}

net_nic_add() {
    local nic_name="$1"
    local network="${2:-incusbr0}"
    local nic_type="${3:-bridged}"

    [[ -n "$nic_name" ]] || die "NIC name required"

    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    if incus config device show "$IWT_VM_NAME" 2>/dev/null | grep -q "^${nic_name}:"; then
        die "Device '$nic_name' already exists on $IWT_VM_NAME"
    fi

    info "Adding NIC '$nic_name' (type: $nic_type, network: $network)"

    incus config device add "$IWT_VM_NAME" "$nic_name" nic \
        nictype="$nic_type" \
        network="$network"

    if vm_is_running; then
        ok "NIC hotplugged into running VM"
    else
        ok "NIC added (will connect when VM starts)"
    fi
}

net_nic_remove() {
    local nic_name="$1"

    [[ -n "$nic_name" ]] || die "NIC name required"

    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    info "Removing NIC: $nic_name"
    incus config device remove "$IWT_VM_NAME" "$nic_name"
    ok "NIC removed"
}


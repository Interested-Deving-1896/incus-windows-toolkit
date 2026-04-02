#!/usr/bin/env bash
# Set up a running Windows VM with guest tools, WinFsp, WinBtrfs, and VirtIO drivers.
#
# Orchestrates installation of all guest-side components needed for
# full Incus integration (shared folders, agent, balloon, serial, Btrfs volumes).
#
# Usage:
#   setup-guest.sh [options]
#
# Options:
#   --vm NAME               Target VM (default: $IWT_VM_NAME)
#   --install-winfsp        Install WinFsp for filesystem passthrough
#   --install-virtio        Install VirtIO guest tools (balloon, serial, QEMU agent)
#   --install-winbtrfs      Install WinBtrfs driver (enables Btrfs volumes in guest)
#   --mount-bdfs-shares     Push bdfs-mount-shares.ps1 and register logon auto-mount task
#   --security-audit        Run Windows security audit after setup
#   --secure-boot-check     Run UEFI Secure Boot variable audit after setup
#   --all                   Install everything and run all checks
#   --check                 Only check status, don't install anything
#   --help                  Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
source "$IWT_ROOT/remoteapp/backend/incus-backend.sh"
load_config

INSTALL_WINFSP=false
INSTALL_VIRTIO=false
INSTALL_WINBTRFS=false
MOUNT_BDFS_SHARES=false
RUN_SECURITY_AUDIT=false
RUN_SB_CHECK=false
CHECK_ONLY=false

# --- Argument parsing ---

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vm)                 IWT_VM_NAME="$2"; shift 2 ;;
            --install-winfsp)     INSTALL_WINFSP=true; shift ;;
            --install-virtio)     INSTALL_VIRTIO=true; shift ;;
            --install-winbtrfs)   INSTALL_WINBTRFS=true; shift ;;
            --mount-bdfs-shares)  MOUNT_BDFS_SHARES=true; shift ;;
            --security-audit)     RUN_SECURITY_AUDIT=true; shift ;;
            --secure-boot-check)  RUN_SB_CHECK=true; shift ;;
            --all)
                INSTALL_WINFSP=true; INSTALL_VIRTIO=true; INSTALL_WINBTRFS=true
                MOUNT_BDFS_SHARES=true
                RUN_SECURITY_AUDIT=true; RUN_SB_CHECK=true
                shift ;;
            --check)              CHECK_ONLY=true; shift ;;
            --help|-h)
                sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
                exit 0
                ;;
            *)                 die "Unknown option: $1" ;;
        esac
    done

    # Default to --all if no specific component requested
    if [[ "$INSTALL_WINFSP" == false && "$INSTALL_VIRTIO" == false && \
          "$INSTALL_WINBTRFS" == false && "$MOUNT_BDFS_SHARES" == false && \
          "$RUN_SECURITY_AUDIT" == false && \
          "$RUN_SB_CHECK" == false && "$CHECK_ONLY" == false ]]; then
        INSTALL_WINFSP=true
        INSTALL_VIRTIO=true
        INSTALL_WINBTRFS=true
    fi
}

# --- Status check ---

check_guest_status() {
    local status
    status=$(incus exec "$IWT_VM_NAME" -- powershell -Command '
        $result = @{}

        # Incus agent
        $agentSvc = Get-Service -Name "incus-agent" -ErrorAction SilentlyContinue
        $result.IncusAgent = if ($agentSvc) { $agentSvc.Status.ToString() } else { "NotInstalled" }

        # WinFsp
        $result.WinFsp = (Test-Path "C:\Program Files\WinFsp\bin\winfsp-x64.dll")
        $winfspSvc = Get-Service -Name "WinFsp.Launcher" -ErrorAction SilentlyContinue
        $result.WinFspService = if ($winfspSvc) { $winfspSvc.Status.ToString() } else { "NotInstalled" }

        # VirtIO guest tools
        $result.VirtIOBalloon = (Get-Service -Name "BalloonService" -ErrorAction SilentlyContinue) -ne $null
        $result.VirtIOSerial = (Get-Service -Name "VirtioSerial" -ErrorAction SilentlyContinue) -ne $null
        $result.QemuAgent = (Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue) -ne $null

        # VirtIO-FS
        $result.VirtioFS = (Test-Path "C:\Program Files\VirtIO-FS\virtiofs.exe") -or
                           (Test-Path "C:\Program Files\Virtio-Win\VirtIO-FS\virtiofs.exe")
        $virtioFsSvc = Get-Service -Name "VirtioFsSvc" -ErrorAction SilentlyContinue
        $result.VirtioFSService = if ($virtioFsSvc) { $virtioFsSvc.Status.ToString() } else { "NotInstalled" }

        # WinBtrfs
        $result.WinBtrfs = (Test-Path "C:\Windows\System32\drivers\btrfs.sys")
        $btrfsSvc = Get-Service -Name "btrfs" -ErrorAction SilentlyContinue
        $result.WinBtrfsService = if ($btrfsSvc) { $btrfsSvc.Status.ToString() } else { "NotInstalled" }

        # RDP
        $rdpEnabled = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
        $result.RDP = ($rdpEnabled -eq 0)

        # RemoteApp
        $raKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList"
        $raEnabled = (Get-ItemProperty $raKey -Name fDisabledAllowList -ErrorAction SilentlyContinue).fDisabledAllowList
        $result.RemoteApp = ($raEnabled -eq 1)

        $result | ConvertTo-Json
    ' 2>/dev/null) || {
        err "Cannot reach VM agent"
        return 1
    }

    echo "$status"
}

display_status() {
    local status_json="$1"

    bold "Guest Status: $IWT_VM_NAME"
    echo ""

    check_field() {
        local field="$1"
        local label="$2"
        local value
        value=$(echo "$status_json" | jq -r ".$field // \"unknown\"")

        case "$value" in
            true|True|Running)   ok "  $label" ;;
            false|False)         err "  $label: not installed" ;;
            NotInstalled)        err "  $label: not installed" ;;
            Stopped)             warn "  $label: stopped" ;;
            *)                   info "  $label: $value" ;;
        esac
    }

    info "Core:"
    check_field "IncusAgent" "Incus Agent"
    check_field "RDP" "RDP Enabled"
    check_field "RemoteApp" "RemoteApp Allow-All"

    echo ""
    info "VirtIO Guest Tools:"
    check_field "VirtIOBalloon" "Balloon Service"
    check_field "VirtIOSerial" "Serial Driver"
    check_field "QemuAgent" "QEMU Guest Agent"

    echo ""
    info "Filesystem:"
    check_field "WinFsp" "WinFsp"
    check_field "WinFspService" "WinFsp Launcher"
    check_field "VirtioFS" "VirtIO-FS Driver"
    check_field "VirtioFSService" "VirtIO-FS Service"
    check_field "WinBtrfs"        "WinBtrfs Driver"
    check_field "WinBtrfsService" "WinBtrfs Service"
}

# --- VirtIO guest tools installation ---

install_virtio_guest_tools() {
    info "Installing VirtIO guest tools..."

    # Check if we have the installer cached on the host
    local tools_exe
    tools_exe=$(find "$IWT_CACHE_DIR" -name 'virtio-win-guest-tools*' -print -quit 2>/dev/null || true)

    if [[ -n "$tools_exe" && -f "$tools_exe" ]]; then
        info "Pushing cached installer to guest..."
        incus file push "$tools_exe" "$IWT_VM_NAME/Windows/Temp/virtio-win-guest-tools.exe"
    else
        info "No cached installer found. Downloading inside guest..."
        # Get the latest release URL
        local download_url="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win-guest-tools.exe"

        incus exec "$IWT_VM_NAME" -- powershell -Command "
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri '${download_url}' -OutFile 'C:\Windows\Temp\virtio-win-guest-tools.exe' -UseBasicParsing
        " || die "Failed to download VirtIO guest tools in guest"
    fi

    info "Running installer (silent)..."
    incus exec "$IWT_VM_NAME" -- powershell -Command "
        \$installer = 'C:\Windows\Temp\virtio-win-guest-tools.exe'
        \$proc = Start-Process \$installer -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
        Write-Host \"Exit code: \$(\$proc.ExitCode)\"

        if (\$proc.ExitCode -ne 0 -and \$proc.ExitCode -ne 3010) {
            Write-Host 'ERROR: Installation failed'
            exit 1
        }

        Remove-Item \$installer -Force -ErrorAction SilentlyContinue
        Write-Host 'VirtIO guest tools installed'
    " || die "VirtIO guest tools installation failed"

    ok "VirtIO guest tools installed in $IWT_VM_NAME"
}

# --- Main ---

main() {
    parse_args "$@"

    echo ""
    bold "IWT Guest Setup"
    info "VM: $IWT_VM_NAME"
    echo ""

    # Ensure VM is running
    if ! vm_is_running; then
        die "VM '$IWT_VM_NAME' is not running. Start it with: iwt vm start $IWT_VM_NAME"
    fi
    vm_wait_for_agent

    # Show current status
    local status_json
    status_json=$(check_guest_status) || exit 1
    display_status "$status_json"

    if [[ "$CHECK_ONLY" == true ]]; then
        return 0
    fi

    echo ""

    # Install VirtIO guest tools
    if [[ "$INSTALL_VIRTIO" == true ]]; then
        local has_balloon
        has_balloon=$(echo "$status_json" | jq -r '.VirtIOBalloon // false')
        if [[ "$has_balloon" == "true" || "$has_balloon" == "True" ]]; then
            ok "VirtIO guest tools already installed, skipping"
        else
            install_virtio_guest_tools
        fi
    fi

    # Install WinFsp
    if [[ "$INSTALL_WINFSP" == true ]]; then
        local has_winfsp
        has_winfsp=$(echo "$status_json" | jq -r '.WinFsp // false')
        if [[ "$has_winfsp" == "true" || "$has_winfsp" == "True" ]]; then
            ok "WinFsp already installed, skipping"
        else
            "$SCRIPT_DIR/setup-winfsp.sh" --vm "$IWT_VM_NAME"
        fi
    fi

    # Install WinBtrfs
    if [[ "$INSTALL_WINBTRFS" == true ]]; then
        local has_winbtrfs
        has_winbtrfs=$(echo "$status_json" | jq -r '.WinBtrfs // false')
        if [[ "$has_winbtrfs" == "true" || "$has_winbtrfs" == "True" ]]; then
            ok "WinBtrfs already installed, skipping"
        else
            "$SCRIPT_DIR/setup-winbtrfs.sh" --vm "$IWT_VM_NAME"
        fi
    fi

    # Push bdfs-mount-shares.ps1 and register it as a startup task
    if [[ "$MOUNT_BDFS_SHARES" == true ]]; then
        local bdfs_state="${IWT_BDFS_STATE_DIR:-/var/lib/iwt/bdfs}/shares.state"

        # Only proceed if there are active bdfs shares for this VM
        local has_shares=false
        if [[ -f "$bdfs_state" ]]; then
            while IFS='|' read -r _blend _vm share_name _rest; do
                if [[ "$_vm" == "$IWT_VM_NAME" && -n "$share_name" ]]; then
                    has_shares=true; break
                fi
            done < "$bdfs_state"
        fi

        if [[ "$has_shares" == true ]]; then
            info "Installing bdfs-mount-shares.ps1 in guest..."

            # Push the PowerShell helper
            incus file push "$SCRIPT_DIR/bdfs-mount-shares.ps1" \
                "$IWT_VM_NAME/C:/ProgramData/IWT/bdfs-mount-shares.ps1"

            # Write a share-name list so the script can discover shares without
            # needing VirtioFsSvc tag enumeration
            local share_list_tmp
            share_list_tmp=$(mktemp)
            echo "# bdfs shares for $IWT_VM_NAME — generated by iwt vm setup-guest" > "$share_list_tmp"
            while IFS='|' read -r _blend _vm share_name _rest; do
                [[ "$_vm" == "$IWT_VM_NAME" && -n "$share_name" ]] && echo "$share_name"
            done < "$bdfs_state" >> "$share_list_tmp"
            incus file push "$share_list_tmp" \
                "$IWT_VM_NAME/C:/ProgramData/IWT/bdfs-shares.txt"
            rm -f "$share_list_tmp"

            # Register a scheduled task that runs at logon to auto-mount shares
            incus exec "$IWT_VM_NAME" -- powershell -Command '
                $action  = New-ScheduledTaskAction `
                    -Execute "powershell.exe" `
                    -Argument "-NonInteractive -WindowStyle Hidden -File C:\ProgramData\IWT\bdfs-mount-shares.ps1 -All -Quiet"
                $trigger = New-ScheduledTaskTrigger -AtLogOn
                $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
                $principal = New-ScheduledTaskPrincipal -UserId "BUILTIN\Users" -RunLevel Highest
                Register-ScheduledTask `
                    -TaskName "IWT-bdfs-MountShares" `
                    -Action $action -Trigger $trigger `
                    -Settings $settings -Principal $principal `
                    -Description "Auto-mount IWT bdfs virtiofs shares at logon" `
                    -Force | Out-Null
                Write-Host "Scheduled task registered: IWT-bdfs-MountShares"
            '
            ok "bdfs-mount-shares.ps1 installed; shares will auto-mount at next logon"
            info "To mount immediately inside the VM, run:"
            info "  powershell C:\\ProgramData\\IWT\\bdfs-mount-shares.ps1 -All"
        else
            info "No active bdfs shares found for '$IWT_VM_NAME' — skipping bdfs share setup"
            info "Attach shares first with: iwt vm storage bdfs-share --vm $IWT_VM_NAME ..."
        fi
    fi

    # Final status
    echo ""
    info "Refreshing status..."
    status_json=$(check_guest_status) || exit 1
    display_status "$status_json"

    echo ""
    ok "Guest setup complete"

    # Optional post-setup audits
    if [[ "$RUN_SECURITY_AUDIT" == true ]]; then
        echo ""
        "$SCRIPT_DIR/setup-security-audit.sh" --vm "$IWT_VM_NAME"
    fi

    if [[ "$RUN_SB_CHECK" == true ]]; then
        echo ""
        "$SCRIPT_DIR/setup-secure-boot-check.sh" --vm "$IWT_VM_NAME"
    fi
}

main "$@"

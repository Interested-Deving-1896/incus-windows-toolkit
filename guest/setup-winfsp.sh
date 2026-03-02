#!/usr/bin/env bash
# Download and install WinFsp inside a running Windows VM via the Incus agent.
#
# WinFsp (Windows File System Proxy) enables virtiofs/9p shares to be mounted
# as native Windows drive letters. Required for 'iwt vm share mount' to work
# with VirtIO-FS.
#
# Usage:
#   setup-winfsp.sh [options]
#
# Options:
#   --vm NAME       Target VM (default: $IWT_VM_NAME)
#   --version VER   WinFsp version (default: 2.0)
#   --check         Only check if WinFsp is installed, don't install
#   --help          Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
source "$IWT_ROOT/remoteapp/backend/incus-backend.sh"
load_config

WINFSP_VERSION="2.0"
WINFSP_RELEASE_URL="https://github.com/winfsp/winfsp/releases"
CHECK_ONLY=false

# --- Argument parsing ---

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vm)      IWT_VM_NAME="$2"; shift 2 ;;
            --version) WINFSP_VERSION="$2"; shift 2 ;;
            --check)   CHECK_ONLY=true; shift ;;
            --help|-h)
                sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
                exit 0
                ;;
            *)         die "Unknown option: $1" ;;
        esac
    done
}

# --- WinFsp status check ---

winfsp_check() {
    local result
    result=$(incus exec "$IWT_VM_NAME" -- powershell -Command '
        $winfspDir = "C:\Program Files\WinFsp"
        $winfspDll = "C:\Program Files\WinFsp\bin\winfsp-x64.dll"
        $winfspSvc = Get-Service -Name "WinFsp.Launcher" -ErrorAction SilentlyContinue

        $status = @{
            Installed = (Test-Path $winfspDir)
            DllPresent = (Test-Path $winfspDll)
            ServiceRunning = ($winfspSvc -and $winfspSvc.Status -eq "Running")
        }

        if ($status.Installed) {
            # Try to get version
            $verFile = Get-ChildItem "$winfspDir\bin\winfsp-x64.dll" -ErrorAction SilentlyContinue
            if ($verFile) {
                $ver = $verFile.VersionInfo.ProductVersion
                $status.Version = $ver
            }
        }

        $status | ConvertTo-Json
    ' 2>/dev/null) || {
        err "Cannot reach VM agent. Is the VM running?"
        return 1
    }

    echo "$result"
}

winfsp_is_installed() {
    local status_json
    status_json=$(winfsp_check) || return 1

    local installed
    installed=$(echo "$status_json" | jq -r '.Installed // false')
    [[ "$installed" == "true" || "$installed" == "True" ]]
}

# --- WinFsp download URL resolution ---

winfsp_get_download_url() {
    local version="$1"

    # Fetch latest release info from GitHub API
    local release_json
    release_json=$(curl --disable --silent --fail \
        -H "Accept: application/json" \
        "https://api.github.com/repos/winfsp/winfsp/releases/latest") || {
        # Fallback to known URL pattern
        local msi_url="${WINFSP_RELEASE_URL}/download/v${version}/winfsp-${version}.msi"
        info "GitHub API unavailable, using fallback URL"
        echo "$msi_url"
        return
    }

    # Find the .msi asset
    local msi_url
    msi_url=$(echo "$release_json" | jq -r \
        '.assets[] | select(.name | endswith(".msi")) | .browser_download_url' | head -1)

    if [[ -z "$msi_url" ]]; then
        # Fallback
        local tag
        tag=$(echo "$release_json" | jq -r '.tag_name // empty')
        local ver="${tag#v}"
        msi_url="${WINFSP_RELEASE_URL}/download/${tag}/winfsp-${ver}.msi"
    fi

    echo "$msi_url"
}

# --- WinFsp installation ---

winfsp_install() {
    info "Resolving WinFsp download URL..."
    local msi_url
    msi_url=$(winfsp_get_download_url "$WINFSP_VERSION")
    info "URL: $msi_url"

    info "Downloading WinFsp inside guest..."
    incus exec "$IWT_VM_NAME" -- powershell -Command "
        \$ErrorActionPreference = 'Stop'
        \$msiPath = 'C:\Windows\Temp\winfsp.msi'

        Write-Host 'IWT: Downloading WinFsp...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri '${msi_url}' -OutFile \$msiPath -UseBasicParsing

        if (-not (Test-Path \$msiPath)) {
            Write-Host 'IWT: ERROR - Download failed'
            exit 1
        }

        \$size = (Get-Item \$msiPath).Length
        Write-Host \"IWT: Downloaded WinFsp MSI (\$size bytes)\"
    " || die "Failed to download WinFsp in guest"

    info "Installing WinFsp (silent)..."
    incus exec "$IWT_VM_NAME" -- powershell -Command "
        \$ErrorActionPreference = 'Stop'
        \$msiPath = 'C:\Windows\Temp\winfsp.msi'

        Write-Host 'IWT: Installing WinFsp...'
        \$proc = Start-Process msiexec.exe -ArgumentList '/i', \$msiPath, '/qn', '/norestart', 'ADDLOCAL=ALL' -Wait -PassThru
        Write-Host \"IWT: MSI exit code: \$(\$proc.ExitCode)\"

        if (\$proc.ExitCode -ne 0 -and \$proc.ExitCode -ne 3010) {
            Write-Host 'IWT: ERROR - Installation failed'
            exit 1
        }

        # Clean up installer
        Remove-Item \$msiPath -Force -ErrorAction SilentlyContinue

        # Verify installation
        if (Test-Path 'C:\Program Files\WinFsp\bin\winfsp-x64.dll') {
            Write-Host 'IWT: WinFsp installed successfully'
        } else {
            Write-Host 'IWT: WARNING - WinFsp directory not found after install'
        }

        # Start the launcher service
        Start-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
    " || die "Failed to install WinFsp in guest"

    ok "WinFsp installed in $IWT_VM_NAME"
}

# --- VirtIO-FS service setup ---

setup_virtiofs_service() {
    info "Configuring VirtIO-FS service..."
    incus exec "$IWT_VM_NAME" -- powershell -Command "
        \$ErrorActionPreference = 'SilentlyContinue'

        # Check if virtiofs.exe exists (installed by VirtIO guest tools)
        \$virtiofsExe = 'C:\Program Files\VirtIO-FS\virtiofs.exe'
        if (-not (Test-Path \$virtiofsExe)) {
            \$virtiofsExe = 'C:\Program Files\Virtio-Win\VirtIO-FS\virtiofs.exe'
        }

        if (Test-Path \$virtiofsExe) {
            Write-Host 'IWT: VirtIO-FS driver found'

            # Ensure the VirtIO-FS service is set to auto-start
            \$svc = Get-Service -Name 'VirtioFsSvc' -ErrorAction SilentlyContinue
            if (\$svc) {
                Set-Service -Name 'VirtioFsSvc' -StartupType Automatic
                Start-Service -Name 'VirtioFsSvc' -ErrorAction SilentlyContinue
                Write-Host 'IWT: VirtIO-FS service configured for auto-start'
            } else {
                Write-Host 'IWT: VirtIO-FS service not registered (may need VirtIO guest tools)'
            }
        } else {
            Write-Host 'IWT: VirtIO-FS driver not found. Install VirtIO guest tools first:'
            Write-Host '     iwt vm setup-guest --install-virtio'
        }
    " || warn "VirtIO-FS service configuration may have failed"
}

# --- Main ---

main() {
    parse_args "$@"

    echo ""
    bold "WinFsp Guest Setup"
    info "VM: $IWT_VM_NAME"
    echo ""

    # Ensure VM is running and agent is reachable
    if ! vm_is_running; then
        die "VM '$IWT_VM_NAME' is not running. Start it with: iwt vm start $IWT_VM_NAME"
    fi
    vm_wait_for_agent

    # Check current status
    info "Checking WinFsp status..."
    local status_json
    status_json=$(winfsp_check) || exit 1

    local installed
    installed=$(echo "$status_json" | jq -r '.Installed // false')
    local service_running
    service_running=$(echo "$status_json" | jq -r '.ServiceRunning // false')
    local version
    version=$(echo "$status_json" | jq -r '.Version // "unknown"')

    if [[ "$installed" == "true" || "$installed" == "True" ]]; then
        ok "WinFsp is installed (version: $version)"
        if [[ "$service_running" == "true" || "$service_running" == "True" ]]; then
            ok "WinFsp.Launcher service is running"
        else
            warn "WinFsp.Launcher service is not running"
        fi

        if [[ "$CHECK_ONLY" == true ]]; then
            return 0
        fi

        info "WinFsp already installed. Configuring VirtIO-FS service..."
        setup_virtiofs_service
    else
        if [[ "$CHECK_ONLY" == true ]]; then
            err "WinFsp is not installed"
            return 1
        fi

        winfsp_install
        setup_virtiofs_service
    fi

    echo ""
    ok "Guest filesystem setup complete"
    info "Shared folders can now be mounted with: iwt vm share mount <name> <drive>"
}

main "$@"

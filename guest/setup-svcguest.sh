#!/usr/bin/env bash
# Windows guest service management via SvcGuest.
#
# SvcGuest (github.com/nicowillis/SvcGuest) is a lightweight Windows
# service host that runs arbitrary executables as Windows services without
# requiring them to implement the Windows Service Control Manager protocol.
# It is the Windows equivalent of systemd's Type=simple.
#
# IWT uses SvcGuest to install guest-side agents (QEMU guest agent,
# WinBtrfs mount helper, IWT health reporter) as persistent Windows services
# that survive reboots without requiring a full MSI installer.
#
# Usage:
#   setup-svcguest.sh [options]
#
# Options:
#   --check              Check SvcGuest availability in guest image
#   --install            Download SvcGuest binary to IWT cache
#   --inject VM          Inject SvcGuest into a VM's Windows image
#   --register VM SVC EXE  Register EXE as service SVC in VM
#   --list VM            List SvcGuest-managed services in VM
#   --help               Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

CHECK_ONLY=false
DO_INSTALL=false
DO_INJECT=false
DO_REGISTER=false
DO_LIST=false

VM=""
SVC=""
EXE=""

SVCGUEST_VERSION="${IWT_SVCGUEST_VERSION:-latest}"
SVCGUEST_CACHE="${IWT_CACHE_DIR:-$HOME/.cache/iwt}/svcguest"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)     CHECK_ONLY=true; shift ;;
        --install)   DO_INSTALL=true; shift ;;
        --inject)    DO_INJECT=true; VM="$2"; shift 2 ;;
        --register)  DO_REGISTER=true; VM="$2"; SVC="$3"; EXE="$4"; shift 4 ;;
        --list)      DO_LIST=true; VM="$2"; shift 2 ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ "$CHECK_ONLY" == false && "$DO_INSTALL" == false && "$DO_INJECT" == false && \
   "$DO_REGISTER" == false && "$DO_LIST" == false ]] && CHECK_ONLY=true

SVCGUEST_BIN="$SVCGUEST_CACHE/SvcGuest.exe"

check_svcguest() {
    if [[ -f "$SVCGUEST_BIN" ]]; then
        ok "SvcGuest.exe found: $SVCGUEST_BIN"
        return 0
    fi
    warn "SvcGuest.exe not found in cache (run --install)"
    return 1
}

install_svcguest() {
    info "Downloading SvcGuest..."
    mkdir -p "$SVCGUEST_CACHE"

    local api_url="https://api.github.com/repos/nicowillis/SvcGuest/releases/latest"
    local download_url

    if [[ "$SVCGUEST_VERSION" == "latest" ]]; then
        download_url=$(curl -fsSL "$api_url" \
            | grep "browser_download_url" \
            | grep -i "SvcGuest.exe" \
            | head -1 \
            | cut -d'"' -f4)
    else
        download_url="https://github.com/nicowillis/SvcGuest/releases/download/${SVCGUEST_VERSION}/SvcGuest.exe"
    fi

    if [[ -z "$download_url" ]]; then
        # Build from source if no release found
        info "No release found — building SvcGuest from source..."
        _build_svcguest_from_source
        return
    fi

    curl -fsSL -o "$SVCGUEST_BIN" "$download_url"
    ok "SvcGuest.exe downloaded: $SVCGUEST_BIN"
}

_build_svcguest_from_source() {
    require_cmd x86_64-w64-mingw32-gcc "mingw-w64"
    local src_dir="${IWT_BUILD_DIR:-/tmp/iwt-build}/SvcGuest"
    require_cmd git "git"
    git clone --depth=1 https://github.com/nicowillis/SvcGuest.git "$src_dir"
    cd "$src_dir"
    x86_64-w64-mingw32-gcc -o "$SVCGUEST_BIN" SvcGuest.c -ladvapi32
    ok "SvcGuest.exe built: $SVCGUEST_BIN"
}

inject_svcguest() {
    [[ -f "$SVCGUEST_BIN" ]] || die "SvcGuest.exe not found — run --install first"

    info "Injecting SvcGuest into VM: $VM"

    # Use partitionfs to mount the Windows partition
    local partfs_script="$IWT_ROOT/image-pipeline/scripts/setup-partitionfs.sh"
    local vm_disk
    vm_disk=$(iwt_get_disk_path "$VM" 2>/dev/null || echo "")

    if [[ -z "$vm_disk" ]]; then
        warn "Cannot determine disk path for VM: $VM"
        warn "Place SvcGuest.exe manually at C:\\Windows\\System32\\SvcGuest.exe"
        return 1
    fi

    local mnt_dir
    mnt_dir=$(mktemp -d)
    trap 'rm -rf "$mnt_dir"' EXIT

    if [[ -x "$partfs_script" ]]; then
        "$partfs_script" --mount "$vm_disk" "$mnt_dir" --partition 3
    else
        # Fallback: direct mount if root
        sudo mount -o loop,offset="$(get_partition_offset "$vm_disk" 3)" \
            "$vm_disk" "$mnt_dir"
    fi

    local target_dir="$mnt_dir/Windows/System32"
    if [[ -d "$target_dir" ]]; then
        cp "$SVCGUEST_BIN" "$target_dir/SvcGuest.exe"
        ok "SvcGuest.exe injected to $target_dir"
    else
        warn "Windows/System32 not found at $mnt_dir — wrong partition?"
    fi

    if [[ -x "$partfs_script" ]]; then
        "$partfs_script" --umount "$mnt_dir"
    else
        sudo umount "$mnt_dir"
    fi
}

register_service() {
    [[ -n "$VM" && -n "$SVC" && -n "$EXE" ]] || die "Usage: --register VM SVC EXE"
    info "Registering service '$SVC' → '$EXE' in VM: $VM"

    # Generate a .reg file to add the service entry
    local reg_file
    reg_file=$(mktemp --suffix=.reg)
    trap 'rm -f "$reg_file"' EXIT

    cat > "$reg_file" <<REG
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\\${SVC}]
"Type"=dword:00000010
"Start"=dword:00000002
"ErrorControl"=dword:00000001
"ImagePath"="C:\\\\Windows\\\\System32\\\\SvcGuest.exe \"${EXE}\""
"DisplayName"="${SVC}"
"Description"="IWT-managed service: ${SVC}"
REG

    info "Registry file generated: $reg_file"
    info "Import this file into the VM's registry to register the service."
    info "  Method 1: Copy to VM and run: reg import ${SVC}.reg"
    info "  Method 2: Use offline registry editing (chntpw/hivex)"

    # If hivex is available, apply offline
    if command -v hivexregedit &>/dev/null; then
        info "Applying via hivex (offline)..."
        _apply_reg_offline "$VM" "$reg_file"
    fi
}

_apply_reg_offline() {
    local vm="$1"
    local reg_file="$2"
    warn "Offline registry editing not yet implemented — apply $reg_file manually"
}

list_services() {
    info "SvcGuest-managed services in VM: $VM"
    warn "Listing requires live VM access or offline registry parsing"
    info "Connect to VM and run: sc query type= all | findstr SvcGuest"
}

# --- Main ---

if [[ "$DO_INSTALL" == true ]];  then install_svcguest; fi
if [[ "$CHECK_ONLY" == true ]];  then check_svcguest; exit 0; fi
if [[ "$DO_INJECT" == true ]];   then inject_svcguest; fi
if [[ "$DO_REGISTER" == true ]]; then register_service; fi
if [[ "$DO_LIST" == true ]];     then list_services; fi

#!/usr/bin/env bash
# Set up looking-glass IVSHMEM on the host.
#
# Usage:
#   setup-looking-glass.sh [--kvmfr | --shm] [--size SIZE_MB]
#
# Options:
#   --kvmfr       Use KVMFR kernel module (recommended, lower latency)
#   --shm         Use /dev/shm shared memory file (no kernel module needed)
#   --size SIZE   Shared memory size in MB (default: 128)
#   --check       Check looking-glass prerequisites
#
# KVMFR method requires building and loading the kvmfr kernel module.
# SHM method works out of the box but has slightly higher latency.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$IWT_ROOT/cli/lib.sh"

SHM_SIZE=128
METHOD=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kvmfr) METHOD="kvmfr"; shift ;;
            --shm)   METHOD="shm"; shift ;;
            --size)  SHM_SIZE="$2"; shift 2 ;;
            --check) looking_glass_check_full; exit 0 ;;
            --help|-h)
                echo "Usage: setup-looking-glass.sh [--kvmfr | --shm] [--size SIZE_MB]"
                exit 0
                ;;
            *)       die "Unknown option: $1" ;;
        esac
    done

    if [[ -z "$METHOD" ]]; then
        # Auto-detect: prefer kvmfr if module is available
        if modinfo kvmfr &>/dev/null 2>&1; then
            METHOD="kvmfr"
        else
            METHOD="shm"
        fi
        info "Auto-selected method: $METHOD"
    fi
}

looking_glass_check_full() {
    info "Looking-glass prerequisites:"
    echo ""

    # IVSHMEM
    if [[ -c /dev/kvmfr0 ]]; then
        ok "KVMFR device: /dev/kvmfr0"
    elif [[ -f /dev/shm/looking-glass ]]; then
        ok "SHM file: /dev/shm/looking-glass"
    else
        warn "No IVSHMEM device configured"
    fi

    # Client
    if command -v looking-glass-client &>/dev/null; then
        local version
        version=$(looking-glass-client --version 2>&1 | head -1 || echo "unknown")
        ok "Client: $version"
    else
        err "looking-glass-client not installed"
        echo "  Build from: https://looking-glass.io/docs/B7-rc1/build/"
    fi

    # KVMFR module
    if modinfo kvmfr &>/dev/null 2>&1; then
        ok "KVMFR module available"
        if lsmod | grep -q kvmfr; then
            ok "KVMFR module loaded"
        else
            warn "KVMFR module not loaded (modprobe kvmfr)"
        fi
    else
        info "KVMFR module not installed (optional, /dev/shm works too)"
    fi
}

setup_shm() {
    info "Setting up /dev/shm/looking-glass (${SHM_SIZE}MB)"

    # Create the shared memory file
    touch /dev/shm/looking-glass
    chown "$(logname 2>/dev/null || echo "$USER"):kvm" /dev/shm/looking-glass 2>/dev/null || \
        chown "$(logname 2>/dev/null || echo "$USER")" /dev/shm/looking-glass
    chmod 0660 /dev/shm/looking-glass

    # Create tmpfiles.d entry for persistence across reboots
    local tmpfiles_conf="/etc/tmpfiles.d/looking-glass.conf"
    local user
    user=$(logname 2>/dev/null || echo "$USER")

    cat > "$tmpfiles_conf" <<EOF
# looking-glass shared memory
f /dev/shm/looking-glass 0660 $user kvm -
EOF

    ok "SHM file created: /dev/shm/looking-glass"
    ok "Persistent config: $tmpfiles_conf"

    echo ""
    info "Incus VM config needed (add to raw.qemu):"
    echo "  -device ivshmem-plain,memdev=ivshmem,bus=pci.0"
    echo "  -object memory-backend-file,id=ivshmem,share=on,mem-path=/dev/shm/looking-glass,size=${SHM_SIZE}M"
    echo ""
    info "Or apply the looking-glass profile:"
    echo "  iwt profiles install --gpu"
    echo "  incus profile assign <vm> windows-desktop,looking-glass"
}

setup_kvmfr() {
    info "Setting up KVMFR device (${SHM_SIZE}MB)"

    # Check if module is available
    if ! modinfo kvmfr &>/dev/null 2>&1; then
        err "KVMFR module not found. Build it from looking-glass source:"
        echo ""
        echo "  git clone https://gitlab.com/openos-project/upstream-mirrors/LookingGlass"
        echo "  cd LookingGlass/module"
        echo "  make"
        echo "  sudo make install"
        echo "  sudo modprobe kvmfr"
        echo ""
        die "Install KVMFR module first, or use --shm method"
    fi

    # Load module with size parameter
    # Size is in MB, kvmfr expects it as static_size_mb
    if lsmod | grep -q kvmfr; then
        info "KVMFR module already loaded, reloading with size=${SHM_SIZE}MB"
        rmmod kvmfr 2>/dev/null || true
    fi

    modprobe kvmfr "static_size_mb=$SHM_SIZE"

    if [[ ! -c /dev/kvmfr0 ]]; then
        die "KVMFR device not created after modprobe"
    fi

    # Set permissions
    local user
    user=$(logname 2>/dev/null || echo "$USER")
    chown "$user:kvm" /dev/kvmfr0 2>/dev/null || chown "$user" /dev/kvmfr0
    chmod 0660 /dev/kvmfr0

    # Persist module loading
    if [[ ! -f /etc/modules-load.d/kvmfr.conf ]]; then
        echo "kvmfr" > /etc/modules-load.d/kvmfr.conf
    fi

    # Persist module options
    cat > /etc/modprobe.d/kvmfr.conf <<EOF
options kvmfr static_size_mb=$SHM_SIZE
EOF

    # Persist permissions via udev
    cat > /etc/udev/rules.d/99-kvmfr.rules <<EOF
SUBSYSTEM=="kvmfr", OWNER="$user", GROUP="kvm", MODE="0660"
EOF

    ok "KVMFR device: /dev/kvmfr0 (${SHM_SIZE}MB)"
    ok "Module autoload: /etc/modules-load.d/kvmfr.conf"
    ok "Module options: /etc/modprobe.d/kvmfr.conf"
    ok "Udev rules: /etc/udev/rules.d/99-kvmfr.rules"

    echo ""
    info "Incus VM config needed (add to raw.qemu):"
    echo "  -device ivshmem-plain,memdev=ivshmem,bus=pci.0"
    echo "  -object memory-backend-file,id=ivshmem,share=on,mem-path=/dev/kvmfr0,size=${SHM_SIZE}M"
    echo ""
    info "Or apply the looking-glass profile:"
    echo "  iwt profiles install --gpu"
    echo "  incus profile assign <vm> windows-desktop,looking-glass"
}

# --- Main ---

parse_args "$@"

case "$METHOD" in
    shm)   setup_shm ;;
    kvmfr) setup_kvmfr ;;
esac

echo ""
bold "Next steps:"
echo "  1. Install looking-glass host app in the Windows VM"
echo "     Download from: https://looking-glass.io/artifact/stable/host"
echo "  2. Install the IVSHMEM driver in Windows (from virtio-win ISO)"
echo "  3. Start the VM and run looking-glass-host.exe"
echo "  4. On Linux: iwt vm gpu looking-glass launch"

#!/usr/bin/env bash
# Rootless overlay filesystem for VM disk layering via fuse-overlayfs.
#
# containers/fuse-overlayfs provides overlay+shiftfs in FUSE for
# environments where kernel overlayfs is unavailable (unprivileged Incus,
# CI runners without CAP_SYS_ADMIN, rootless containers).
#
# IWT uses fuse-overlayfs as a fallback when:
#   - IWT_STORAGE_BACKEND=btrfs but Btrfs subvolumes cannot be created
#   - Running in an unprivileged context (detected automatically)
#   - IWT_STORAGE_BACKEND=overlay is set explicitly
#
# The overlay stack for a VM named $VM:
#   lower:  read-only base image layer  ($IWT_POOL_DIR/base/$VM)
#   upper:  writable delta layer        ($IWT_POOL_DIR/upper/$VM)
#   work:   overlayfs work dir          ($IWT_POOL_DIR/work/$VM)
#   merged: merged view (VM disk path)  ($IWT_POOL_DIR/merged/$VM)
#
# Usage:
#   setup-fuse-overlayfs.sh [options]
#
# Options:
#   --check              Check fuse-overlayfs availability
#   --install            Install fuse-overlayfs
#   --create VM          Create overlay stack for VM
#   --mount VM           Mount overlay for VM
#   --umount VM          Unmount overlay for VM
#   --commit VM          Flatten upper layer into base (squash delta)
#   --status VM          Show overlay status
#   --help               Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

CHECK_ONLY=false
DO_INSTALL=false
DO_CREATE=false
DO_MOUNT=false
DO_UMOUNT=false
DO_COMMIT=false
DO_STATUS=false
VM=""

POOL_DIR="${IWT_POOL_DIR:-/var/lib/iwt/pool}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)    CHECK_ONLY=true; shift ;;
        --install)  DO_INSTALL=true; shift ;;
        --create)   DO_CREATE=true; VM="$2"; shift 2 ;;
        --mount)    DO_MOUNT=true; VM="$2"; shift 2 ;;
        --umount)   DO_UMOUNT=true; VM="$2"; shift 2 ;;
        --commit)   DO_COMMIT=true; VM="$2"; shift 2 ;;
        --status)   DO_STATUS=true; VM="$2"; shift 2 ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ "$CHECK_ONLY" == false && "$DO_INSTALL" == false && "$DO_CREATE" == false && \
   "$DO_MOUNT" == false && "$DO_UMOUNT" == false && "$DO_COMMIT" == false && \
   "$DO_STATUS" == false ]] && CHECK_ONLY=true

overlay_dirs() {
    local vm="$1"
    LOWER_DIR="$POOL_DIR/base/$vm"
    UPPER_DIR="$POOL_DIR/upper/$vm"
    WORK_DIR="$POOL_DIR/work/$vm"
    MERGED_DIR="$POOL_DIR/merged/$vm"
}

check_fuse_overlayfs() {
    if command -v fuse-overlayfs &>/dev/null; then
        ok "fuse-overlayfs found: $(fuse-overlayfs --version 2>/dev/null | head -1 || echo 'version unknown')"
        return 0
    fi
    err "fuse-overlayfs not found"
    return 1
}

install_fuse_overlayfs() {
    info "Installing fuse-overlayfs..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y fuse-overlayfs
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y fuse-overlayfs
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm fuse-overlayfs
    else
        info "Building fuse-overlayfs from source..."
        require_cmd git "git"
        local src_dir="${IWT_BUILD_DIR:-/tmp/iwt-build}/fuse-overlayfs"
        git clone --depth=1 https://github.com/containers/fuse-overlayfs.git "$src_dir"
        cd "$src_dir"
        ./autogen.sh
        ./configure
        make -j"$(nproc)"
        sudo make install
    fi
    ok "fuse-overlayfs installed"
}

create_overlay() {
    overlay_dirs "$VM"
    info "Creating overlay stack for VM: $VM"
    mkdir -p "$LOWER_DIR" "$UPPER_DIR" "$WORK_DIR" "$MERGED_DIR"
    ok "Overlay directories created:"
    info "  lower:  $LOWER_DIR"
    info "  upper:  $UPPER_DIR"
    info "  work:   $WORK_DIR"
    info "  merged: $MERGED_DIR"
}

mount_overlay() {
    require_cmd fuse-overlayfs "fuse-overlayfs"
    overlay_dirs "$VM"

    [[ -d "$LOWER_DIR" ]]  || die "Lower dir not found: $LOWER_DIR (run --create first)"
    [[ -d "$UPPER_DIR" ]]  || die "Upper dir not found: $UPPER_DIR"
    [[ -d "$WORK_DIR" ]]   || die "Work dir not found: $WORK_DIR"
    [[ -d "$MERGED_DIR" ]] || mkdir -p "$MERGED_DIR"

    if mountpoint -q "$MERGED_DIR" 2>/dev/null; then
        warn "Already mounted: $MERGED_DIR"
        return 0
    fi

    info "Mounting overlay for VM: $VM"
    fuse-overlayfs \
        -o "lowerdir=$LOWER_DIR,upperdir=$UPPER_DIR,workdir=$WORK_DIR" \
        "$MERGED_DIR"
    ok "Overlay mounted at $MERGED_DIR"
}

umount_overlay() {
    overlay_dirs "$VM"

    if ! mountpoint -q "$MERGED_DIR" 2>/dev/null; then
        warn "Not mounted: $MERGED_DIR"
        return 0
    fi

    info "Unmounting overlay for VM: $VM"
    if command -v fusermount3 &>/dev/null; then
        fusermount3 -u "$MERGED_DIR"
    else
        fusermount -u "$MERGED_DIR"
    fi
    ok "Overlay unmounted: $MERGED_DIR"
}

commit_overlay() {
    overlay_dirs "$VM"
    [[ -d "$UPPER_DIR" ]] || die "Upper dir not found: $UPPER_DIR"

    info "Committing upper layer into base for VM: $VM"
    # Ensure not mounted before modifying base
    if mountpoint -q "$MERGED_DIR" 2>/dev/null; then
        die "VM overlay is mounted — unmount before committing"
    fi

    # Merge upper into lower using rsync
    require_cmd rsync "rsync"
    rsync -a --delete "$UPPER_DIR/" "$LOWER_DIR/"

    # Clear upper and work dirs
    rm -rf "${UPPER_DIR:?}"/* "${WORK_DIR:?}"/* 2>/dev/null || true
    ok "Committed: upper layer merged into base, delta cleared"
}

status_overlay() {
    overlay_dirs "$VM"
    bold "Overlay status: $VM"
    echo "  lower:  $LOWER_DIR $(du -sh "$LOWER_DIR" 2>/dev/null | cut -f1 || echo '(missing)')"
    echo "  upper:  $UPPER_DIR $(du -sh "$UPPER_DIR" 2>/dev/null | cut -f1 || echo '(missing)')"
    echo "  merged: $MERGED_DIR $(mountpoint -q "$MERGED_DIR" 2>/dev/null && echo '(mounted)' || echo '(not mounted)')"
}

# --- Main ---

if [[ "$DO_INSTALL" == true ]]; then install_fuse_overlayfs; fi
if [[ "$CHECK_ONLY" == true ]]; then check_fuse_overlayfs || suggest_install fuse-overlayfs; exit 0; fi
if [[ "$DO_CREATE" == true ]];  then create_overlay; fi
if [[ "$DO_MOUNT" == true ]];   then mount_overlay; fi
if [[ "$DO_UMOUNT" == true ]];  then umount_overlay; fi
if [[ "$DO_COMMIT" == true ]];  then commit_overlay; fi
if [[ "$DO_STATUS" == true ]];  then status_overlay; fi

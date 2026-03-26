#!/usr/bin/env bash
# Live disk image resize for IWT VMs via embiggen-disk.
#
# nicowillis/embiggen-disk resizes a filesystem inside a disk image
# without unmounting or stopping the VM. It handles:
#   - Extending the raw image file (truncate/fallocate)
#   - Resizing the partition table entry (sfdisk/sgdisk)
#   - Resizing the filesystem in-place (resize2fs, btrfs, xfs_growfs)
#
# IWT uses embiggen-disk when:
#   - `iwt disk resize <vm> <size>` is called
#   - IWT_AUTO_RESIZE=true and a VM disk crosses IWT_RESIZE_THRESHOLD
#
# Usage:
#   setup-embiggen-disk.sh [options]
#
# Options:
#   --check              Check embiggen-disk availability
#   --install            Install embiggen-disk
#   --resize IMG SIZE    Resize image IMG to SIZE (e.g. 20G, +5G)
#   --info IMG           Show current image and partition sizes
#   --help               Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

CHECK_ONLY=false
DO_INSTALL=false
DO_RESIZE=false
DO_INFO=false

IMG=""
SIZE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)    CHECK_ONLY=true; shift ;;
        --install)  DO_INSTALL=true; shift ;;
        --resize)   DO_RESIZE=true; IMG="$2"; SIZE="$3"; shift 3 ;;
        --info)     DO_INFO=true; IMG="$2"; shift 2 ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ "$CHECK_ONLY" == false && "$DO_INSTALL" == false && \
   "$DO_RESIZE" == false && "$DO_INFO" == false ]] && CHECK_ONLY=true

check_embiggen() {
    if command -v embiggen-disk &>/dev/null; then
        ok "embiggen-disk found"
        return 0
    fi
    err "embiggen-disk not found"
    return 1
}

install_embiggen() {
    info "Installing embiggen-disk..."

    # embiggen-disk is a shell script — install directly
    local bin_dir="${HOME}/.local/bin"
    mkdir -p "$bin_dir"

    if command -v curl &>/dev/null; then
        curl -fsSL \
            "https://raw.githubusercontent.com/nicowillis/embiggen-disk/main/embiggen-disk" \
            -o "$bin_dir/embiggen-disk"
    elif command -v wget &>/dev/null; then
        wget -qO "$bin_dir/embiggen-disk" \
            "https://raw.githubusercontent.com/nicowillis/embiggen-disk/main/embiggen-disk"
    else
        # Clone and symlink
        local src_dir="${IWT_BUILD_DIR:-/tmp/iwt-build}/embiggen-disk"
        require_cmd git "git"
        git clone --depth=1 https://github.com/nicowillis/embiggen-disk.git "$src_dir"
        ln -sf "$src_dir/embiggen-disk" "$bin_dir/embiggen-disk"
    fi

    chmod +x "$bin_dir/embiggen-disk"

    # Ensure bin_dir is in PATH
    if ! echo "$PATH" | grep -q "$bin_dir"; then
        warn "Add $bin_dir to PATH to use embiggen-disk"
    fi

    # embiggen-disk depends on: sfdisk/sgdisk, resize2fs/btrfs/xfs_growfs
    local deps=(util-linux e2fsprogs)
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y "${deps[@]}" btrfs-progs xfsprogs 2>/dev/null || true
    fi

    ok "embiggen-disk installed at $bin_dir/embiggen-disk"
}

resize_image() {
    require_cmd embiggen-disk "embiggen-disk (run --install)"
    [[ -f "$IMG" ]] || die "Image not found: $IMG"
    [[ -n "$SIZE" ]] || die "Size required (e.g. 20G or +5G)"

    local current_size
    current_size=$(du -sh "$IMG" | cut -f1)
    info "Resizing $IMG ($current_size) → $SIZE"

    embiggen-disk "$IMG" "$SIZE"
    local new_size
    new_size=$(du -sh "$IMG" | cut -f1)
    ok "Resized: $IMG ($current_size → $new_size)"
}

info_image() {
    [[ -f "$IMG" ]] || die "Image not found: $IMG"

    bold "Image: $IMG"
    echo "  File size: $(du -sh "$IMG" | cut -f1)"

    if command -v fdisk &>/dev/null; then
        echo ""
        echo "  Partition table:"
        fdisk -l "$IMG" 2>/dev/null | grep -E "^(Disk|Device|/)" | sed 's/^/    /'
    fi

    if command -v file &>/dev/null; then
        echo ""
        echo "  Type: $(file -b "$IMG")"
    fi
}

# --- Main ---

if [[ "$DO_INSTALL" == true ]]; then install_embiggen; fi
if [[ "$CHECK_ONLY" == true ]]; then check_embiggen || suggest_install embiggen-disk; exit 0; fi
if [[ "$DO_RESIZE" == true ]];  then resize_image; fi
if [[ "$DO_INFO" == true ]];    then info_image; fi

#!/usr/bin/env bash
# EROFS image format support for IWT.
#
# EROFS (Enhanced Read-Only File System) is a kernel-native compressed
# read-only filesystem (mainline since Linux 5.4). Unlike DwarFS (FUSE),
# EROFS mounts directly in-kernel with no userspace daemon, supports
# LZ4/LZMA/zstd compression, and integrates natively with dm-verity for
# cryptographic integrity verification.
#
# IWT uses EROFS as an alternative to DwarFS when:
#   - IWT_IMAGE_FORMAT=erofs
#   - Kernel EROFS support is available (CONFIG_EROFS_FS)
#   - dm-verity integration is desired (see storage/setup-verity.sh)
#
# Usage:
#   setup-erofs.sh [options]
#
# Options:
#   --check              Check erofs-utils availability
#   --install            Install erofs-utils
#   --pack SRC DST       Pack directory SRC into EROFS image DST
#   --unpack SRC DST     Extract EROFS image SRC to directory DST
#   --mount IMG MNT      Mount EROFS image (kernel or FUSE fallback)
#   --umount MNT         Unmount
#   --info IMG           Show image metadata
#   --compress ALG       Compression: lz4, lz4hc, lzma, zstd (default: lz4hc)
#   --with-verity        Append dm-verity Merkle tree to image
#   --help               Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

CHECK_ONLY=false
DO_INSTALL=false
DO_PACK=false
DO_UNPACK=false
DO_MOUNT=false
DO_UMOUNT=false
DO_INFO=false

SRC=""
DST=""
MNT=""
IMG=""
COMPRESS="${IWT_EROFS_COMPRESS:-lz4hc}"
WITH_VERITY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)        CHECK_ONLY=true; shift ;;
        --install)      DO_INSTALL=true; shift ;;
        --pack)         DO_PACK=true; SRC="$2"; DST="$3"; shift 3 ;;
        --unpack)       DO_UNPACK=true; SRC="$2"; DST="$3"; shift 3 ;;
        --mount)        DO_MOUNT=true; IMG="$2"; MNT="$3"; shift 3 ;;
        --umount)       DO_UMOUNT=true; MNT="$2"; shift 2 ;;
        --info)         DO_INFO=true; IMG="$2"; shift 2 ;;
        --compress)     COMPRESS="$2"; shift 2 ;;
        --with-verity)  WITH_VERITY=true; shift ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ "$CHECK_ONLY" == false && "$DO_INSTALL" == false && "$DO_PACK" == false && \
   "$DO_UNPACK" == false && "$DO_MOUNT" == false && "$DO_UMOUNT" == false && \
   "$DO_INFO" == false ]] && CHECK_ONLY=true

check_erofs() {
    local ok=true
    for cmd in mkfs.erofs dump.erofs; do
        if command -v "$cmd" &>/dev/null; then
            ok "$cmd found"
        else
            err "$cmd not found"
            ok=false
        fi
    done

    # Check kernel EROFS support
    if [[ -f /proc/filesystems ]] && grep -q erofs /proc/filesystems 2>/dev/null; then
        ok "Kernel EROFS support: available"
    else
        warn "Kernel EROFS support: not detected (erofsfuse fallback will be used)"
    fi

    $ok
}

install_erofs() {
    info "Installing erofs-utils..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y erofs-utils
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y erofs-utils
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm erofs-utils
    else
        # Build from source
        info "Building erofs-utils from source..."
        require_cmd git "git"
        local src_dir="${IWT_BUILD_DIR:-/tmp/iwt-build}/erofs-utils"
        mkdir -p "$(dirname "$src_dir")"
        git clone --depth=1 https://github.com/erofs/erofs-utils.git "$src_dir"
        cd "$src_dir"
        ./autogen.sh
        ./configure --enable-fuse
        make -j"$(nproc)"
        sudo make install
    fi
    ok "erofs-utils installed"
}

pack_erofs() {
    require_cmd mkfs.erofs "erofs-utils"
    [[ -d "$SRC" ]] || die "Source directory not found: $SRC"

    info "Packing $SRC → $DST (compression: $COMPRESS)"
    mkdir -p "$(dirname "$DST")"

    local args=("-z$COMPRESS")
    [[ "$WITH_VERITY" == true ]] && args+=("--chunksize=4096")

    mkfs.erofs "${args[@]}" "$DST" "$SRC"

    if [[ -f "$DST" ]]; then
        local size
        size=$(du -sh "$DST" | cut -f1)
        ok "EROFS image created: $DST ($size)"

        if [[ "$WITH_VERITY" == true ]]; then
            info "Appending dm-verity Merkle tree..."
            # Delegate to setup-verity.sh if available
            local verity_script="$IWT_ROOT/storage/setup-verity.sh"
            if [[ -x "$verity_script" ]]; then
                "$verity_script" --append "$DST"
            else
                warn "setup-verity.sh not found — skipping verity tree"
            fi
        fi
    else
        die "Pack failed — output not found: $DST"
    fi
}

unpack_erofs() {
    require_cmd dump.erofs "erofs-utils"
    [[ -f "$SRC" ]] || die "EROFS image not found: $SRC"
    mkdir -p "$DST"

    info "Unpacking $SRC → $DST"
    # erofs-utils extract via erofsfuse or dump
    if command -v erofsfuse &>/dev/null; then
        local tmp_mnt
        tmp_mnt=$(mktemp -d)
        erofsfuse "$SRC" "$tmp_mnt"
        cp -a "$tmp_mnt/." "$DST/"
        fusermount -u "$tmp_mnt" 2>/dev/null || fusermount3 -u "$tmp_mnt" 2>/dev/null || true
        rmdir "$tmp_mnt"
    else
        die "erofsfuse required for unpack — install erofs-utils with FUSE support"
    fi
    ok "Unpacked to $DST"
}

mount_erofs() {
    [[ -f "$IMG" ]] || die "Image not found: $IMG"
    mkdir -p "$MNT"

    # Prefer kernel mount; fall back to erofsfuse
    if grep -q erofs /proc/filesystems 2>/dev/null; then
        info "Mounting $IMG at $MNT (kernel EROFS)..."
        sudo mount -t erofs -o ro "$IMG" "$MNT"
    elif command -v erofsfuse &>/dev/null; then
        info "Mounting $IMG at $MNT (erofsfuse)..."
        erofsfuse "$IMG" "$MNT"
    else
        die "Neither kernel EROFS nor erofsfuse available"
    fi
    ok "Mounted: $MNT"
}

umount_erofs() {
    info "Unmounting $MNT..."
    if mountpoint -q "$MNT" 2>/dev/null; then
        sudo umount "$MNT" 2>/dev/null || \
        fusermount -u "$MNT" 2>/dev/null || \
        fusermount3 -u "$MNT" 2>/dev/null
    fi
    ok "Unmounted: $MNT"
}

info_erofs() {
    require_cmd dump.erofs "erofs-utils"
    [[ -f "$IMG" ]] || die "Image not found: $IMG"
    dump.erofs --superblock "$IMG"
}

# --- Main ---

if [[ "$DO_INSTALL" == true ]];  then install_erofs; fi
if [[ "$CHECK_ONLY" == true ]];  then check_erofs || suggest_install erofs-utils; exit 0; fi
if [[ "$DO_PACK" == true ]];     then pack_erofs; fi
if [[ "$DO_UNPACK" == true ]];   then unpack_erofs; fi
if [[ "$DO_MOUNT" == true ]];    then mount_erofs; fi
if [[ "$DO_UMOUNT" == true ]];   then umount_erofs; fi
if [[ "$DO_INFO" == true ]];     then info_erofs; fi

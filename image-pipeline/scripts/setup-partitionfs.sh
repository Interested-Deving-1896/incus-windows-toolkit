#!/usr/bin/env bash
# Mount partitions inside a disk image via FUSE — no losetup or root required.
#
# Integrates two complementary FUSE partition tools:
#   - partitionfs (madscientist42): exposes each partition as a separate
#     mountable path; mature, supports MBR and GPT
#   - partsfs (andreax79): similar FUSE approach, Python-based
#
# IWT uses these to inject files (WinBtrfs driver, configs) into a Windows
# disk image's NTFS system partition without needing loop devices or root.
#
# Usage:
#   setup-partitionfs.sh [options]
#
# Options:
#   --check              Check tool availability
#   --install            Build/install partitionfs from source
#   --install-partsfs    Install partsfs (Python) via pip
#   --mount IMAGE DIR    Mount all partitions of IMAGE under DIR
#   --mount-part IMAGE DIR PARTNUM   Mount a single partition
#   --umount DIR         Unmount
#   --inject IMAGE PARTNUM SRC DEST  Copy SRC into partition PARTNUM at DEST
#   --help               Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

CHECK_ONLY=false
DO_INSTALL=false
DO_INSTALL_PARTSFS=false
DO_MOUNT=false
DO_MOUNT_PART=false
DO_UMOUNT=false
DO_INJECT=false

IMAGE=""
MOUNT_DIR=""
PART_NUM=""
INJECT_SRC=""
INJECT_DEST=""

TOOL_BIN="${IWT_TOOL_DIR:-/usr/local/bin}/partitionfs"
SRC_DIR="${IWT_BUILD_DIR:-/tmp/iwt-build}/partitionfs"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)             CHECK_ONLY=true; shift ;;
        --install)           DO_INSTALL=true; shift ;;
        --install-partsfs)   DO_INSTALL_PARTSFS=true; shift ;;
        --mount)             DO_MOUNT=true; IMAGE="$2"; MOUNT_DIR="$3"; shift 3 ;;
        --mount-part)        DO_MOUNT_PART=true; IMAGE="$2"; MOUNT_DIR="$3"; PART_NUM="$4"; shift 4 ;;
        --umount)            DO_UMOUNT=true; MOUNT_DIR="$2"; shift 2 ;;
        --inject)            DO_INJECT=true; IMAGE="$2"; PART_NUM="$3"; INJECT_SRC="$4"; INJECT_DEST="$5"; shift 5 ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ "$CHECK_ONLY" == false && "$DO_INSTALL" == false && \
   "$DO_INSTALL_PARTSFS" == false && "$DO_MOUNT" == false && \
   "$DO_MOUNT_PART" == false && "$DO_UMOUNT" == false && \
   "$DO_INJECT" == false ]] && CHECK_ONLY=true

check_tools() {
    local ok=true
    if [[ -x "$TOOL_BIN" ]] || command -v partitionfs &>/dev/null; then
        ok "partitionfs found"
    else
        err "partitionfs not found"
        ok=false
    fi
    if command -v partsfs &>/dev/null; then
        ok "partsfs found"
    else
        warn "partsfs not found (optional)"
    fi
    require_cmd fusermount "fuse (libfuse)"
    $ok
}

install_partitionfs() {
    info "Building partitionfs from source..."
    require_cmd git "git"
    require_cmd gcc "gcc (build-essential)"
    require_cmd pkg-config "pkg-config"

    # Ensure FUSE dev headers are present
    if ! pkg-config --exists fuse 2>/dev/null; then
        if command -v apt-get &>/dev/null; then
            sudo apt-get install -y libfuse-dev
        else
            die "libfuse-dev required — install manually"
        fi
    fi

    mkdir -p "$(dirname "$SRC_DIR")"
    if [[ ! -d "$SRC_DIR/.git" ]]; then
        git clone --depth=1 \
            https://github.com/madscientist42/partitionfs.git \
            "$SRC_DIR"
    else
        git -C "$SRC_DIR" pull --ff-only
    fi

    cd "$SRC_DIR"
    if [[ -f "CMakeLists.txt" ]]; then
        mkdir -p build && cd build
        cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local
        make -j"$(nproc)"
        sudo make install
    elif [[ -f "Makefile" ]]; then
        make -j"$(nproc)"
        sudo cp partitionfs "$TOOL_BIN"
    else
        die "Unknown build system in $SRC_DIR"
    fi

    ok "partitionfs installed to $TOOL_BIN"
}

install_partsfs() {
    info "Installing partsfs..."
    if command -v pipx &>/dev/null; then
        pipx install git+https://github.com/andreax79/partsfs.git
    elif command -v pip3 &>/dev/null; then
        pip3 install --user git+https://github.com/andreax79/partsfs.git
    else
        die "pip3 or pipx required to install partsfs"
    fi
    ok "partsfs installed"
}

# Mount all partitions of IMAGE under MOUNT_DIR/partN/
mount_image() {
    local tool
    if [[ -x "$TOOL_BIN" ]]; then
        tool="$TOOL_BIN"
    elif command -v partitionfs &>/dev/null; then
        tool="partitionfs"
    else
        die "partitionfs not found"
    fi

    [[ -f "$IMAGE" ]] || die "Image not found: $IMAGE"
    mkdir -p "$MOUNT_DIR"

    info "Mounting partitions of $IMAGE under $MOUNT_DIR..."
    "$tool" "$IMAGE" "$MOUNT_DIR"
    ok "Mounted — partitions available under $MOUNT_DIR"
}

# Mount a single partition
mount_partition() {
    local tool
    if [[ -x "$TOOL_BIN" ]]; then
        tool="$TOOL_BIN"
    elif command -v partitionfs &>/dev/null; then
        tool="partitionfs"
    else
        die "partitionfs not found"
    fi

    [[ -f "$IMAGE" ]] || die "Image not found: $IMAGE"
    mkdir -p "$MOUNT_DIR"

    info "Mounting partition $PART_NUM of $IMAGE at $MOUNT_DIR..."
    "$tool" -o partition="$PART_NUM" "$IMAGE" "$MOUNT_DIR"
    ok "Partition $PART_NUM mounted at $MOUNT_DIR"
}

umount_image() {
    info "Unmounting $MOUNT_DIR..."
    if command -v fusermount3 &>/dev/null; then
        fusermount3 -u "$MOUNT_DIR"
    else
        fusermount -u "$MOUNT_DIR"
    fi
    ok "Unmounted $MOUNT_DIR"
}

# Inject a file into a partition without root
inject_file() {
    [[ -f "$IMAGE" ]]      || die "Image not found: $IMAGE"
    [[ -f "$INJECT_SRC" ]] || die "Source file not found: $INJECT_SRC"

    local tmp_mount
    tmp_mount=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "umount_image_dir '$tmp_mount'" EXIT

    info "Injecting $INJECT_SRC into partition $PART_NUM at $INJECT_DEST..."
    mount_partition_to "$tmp_mount"

    # Create destination directory if needed
    local dest_dir
    dest_dir=$(dirname "$tmp_mount/$INJECT_DEST")
    mkdir -p "$dest_dir"

    cp "$INJECT_SRC" "$tmp_mount/$INJECT_DEST"
    ok "Injected: $INJECT_DEST"

    umount_image_dir "$tmp_mount"
    trap - EXIT
    rmdir "$tmp_mount" 2>/dev/null || true
}

mount_partition_to() {
    local dir="$1"
    local tool
    if [[ -x "$TOOL_BIN" ]]; then
        tool="$TOOL_BIN"
    else
        tool="partitionfs"
    fi
    "$tool" -o partition="$PART_NUM" "$IMAGE" "$dir"
}

umount_image_dir() {
    local dir="$1"
    if command -v fusermount3 &>/dev/null; then
        fusermount3 -u "$dir" 2>/dev/null || true
    else
        fusermount -u "$dir" 2>/dev/null || true
    fi
}

# --- Main ---

if [[ "$DO_INSTALL" == true ]];        then install_partitionfs; fi
if [[ "$DO_INSTALL_PARTSFS" == true ]]; then install_partsfs; fi
if [[ "$CHECK_ONLY" == true ]];        then check_tools; exit 0; fi
if [[ "$DO_MOUNT" == true ]];          then mount_image; fi
if [[ "$DO_MOUNT_PART" == true ]];     then mount_partition; fi
if [[ "$DO_UMOUNT" == true ]];         then umount_image; fi
if [[ "$DO_INJECT" == true ]];         then inject_file; fi

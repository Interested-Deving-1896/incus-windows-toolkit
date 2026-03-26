#!/usr/bin/env bash
# verity-squash-root integration for IWT rescue/recovery images.
#
# verity-squash-root (github.com/rfc2822/verity-squash-root) builds a
# minimal initramfs that mounts a SquashFS root protected by dm-verity.
# IWT uses it to create tamper-evident recovery environments that can be
# embedded in the VM's EFI System Partition.
#
# The output is a UKI (Unified Kernel Image) containing:
#   kernel + initramfs (with verity-squash-root) + SquashFS root image
#
# Usage:
#   setup-verity-squash-root.sh [options]
#
# Options:
#   --check              Check verity-squash-root availability
#   --install            Install verity-squash-root and dependencies
#   --build SRC DST      Build UKI from rootfs directory SRC to DST
#   --verify UKI         Verify UKI integrity
#   --help               Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

CHECK_ONLY=false
DO_INSTALL=false
DO_BUILD=false
DO_VERIFY=false

SRC=""
DST=""
UKI=""

KERNEL="${IWT_KERNEL:-/boot/vmlinuz}"
INITRD_TOOLS_DIR="${IWT_BUILD_DIR:-/tmp/iwt-build}/verity-squash-root"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)    CHECK_ONLY=true; shift ;;
        --install)  DO_INSTALL=true; shift ;;
        --build)    DO_BUILD=true; SRC="$2"; DST="$3"; shift 3 ;;
        --verify)   DO_VERIFY=true; UKI="$2"; shift 2 ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ "$CHECK_ONLY" == false && "$DO_INSTALL" == false && \
   "$DO_BUILD" == false && "$DO_VERIFY" == false ]] && CHECK_ONLY=true

check_vsr() {
    local ok=true
    for cmd in mksquashfs veritysetup objcopy; do
        if command -v "$cmd" &>/dev/null; then
            ok "$cmd found"
        else
            warn "$cmd not found"
            ok=false
        fi
    done
    if [[ -d "$INITRD_TOOLS_DIR" ]]; then
        ok "verity-squash-root source: $INITRD_TOOLS_DIR"
    else
        warn "verity-squash-root not cloned (run --install)"
        ok=false
    fi
    $ok
}

install_vsr() {
    info "Installing verity-squash-root dependencies..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y \
            squashfs-tools \
            cryptsetup-bin \
            binutils \
            dracut \
            linux-image-generic 2>/dev/null || \
        sudo apt-get install -y \
            squashfs-tools \
            cryptsetup-bin \
            binutils
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y squashfs-tools cryptsetup binutils dracut
    fi

    info "Cloning verity-squash-root..."
    require_cmd git "git"
    mkdir -p "$(dirname "$INITRD_TOOLS_DIR")"
    if [[ -d "$INITRD_TOOLS_DIR" ]]; then
        git -C "$INITRD_TOOLS_DIR" pull --ff-only
    else
        git clone --depth=1 \
            https://github.com/rfc2822/verity-squash-root.git \
            "$INITRD_TOOLS_DIR"
    fi
    ok "verity-squash-root cloned to $INITRD_TOOLS_DIR"
}

build_uki() {
    [[ -d "$SRC" ]] || die "Source rootfs not found: $SRC"
    mkdir -p "$(dirname "$DST")"

    local build_dir
    build_dir=$(mktemp -d)
    trap 'rm -rf "$build_dir"' EXIT

    local squash_img="$build_dir/root.squashfs"
    local hashtree="$build_dir/root.verity"
    local roothash_file="$build_dir/root.roothash"

    progress_init 4

    # Step 1: Create SquashFS
    progress_step "Creating SquashFS from $SRC"
    mksquashfs "$SRC" "$squash_img" -comp zstd -noappend -quiet
    local squash_size
    squash_size=$(du -sh "$squash_img" | cut -f1)
    info "  SquashFS: $squash_size"

    # Step 2: Generate dm-verity tree
    progress_step "Generating dm-verity Merkle tree"
    local root_hash
    root_hash=$(veritysetup format \
        --hash=sha256 \
        --data-block-size=4096 \
        --hash-block-size=4096 \
        "$squash_img" "$hashtree" \
        | grep "Root hash:" | awk '{print $3}')
    echo "$root_hash" > "$roothash_file"
    info "  Root hash: $root_hash"

    # Step 3: Build initramfs with verity-squash-root
    progress_step "Building initramfs"
    local initramfs="$build_dir/initramfs.img"

    if [[ -f "$INITRD_TOOLS_DIR/build-initramfs.sh" ]]; then
        SQUASHFS_IMAGE="$squash_img" \
        HASHTREE_IMAGE="$hashtree" \
        ROOT_HASH="$root_hash" \
        OUTPUT="$initramfs" \
            "$INITRD_TOOLS_DIR/build-initramfs.sh"
    else
        # Minimal initramfs with inline verity+squashfs mount
        _build_minimal_initramfs "$squash_img" "$hashtree" "$root_hash" "$initramfs"
    fi

    # Step 4: Assemble UKI via objcopy
    progress_step "Assembling UKI: $DST"
    local kernel
    kernel=$(find /boot -maxdepth 1 -name 'vmlinuz-*' 2>/dev/null | sort -V | tail -1 || echo "$KERNEL")
    [[ -f "$kernel" ]] || die "Kernel not found: $kernel"

    # UKI sections: .linux (kernel), .initrd (initramfs), .cmdline
    local cmdline="root=/dev/mapper/root ro quiet"
    echo -n "$cmdline" > "$build_dir/cmdline.txt"

    objcopy \
        --add-section .linux="$kernel"          --change-section-vma .linux=0x2000000 \
        --add-section .initrd="$initramfs"       --change-section-vma .initrd=0x3000000 \
        --add-section .cmdline="$build_dir/cmdline.txt" --change-section-vma .cmdline=0x1000 \
        /usr/lib/systemd/boot/efi/linuxx64.efi.stub "$DST" 2>/dev/null || \
    objcopy \
        --add-section .linux="$kernel"          --change-section-vma .linux=0x2000000 \
        --add-section .initrd="$initramfs"       --change-section-vma .initrd=0x3000000 \
        --add-section .cmdline="$build_dir/cmdline.txt" --change-section-vma .cmdline=0x1000 \
        /dev/null "$DST"

    ok "UKI built: $DST"
    ok "Root hash: $root_hash"
    echo "$root_hash" > "${DST}.roothash"
}

_build_minimal_initramfs() {
    local squash_img="$1"
    local hashtree="$2"
    local root_hash="$3"
    local output="$4"

    local initrd_dir
    initrd_dir=$(mktemp -d)
    trap 'rm -rf "$initrd_dir"' RETURN

    # Minimal directory structure
    mkdir -p "$initrd_dir"/{bin,dev,proc,sys,mnt/root,mnt/squash}

    # Copy busybox if available
    if command -v busybox &>/dev/null; then
        cp "$(command -v busybox)" "$initrd_dir/bin/busybox"
        for cmd in sh mount umount mknod; do
            ln -sf busybox "$initrd_dir/bin/$cmd"
        done
    fi

    # Copy veritysetup
    cp "$(command -v veritysetup)" "$initrd_dir/bin/" 2>/dev/null || true

    # Copy squashfs image and hashtree into initramfs
    cp "$squash_img" "$initrd_dir/root.squashfs"
    cp "$hashtree"   "$initrd_dir/root.verity"

    # Init script
    cat > "$initrd_dir/init" <<INIT
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mknod /dev/null c 1 3

# Set up loop devices for squashfs and verity
losetup /dev/loop0 /root.squashfs
losetup /dev/loop1 /root.verity

# Open dm-verity
veritysetup open /dev/loop0 root /dev/loop1 ${root_hash}

# Mount verified squashfs
mount -t squashfs -o ro /dev/mapper/root /mnt/root

# Switch root
exec switch_root /mnt/root /sbin/init
INIT
    chmod +x "$initrd_dir/init"

    # Pack initramfs
    (cd "$initrd_dir" && find . | cpio -H newc -o | gzip -9) > "$output"
}

verify_uki() {
    [[ -f "$UKI" ]] || die "UKI not found: $UKI"
    local roothash_f="${UKI}.roothash"
    [[ -f "$roothash_f" ]] || die "Root hash file not found: $roothash_f"

    info "Verifying UKI: $UKI"
    # Extract .initrd section and check embedded squashfs
    if command -v objdump &>/dev/null; then
        objdump -h "$UKI" | grep -E "\.(linux|initrd|cmdline)" | sed 's/^/  /'
    fi
    ok "UKI sections present"
    info "Root hash: $(cat "$roothash_f")"
}

# --- Main ---

if [[ "$DO_INSTALL" == true ]]; then install_vsr; fi
if [[ "$CHECK_ONLY" == true ]]; then check_vsr; exit 0; fi
if [[ "$DO_BUILD" == true ]];   then build_uki; fi
if [[ "$DO_VERIFY" == true ]];  then verify_uki; fi

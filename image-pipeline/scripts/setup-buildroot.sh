#!/usr/bin/env bash
# Buildroot-based rescue environment for IWT VMs.
#
# Buildroot generates a minimal Linux system (kernel + initramfs + rootfs)
# suitable for embedding as a recovery partition in Windows VM disk images.
# The rescue environment provides:
#   - Btrfs tools (btrfs-progs) for filesystem repair
#   - WinBtrfs-compatible partition access
#   - Network stack for remote rescue via SSH
#   - dm-verity verification tools
#   - IWT rescue agent (disk resize, snapshot rollback)
#
# The output is a self-contained ISO or raw image that can be:
#   1. Placed in the VM's EFI System Partition as a UEFI boot entry
#   2. Attached as a secondary disk for emergency boot
#   3. Embedded as a recovery partition (partition 4 by convention)
#
# Usage:
#   setup-buildroot.sh [options]
#
# Options:
#   --check              Check Buildroot prerequisites
#   --install            Install Buildroot and dependencies
#   --configure          Generate IWT Buildroot defconfig
#   --build              Build the rescue image
#   --clean              Clean Buildroot output
#   --inject VM          Inject rescue image into VM's recovery partition
#   --output-dir DIR     Output directory (default: $IWT_BUILD_DIR/rescue)
#   --arch ARCH          Target arch: x86_64 (default), aarch64
#   --help               Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

CHECK_ONLY=false
DO_INSTALL=false
DO_CONFIGURE=false
DO_BUILD=false
DO_CLEAN=false
DO_INJECT=false

VM=""
OUTPUT_DIR="${IWT_BUILD_DIR:-/tmp/iwt-build}/rescue"
ARCH="${IWT_RESCUE_ARCH:-x86_64}"
BUILDROOT_VERSION="${IWT_BUILDROOT_VERSION:-2024.02}"
BUILDROOT_DIR="${IWT_BUILD_DIR:-/tmp/iwt-build}/buildroot-${BUILDROOT_VERSION}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)       CHECK_ONLY=true; shift ;;
        --install)     DO_INSTALL=true; shift ;;
        --configure)   DO_CONFIGURE=true; shift ;;
        --build)       DO_BUILD=true; shift ;;
        --clean)       DO_CLEAN=true; shift ;;
        --inject)      DO_INJECT=true; VM="$2"; shift 2 ;;
        --output-dir)  OUTPUT_DIR="$2"; shift 2 ;;
        --arch)        ARCH="$2"; shift 2 ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ "$CHECK_ONLY" == false && "$DO_INSTALL" == false && "$DO_CONFIGURE" == false && \
   "$DO_BUILD" == false && "$DO_CLEAN" == false && "$DO_INJECT" == false ]] && CHECK_ONLY=true

# Buildroot arch string
br_arch() {
    case "$ARCH" in
        x86_64)  echo "x86_64" ;;
        aarch64) echo "aarch64" ;;
        *)       die "Unsupported arch: $ARCH" ;;
    esac
}

check_buildroot() {
    local ok=true
    local deps=(make gcc g++ unzip rsync bc cpio python3 wget)
    for dep in "${deps[@]}"; do
        if command -v "$dep" &>/dev/null; then
            ok "$dep found"
        else
            warn "$dep not found"
            ok=false
        fi
    done
    if [[ -d "$BUILDROOT_DIR" ]]; then
        ok "Buildroot source: $BUILDROOT_DIR"
    else
        warn "Buildroot not downloaded (run --install)"
        ok=false
    fi
    $ok
}

install_buildroot() {
    info "Installing Buildroot build dependencies..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y \
            make gcc g++ unzip rsync bc cpio python3 wget \
            libncurses-dev libssl-dev file patch perl
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y \
            make gcc gcc-c++ unzip rsync bc cpio python3 wget \
            ncurses-devel openssl-devel file patch perl
    fi

    info "Downloading Buildroot ${BUILDROOT_VERSION}..."
    mkdir -p "$(dirname "$BUILDROOT_DIR")"
    local tarball="${BUILDROOT_DIR}.tar.gz"
    local url="https://buildroot.org/downloads/buildroot-${BUILDROOT_VERSION}.tar.gz"

    if [[ ! -f "$tarball" ]]; then
        wget -q --show-progress -O "$tarball" "$url"
    fi

    if [[ ! -d "$BUILDROOT_DIR" ]]; then
        tar -xzf "$tarball" -C "$(dirname "$BUILDROOT_DIR")"
    fi
    ok "Buildroot ready: $BUILDROOT_DIR"
}

configure_buildroot() {
    [[ -d "$BUILDROOT_DIR" ]] || die "Buildroot not found — run --install first"
    mkdir -p "$OUTPUT_DIR"

    info "Generating IWT rescue defconfig for $ARCH..."
    local defconfig="$OUTPUT_DIR/iwt_rescue_defconfig"

    cat > "$defconfig" <<DEFCONFIG
# IWT Rescue Environment — Buildroot defconfig
# Target: ${ARCH} minimal rescue system

BR2_$(br_arch | tr '[:lower:]' '[:upper:]')=y
BR2_TOOLCHAIN_BUILDROOT_GLIBC=y
BR2_OPTIMIZE_2=y

# Kernel
BR2_LINUX_KERNEL=y
BR2_LINUX_KERNEL_LATEST_VERSION=y
BR2_LINUX_KERNEL_USE_DEFCONFIG=y
BR2_LINUX_KERNEL_DEFCONFIG="$(br_arch)"
BR2_LINUX_KERNEL_COMPRESS_XZ=y

# Filesystem
BR2_TARGET_ROOTFS_SQUASHFS=y
BR2_TARGET_ROOTFS_SQUASHFS_LZMA=y
BR2_TARGET_ROOTFS_INITRAMFS=y

# Core packages
BR2_PACKAGE_BUSYBOX=y
BR2_PACKAGE_OPENSSH=y
BR2_PACKAGE_DROPBEAR=y

# Btrfs tools
BR2_PACKAGE_BTRFS_PROGS=y
BR2_PACKAGE_E2FSPROGS=y
BR2_PACKAGE_DOSFSTOOLS=y
BR2_PACKAGE_PARTED=y
BR2_PACKAGE_UTIL_LINUX=y
BR2_PACKAGE_UTIL_LINUX_BINARIES=y

# dm-verity / cryptsetup
BR2_PACKAGE_CRYPTSETUP=y
BR2_PACKAGE_LVM2=y

# Network
BR2_PACKAGE_IPROUTE2=y
BR2_PACKAGE_IPTABLES=y
BR2_PACKAGE_DHCPCD=y

# Debugging
BR2_PACKAGE_GDB=y
BR2_PACKAGE_STRACE=y
BR2_PACKAGE_HTOP=y

# IWT rescue agent (built separately, injected post-build)
# BR2_PACKAGE_IWT_AGENT=y

# Boot
BR2_TARGET_GRUB2=y
BR2_TARGET_GRUB2_X86_64_EFI=y

BR2_ROOTFS_POST_BUILD_SCRIPT="\$(BR2_EXTERNAL)/board/iwt-rescue/post-build.sh"
DEFCONFIG

    # Copy defconfig into Buildroot configs dir
    cp "$defconfig" "$BUILDROOT_DIR/configs/iwt_rescue_defconfig"

    # Create post-build script
    local board_dir="$BUILDROOT_DIR/board/iwt-rescue"
    mkdir -p "$board_dir"
    cat > "$board_dir/post-build.sh" <<'POST_BUILD'
#!/bin/sh
# IWT rescue post-build: inject rescue agent and configure SSH

TARGET="$1"

# Create IWT rescue directories
mkdir -p "$TARGET/etc/iwt"
mkdir -p "$TARGET/usr/lib/iwt"

# Inject rescue agent if built
AGENT="${BR2_EXTERNAL:-}/agents/iwt-rescue-agent"
if [ -f "$AGENT" ]; then
    cp "$AGENT" "$TARGET/usr/bin/iwt-rescue-agent"
    chmod +x "$TARGET/usr/bin/iwt-rescue-agent"
fi

# Configure SSH for rescue access
mkdir -p "$TARGET/etc/ssh"
cat > "$TARGET/etc/ssh/sshd_config" <<SSHD
PermitRootLogin yes
PasswordAuthentication no
AuthorizedKeysFile /etc/iwt/authorized_keys
SSHD

# Rescue init script
cat > "$TARGET/etc/init.d/S99iwt-rescue" <<INIT
#!/bin/sh
case "\$1" in
    start)
        echo "IWT Rescue Environment"
        echo "  Btrfs tools: btrfs, btrfstune, btrfs-find-root"
        echo "  Disk tools:  fdisk, parted, lsblk"
        echo "  Crypto:      veritysetup, cryptsetup"
        echo ""
        echo "Connect via SSH or use the console."
        ;;
esac
INIT
chmod +x "$TARGET/etc/init.d/S99iwt-rescue"
POST_BUILD
    chmod +x "$board_dir/post-build.sh"

    ok "Defconfig written: $BUILDROOT_DIR/configs/iwt_rescue_defconfig"
    info "Run: setup-buildroot.sh --build"
}

build_rescue() {
    [[ -d "$BUILDROOT_DIR" ]] || die "Buildroot not found — run --install first"
    [[ -f "$BUILDROOT_DIR/configs/iwt_rescue_defconfig" ]] || \
        die "Defconfig not found — run --configure first"

    mkdir -p "$OUTPUT_DIR"

    info "Building IWT rescue image (this takes 30-90 minutes on first run)..."
    cd "$BUILDROOT_DIR"

    make iwt_rescue_defconfig O="$OUTPUT_DIR"
    make -C "$OUTPUT_DIR" -j"$(nproc)" 2>&1 | tee "$OUTPUT_DIR/build.log"

    local images_dir="$OUTPUT_DIR/images"
    if [[ -f "$images_dir/rootfs.squashfs" ]]; then
        ok "Rescue rootfs: $images_dir/rootfs.squashfs"
    fi
    if [[ -f "$images_dir/bzImage" ]] || [[ -f "$images_dir/Image" ]]; then
        ok "Rescue kernel: $images_dir/bzImage (or Image)"
    fi
    if [[ -f "$images_dir/boot.iso" ]]; then
        ok "Rescue ISO: $images_dir/boot.iso"
        local size
        size=$(du -sh "$images_dir/boot.iso" | cut -f1)
        info "  Size: $size"
    fi
}

clean_buildroot() {
    info "Cleaning Buildroot output: $OUTPUT_DIR"
    if [[ -d "$OUTPUT_DIR" ]]; then
        rm -rf "${OUTPUT_DIR:?}"
        ok "Cleaned: $OUTPUT_DIR"
    else
        warn "Output dir not found: $OUTPUT_DIR"
    fi
}

inject_rescue() {
    local images_dir="$OUTPUT_DIR/images"
    local rescue_img="$images_dir/boot.iso"

    [[ -f "$rescue_img" ]] || die "Rescue image not found: $rescue_img (run --build first)"
    info "Injecting rescue image into VM: $VM"

    local vm_disk
    vm_disk=$(iwt_get_disk_path "$VM" 2>/dev/null || echo "")

    if [[ -z "$vm_disk" ]]; then
        warn "Cannot determine disk path for VM: $VM"
        warn "Attach $rescue_img as a secondary disk manually:"
        warn "  incus config device add $VM rescue disk source=$rescue_img"
        return 1
    fi

    # Attach as secondary disk via Incus
    if command -v incus &>/dev/null; then
        incus config device add "$VM" iwt-rescue disk \
            source="$rescue_img" \
            readonly=true \
            boot.priority=0
        ok "Rescue image attached to VM $VM as 'iwt-rescue' disk"
        info "Boot from rescue: incus exec $VM -- efibootmgr -n <rescue-entry>"
    else
        warn "incus not found — attach $rescue_img manually"
    fi
}

# --- Main ---

if [[ "$DO_INSTALL" == true ]];   then install_buildroot; fi
if [[ "$CHECK_ONLY" == true ]];   then check_buildroot; exit 0; fi
if [[ "$DO_CONFIGURE" == true ]]; then configure_buildroot; fi
if [[ "$DO_BUILD" == true ]];     then build_rescue; fi
if [[ "$DO_CLEAN" == true ]];     then clean_buildroot; fi
if [[ "$DO_INJECT" == true ]];    then inject_rescue; fi

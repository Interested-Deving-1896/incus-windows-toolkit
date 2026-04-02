#!/usr/bin/env bash
# Shared library for IWT scripts.
# Source this file; do not execute directly.

# --- Colors (auto-disable if not a terminal) ---

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

info()  { echo -e "${BLUE}::${NC} $*"; }
ok()    { echo -e "${GREEN}OK${NC} $*"; }
warn()  { echo -e "${YELLOW}WARNING${NC} $*" >&2; }
err()   { echo -e "${RED}ERROR${NC} $*" >&2; }
die()   { err "$@"; exit 1; }
bold()  { echo -e "${BOLD}$*${NC}"; }

# --- Progress ---

# Simple step counter for multi-step operations
_IWT_STEP=0
_IWT_TOTAL_STEPS=0

progress_init() {
    _IWT_TOTAL_STEPS="$1"
    _IWT_STEP=0
}

progress_step() {
    _IWT_STEP=$((_IWT_STEP + 1))
    info "[${_IWT_STEP}/${_IWT_TOTAL_STEPS}] $*"
}

# --- Dependency checking ---

require_cmd() {
    local missing=()
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing required commands: ${missing[*]}"
        err ""
        err "Install suggestions:"
        for cmd in "${missing[@]}"; do
            suggest_install "$cmd"
        done
        exit 1
    fi
}

suggest_install() {
    local cmd="$1"
    local pkg=""
    local note=""

    case "$cmd" in
        incus)
            pkg="incus"
            note="See https://linuxcontainers.org/incus/docs/main/installing/"
            ;;
        qemu-img)
            pkg="qemu-utils (Debian/Ubuntu) or qemu-img (Fedora/RHEL)"
            ;;
        xfreerdp3|xfreerdp)
            pkg="freerdp3-x11 (Debian/Ubuntu) or freerdp (Fedora/RHEL)"
            ;;
        wimlib-imagex)
            pkg="wimtools (Debian/Ubuntu) or wimlib-utils (Fedora/RHEL)"
            ;;
        mkisofs)
            pkg="genisoimage (Debian/Ubuntu) or mkisofs (Fedora/RHEL)"
            note="Alternative: xorriso"
            ;;
        xorriso)
            pkg="xorriso"
            ;;
        hivexsh|hivexregedit)
            pkg="libhivex-bin (Debian/Ubuntu) or hivex (Fedora/RHEL)"
            ;;
        curl)
            pkg="curl"
            ;;
        shellcheck)
            pkg="shellcheck"
            ;;
        btrfs)
            pkg="btrfs-progs (Debian/Ubuntu) or btrfs-progs (Fedora/RHEL)"
            note="Required for Btrfs storage pool management"
            ;;
        mkfs.btrfs)
            pkg="btrfs-progs (Debian/Ubuntu) or btrfs-progs (Fedora/RHEL)"
            ;;
        mkdwarfs)
            pkg="dwarfs-tools"
            note="See https://github.com/mhx/dwarfs/releases for pre-built packages"
            ;;
        dwarfs)
            pkg="dwarfs-tools (provides dwarfs FUSE driver)"
            note="See https://github.com/mhx/dwarfs/releases"
            ;;
        dwarfsextract)
            pkg="dwarfs-tools (provides dwarfsextract)"
            note="See https://github.com/mhx/dwarfs/releases"
            ;;
        fusermount|fusermount3)
            pkg="fuse (Debian/Ubuntu) or fuse3 (Fedora/RHEL)"
            ;;
        mkfs.erofs|dump.erofs|erofsfuse)
            pkg="erofs-utils"
            note="See https://github.com/erofs/erofs-utils"
            ;;
        fuse-overlayfs)
            pkg="fuse-overlayfs"
            note="See https://github.com/containers/fuse-overlayfs"
            ;;
        embiggen-disk)
            pkg="embiggen-disk (shell script)"
            note="See https://github.com/nicowillis/embiggen-disk"
            ;;
        veritysetup)
            pkg="cryptsetup-bin (Debian/Ubuntu) or cryptsetup (Fedora/RHEL)"
            ;;
        go-dmverity)
            pkg="go-dmverity (Go)"
            note="Install: go install github.com/anatol/go-dmverity/cmd/go-dmverity@latest"
            ;;
        mksquashfs)
            pkg="squashfs-tools"
            ;;
        mkosi)
            pkg="mkosi"
            note="See https://github.com/systemd/mkosi"
            ;;
        partitionfs|partsfs)
            pkg="partitionfs (FUSE)"
            note="See https://github.com/nicowillis/partitionfs"
            ;;
        serviceman)
            pkg="serviceman"
            note="See https://github.com/nicowillis/serviceman"
            ;;
        x86_64-w64-mingw32-gcc)
            pkg="gcc-mingw-w64-x86-64 (Debian/Ubuntu) or mingw64-gcc (Fedora/RHEL)"
            ;;
        unzip)
            pkg="unzip"
            ;;
        *)
            pkg="$cmd"
            ;;
    esac

    err "  $cmd -> install package: $pkg"
    if [[ -n "$note" ]]; then
        err "         $note"
    fi
}

# --- Btrfs host helpers ---

# Returns 0 if the host kernel has Btrfs support, 1 otherwise.
check_btrfs_host() {
    modinfo btrfs &>/dev/null || lsmod | grep -q '^btrfs'
}

# Returns 0 if btrfs-progs are installed.
check_btrfs_progs() {
    command -v btrfs &>/dev/null && command -v mkfs.btrfs &>/dev/null
}

# Returns the Btrfs filesystem UUID for a given path, or empty string.
btrfs_uuid() {
    local path="$1"
    btrfs filesystem show "$path" 2>/dev/null | grep -oP '(?<=uuid: )[a-f0-9-]+' | head -1 || true
}

# Create a Btrfs subvolume if it doesn't already exist.
# Usage: btrfs_ensure_subvol /path/to/subvol
btrfs_ensure_subvol() {
    local path="$1"
    if [[ -d "$path" ]] && btrfs subvolume show "$path" &>/dev/null; then
        return 0  # already a subvolume
    fi
    sudo btrfs subvolume create "$path"
}

# --- EROFS helpers ---

check_erofs_host() {
    command -v mkfs.erofs &>/dev/null && command -v dump.erofs &>/dev/null
}

check_erofs_kernel() {
    grep -q erofs /proc/filesystems 2>/dev/null
}

# --- fuse-overlayfs helpers ---

check_fuse_overlayfs_host() {
    command -v fuse-overlayfs &>/dev/null
}

# --- dm-verity helpers ---

check_verity_host() {
    command -v veritysetup &>/dev/null
}

# --- VM disk path helper ---

# Returns the path to a VM's primary disk image.
# Works with both Incus-managed and standalone images.
# Usage: iwt_get_disk_path VM_NAME
iwt_get_disk_path() {
    local vm="$1"
    # Try Incus storage pool path
    if command -v incus &>/dev/null; then
        local pool
        pool=$(incus config get "$vm" volatile.pool 2>/dev/null || \
               incus storage list --format csv 2>/dev/null | head -1 | cut -d, -f1 || \
               echo "${IWT_STORAGE_POOL:-iwt-btrfs}")
        local pool_path
        pool_path=$(incus storage get "$pool" source 2>/dev/null || echo "")
        if [[ -n "$pool_path" ]]; then
            local disk="$pool_path/virtual-machines/$vm/disk.qcow2"
            [[ -f "$disk" ]] && echo "$disk" && return 0
        fi
    fi
    # Fallback: check common locations
    for candidate in \
        "${IWT_POOL_DIR:-/var/lib/iwt/pool}/vms/${vm}.qcow2" \
        "${HOME}/.local/share/iwt/vms/${vm}.qcow2"; do
        [[ -f "$candidate" ]] && echo "$candidate" && return 0
    done
    return 1
}

# --- bdfs (btrfs-dwarfs-framework) host helpers ---

# Returns 0 if the bdfs CLI and daemon binaries are installed.
check_bdfs_host() {
    command -v bdfs &>/dev/null && command -v bdfs_daemon &>/dev/null
}

# Returns 0 if the btrfs_dwarfs kernel module is loaded or /dev/bdfs_ctl exists.
check_bdfs_module() {
    modinfo btrfs_dwarfs &>/dev/null 2>&1 || lsmod | grep -q '^btrfs_dwarfs' || [[ -e /dev/bdfs_ctl ]]
}

# Returns 0 if bdfs_daemon is currently running.
check_bdfs_daemon() {
    pgrep -x bdfs_daemon &>/dev/null
}

# --- DwarFS host helpers ---

# Returns 0 if all required DwarFS tools are present.
check_dwarfs_host() {
    command -v mkdwarfs      &>/dev/null && \
    command -v dwarfs        &>/dev/null && \
    command -v dwarfsextract &>/dev/null
}

# Returns 0 if FUSE is available for DwarFS mounts.
check_fuse_host() {
    [[ -e /dev/fuse ]] && \
    { command -v fusermount &>/dev/null || command -v fusermount3 &>/dev/null; }
}

# --- Retry logic ---

# Retry a command up to N times with exponential backoff.
# Usage: retry 3 curl -fSL -o file url
retry() {
    local max_attempts="$1"
    shift
    local attempt=1
    local delay=2

    while true; do
        if "$@"; then
            return 0
        fi

        if [[ $attempt -ge $max_attempts ]]; then
            err "Command failed after $max_attempts attempts: $*"
            return 1
        fi

        warn "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
}

# --- File size formatting ---

human_size() {
    local bytes="$1"
    if [[ $bytes -ge 1073741824 ]]; then
        echo "$(( bytes / 1073741824 ))G"
    elif [[ $bytes -ge 1048576 ]]; then
        echo "$(( bytes / 1048576 ))M"
    elif [[ $bytes -ge 1024 ]]; then
        echo "$(( bytes / 1024 ))K"
    else
        echo "${bytes}B"
    fi
}

# --- Config file support ---

IWT_CONFIG_FILE="${IWT_CONFIG_FILE:-$HOME/.config/iwt/config}"

# Load config file if it exists. Config is simple KEY=VALUE format.
load_config() {
    if [[ -f "$IWT_CONFIG_FILE" ]]; then
        # Only source lines that look like safe variable assignments
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            key=$(echo "$key" | tr -d '[:space:]')
            # Only allow IWT_ prefixed variables
            if [[ "$key" =~ ^IWT_ ]]; then
                export "$key=$value"
            fi
        done < "$IWT_CONFIG_FILE"
    fi
}

# Write a default config file
init_config() {
    local config_dir
    config_dir=$(dirname "$IWT_CONFIG_FILE")
    mkdir -p "$config_dir"

    if [[ -f "$IWT_CONFIG_FILE" ]]; then
        info "Config already exists: $IWT_CONFIG_FILE"
        return 0
    fi

    cat > "$IWT_CONFIG_FILE" <<'EOF'
# IWT Configuration
# Lines starting with # are comments.
# Only IWT_ prefixed variables are loaded.

# Default VM name
IWT_VM_NAME=windows

# RDP connection defaults
IWT_RDP_PORT=3389
IWT_RDP_USER=User
IWT_RDP_PASS=

# Default disk size for new images
IWT_DISK_SIZE=64G

# Driver/asset cache directory (avoids re-downloading)
IWT_CACHE_DIR=$HOME/.cache/iwt

# Storage backend for Incus pools.
# btrfs: create Btrfs-backed pools for copy-on-write snapshots (recommended)
# dir:   plain directory pool (Incus default)
IWT_STORAGE_BACKEND=btrfs

# Name of the default Incus storage pool IWT creates/uses.
IWT_STORAGE_POOL=iwt-btrfs

# Image archive format produced by 'iwt image build'.
# dwarfs: pack output into a compressed .dwarfs archive (recommended, saves ~60-70%)
# qcow2:  leave as a raw QCOW2 disk image
IWT_IMAGE_FORMAT=dwarfs

# DwarFS compression level (1=fastest, 9=smallest). Default 7 balances size/speed.
IWT_DWARFS_COMPRESS_LEVEL=7

# Inject WinBtrfs driver into images built with 'iwt image build'.
# Enables Windows guests to mount Btrfs volumes passed through from the host.
IWT_INJECT_WINBTRFS=true

# --- bdfs (btrfs-dwarfs-framework) settings ---
# Set to true to enable bdfs hybrid BTRFS+DwarFS storage for image archiving.
# Requires btrfs-dwarfs-framework to be built and installed.
# https://github.com/Interested-Deving-1896/btrfs-dwarfs-framework
IWT_BDFS_ENABLED=false

# Default compression algorithm for bdfs export/demote operations.
# Options: zstd (recommended), lz4 (faster), zlib (smaller)
IWT_BDFS_COMPRESSION=zstd

# Default blend namespace mount point used by 'iwt vm storage bdfs-blend mount'.
IWT_BDFS_BLEND_MOUNT=/mnt/iwt-blend

# Persistent state directory for bdfs shares.state (survives reboots).
# Blend state files (ephemeral, recreated on each mount) use /run/iwt/bdfs.
IWT_BDFS_STATE_DIR=/var/lib/iwt/bdfs
EOF

    ok "Config created: $IWT_CONFIG_FILE"
}

# --- Cache directory ---

IWT_CACHE_DIR="${IWT_CACHE_DIR:-$HOME/.cache/iwt}"

ensure_cache_dir() {
    mkdir -p "$IWT_CACHE_DIR"
}

# Download a file to cache if not already present.
# Usage: cached_download URL FILENAME
cached_download() {
    local url="$1"
    local filename="$2"
    local dest="$IWT_CACHE_DIR/$filename"

    ensure_cache_dir

    if [[ -f "$dest" ]]; then
        info "Using cached: $filename"
        echo "$dest"
        return 0
    fi

    info "Downloading: $filename"
    retry 3 curl -fSL --progress-bar -o "$dest.tmp" "$url"
    mv "$dest.tmp" "$dest"
    echo "$dest"
}

# --- Architecture helpers ---

detect_arch() {
    local host_arch
    host_arch=$(uname -m)
    case "$host_arch" in
        x86_64|amd64)  echo "x86_64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)             echo "$host_arch" ;;
    esac
}

arch_to_windows() {
    case "$1" in
        x86_64)  echo "amd64" ;;
        arm64)   echo "arm64" ;;
        *)       echo "$1" ;;
    esac
}

arch_to_qemu() {
    case "$1" in
        x86_64)  echo "x86_64" ;;
        arm64)   echo "aarch64" ;;
        *)       echo "$1" ;;
    esac
}

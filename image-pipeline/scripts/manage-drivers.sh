#!/usr/bin/env bash
# Download and manage VirtIO drivers and guest tools for Windows VMs.
#
# Usage:
#   manage-drivers.sh <subcommand> [options]
#
# Subcommands:
#   download          Download VirtIO drivers ISO and guest tools
#   list              List cached driver files
#   verify            Verify cached driver integrity
#   clean             Remove cached driver files
#   path              Print the cache directory path

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

# VirtIO driver sources
VIRTIO_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso"
VIRTIO_GUEST_TOOLS_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win-guest-tools.exe"

# Stable release (pinned version for reproducibility)
VIRTIO_STABLE_VERSION="0.1.262-2"
VIRTIO_STABLE_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-${VIRTIO_STABLE_VERSION}/virtio-win-${VIRTIO_STABLE_VERSION}.iso"
VIRTIO_STABLE_GUEST_TOOLS_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-${VIRTIO_STABLE_VERSION}/virtio-win-guest-tools-${VIRTIO_STABLE_VERSION}.exe"

# --- Subcommands ---

cmd_download() {
    local use_stable=false
    local download_guest_tools=true
    local arch=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stable)          use_stable=true; shift ;;
            --latest)          use_stable=false; shift ;;
            --no-guest-tools)  download_guest_tools=false; shift ;;
            --arch)            arch="$2"; shift 2 ;;
            --help|-h)         usage; exit 0 ;;
            *)                 die "Unknown option: $1" ;;
        esac
    done

    if [[ -z "$arch" ]]; then
        arch=$(detect_arch)
    fi

    echo ""
    bold "VirtIO Driver Download"
    info "Architecture: $arch"
    info "Channel: $(if $use_stable; then echo "stable (v${VIRTIO_STABLE_VERSION})"; else echo "latest"; fi)"
    echo ""

    # Download VirtIO ISO
    local iso_url="$VIRTIO_ISO_URL"
    local iso_filename="virtio-win.iso"
    if [[ "$use_stable" == true ]]; then
        iso_url="$VIRTIO_STABLE_ISO_URL"
        iso_filename="virtio-win-${VIRTIO_STABLE_VERSION}.iso"
    fi

    info "Downloading VirtIO drivers ISO..."
    local iso_path
    iso_path=$(cached_download "$iso_url" "$iso_filename")
    ok "VirtIO ISO: $iso_path"

    # Download guest tools installer
    if [[ "$download_guest_tools" == true ]]; then
        local tools_url="$VIRTIO_GUEST_TOOLS_URL"
        local tools_filename="virtio-win-guest-tools.exe"
        if [[ "$use_stable" == true ]]; then
            tools_url="$VIRTIO_STABLE_GUEST_TOOLS_URL"
            tools_filename="virtio-win-guest-tools-${VIRTIO_STABLE_VERSION}.exe"
        fi

        info "Downloading VirtIO guest tools installer..."
        local tools_path
        tools_path=$(cached_download "$tools_url" "$tools_filename")
        ok "Guest tools: $tools_path"
    fi

    # List what drivers are available for this arch
    echo ""
    info "Available drivers for $arch:"
    list_drivers_in_iso "$iso_path" "$arch"

    echo ""
    ok "Drivers ready. Use 'iwt image build --inject-drivers' to include them in an image."
}

list_drivers_in_iso() {
    local iso_path="$1"
    local arch="$2"
    local win_arch
    win_arch=$(arch_to_windows "$arch")

    local mount_dir
    mount_dir=$(mktemp -d)
    sudo mount -o loop,ro "$iso_path" "$mount_dir" 2>/dev/null || {
        warn "Cannot mount ISO (may need sudo). Listing by filename instead."
        rm -rf "$mount_dir"
        return 0
    }

    local count=0
    for driver_dir in "$mount_dir"/*/; do
        [[ -d "$driver_dir" ]] || continue
        local driver_name
        driver_name=$(basename "$driver_dir")

        # Check if this driver has binaries for our arch
        local found=false
        for win_ver in w11 2k22 2k19 w10; do
            if [[ -d "$driver_dir/$win_ver/$win_arch" ]]; then
                local inf_count
                inf_count=$(find "$driver_dir/$win_ver/$win_arch" -name '*.inf' 2>/dev/null | wc -l)
                printf "  %-20s %s (%d .inf files)\n" "$driver_name" "$win_ver/$win_arch" "$inf_count"
                found=true
                count=$((count + 1))
                break
            fi
        done
    done

    sudo umount "$mount_dir" 2>/dev/null || true
    rm -rf "$mount_dir"

    info "Total: $count driver packages for $win_arch"
}

cmd_list() {
    ensure_cache_dir
    bold "Cached driver files:"
    echo ""

    local found=false
    for f in "$IWT_CACHE_DIR"/virtio-win*; do
        [[ -e "$f" ]] || continue
        found=true
        local size
        size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo "0")
        printf "  %-45s %s\n" "$(basename "$f")" "$(human_size "$size")"
    done

    if [[ "$found" == false ]]; then
        info "No driver files cached. Run 'iwt image drivers download' to fetch them."
    fi
}

cmd_verify() {
    ensure_cache_dir
    bold "Verifying cached drivers:"
    echo ""

    local errors=0

    # Check VirtIO ISO
    local iso_path="$IWT_CACHE_DIR/virtio-win.iso"
    if [[ -f "$iso_path" ]]; then
        local size
        size=$(stat -c%s "$iso_path" 2>/dev/null || stat -f%z "$iso_path" 2>/dev/null || echo "0")
        if [[ "$size" -gt 1000000 ]]; then
            ok "virtio-win.iso ($(human_size "$size"))"
        else
            err "virtio-win.iso appears truncated ($(human_size "$size"))"
            errors=$((errors + 1))
        fi
    else
        # Check for stable version
        local stable_iso
        stable_iso=$(find "$IWT_CACHE_DIR" -name 'virtio-win-*.iso' -print -quit 2>/dev/null || true)
        if [[ -n "$stable_iso" ]]; then
            local size
            size=$(stat -c%s "$stable_iso" 2>/dev/null || stat -f%z "$stable_iso" 2>/dev/null || echo "0")
            if [[ "$size" -gt 1000000 ]]; then
                ok "$(basename "$stable_iso") ($(human_size "$size"))"
            else
                err "$(basename "$stable_iso") appears truncated"
                errors=$((errors + 1))
            fi
        else
            warn "No VirtIO ISO found in cache"
            errors=$((errors + 1))
        fi
    fi

    # Check guest tools
    local tools_path
    tools_path=$(find "$IWT_CACHE_DIR" -name 'virtio-win-guest-tools*' -print -quit 2>/dev/null || true)
    if [[ -n "$tools_path" ]]; then
        local size
        size=$(stat -c%s "$tools_path" 2>/dev/null || stat -f%z "$tools_path" 2>/dev/null || echo "0")
        if [[ "$size" -gt 100000 ]]; then
            ok "$(basename "$tools_path") ($(human_size "$size"))"
        else
            err "$(basename "$tools_path") appears truncated"
            errors=$((errors + 1))
        fi
    else
        warn "No guest tools installer found in cache"
    fi

    echo ""
    if [[ "$errors" -eq 0 ]]; then
        ok "All cached drivers verified"
    else
        err "$errors verification error(s)"
        return 1
    fi
}

cmd_clean() {
    ensure_cache_dir
    local count=0
    for f in "$IWT_CACHE_DIR"/virtio-win*; do
        [[ -e "$f" ]] || continue
        info "Removing: $(basename "$f")"
        rm -f "$f"
        count=$((count + 1))
    done

    if [[ "$count" -eq 0 ]]; then
        info "No driver files to clean"
    else
        ok "Removed $count cached driver file(s)"
    fi
}

cmd_path() {
    ensure_cache_dir
    echo "$IWT_CACHE_DIR"
}

usage() {
    cat <<EOF
iwt image drivers - Download and manage VirtIO drivers

Subcommands:
  download    Download VirtIO drivers ISO and guest tools
  list        List cached driver files
  verify      Verify cached driver integrity
  clean       Remove cached driver files
  path        Print the cache directory path

Download options:
  --stable            Use pinned stable version (v${VIRTIO_STABLE_VERSION})
  --latest            Use latest version (default)
  --no-guest-tools    Skip guest tools installer download
  --arch ARCH         Target architecture (default: auto-detect)

Examples:
  iwt image drivers download
  iwt image drivers download --stable
  iwt image drivers list
  iwt image drivers verify
  iwt image drivers clean
EOF
}

# --- Main ---

main() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        download)     cmd_download "$@" ;;
        list|ls)      cmd_list ;;
        verify)       cmd_verify ;;
        clean)        cmd_clean ;;
        path)         cmd_path ;;
        help|--help|-h) usage ;;
        *)
            err "Unknown drivers subcommand: $subcmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"

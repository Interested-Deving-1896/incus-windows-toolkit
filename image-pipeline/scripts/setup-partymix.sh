#!/usr/bin/env bash
# Assemble MBR-partitioned disk images using partymix (Rust).
#
# pyx-cvm/partymix assembles filesystem images into a disk image with an
# MBR partition table. IWT uses it for legacy BIOS boot scenarios where
# GPT is not required (older Hyper-V configs, BIOS-only QEMU targets).
#
# Usage:
#   setup-partymix.sh [options]
#
# Options:
#   --check           Check partymix availability
#   --install         Install partymix via cargo
#   --assemble        Assemble a disk image from partition images
#   --boot PART_IMG   Bootable partition image (partition 1)
#   --data PART_IMG   Data partition image (partition 2, optional)
#   --output PATH     Output disk image path (default: ./windows-mbr.img)
#   --help            Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

CHECK_ONLY=false
DO_INSTALL=false
DO_ASSEMBLE=false
BOOT_IMG=""
DATA_IMG=""
OUTPUT_PATH="./windows-mbr.img"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)     CHECK_ONLY=true; shift ;;
        --install)   DO_INSTALL=true; shift ;;
        --assemble)  DO_ASSEMBLE=true; shift ;;
        --boot)      BOOT_IMG="$2"; shift 2 ;;
        --data)      DATA_IMG="$2"; shift 2 ;;
        --output)    OUTPUT_PATH="$2"; shift 2 ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ "$CHECK_ONLY" == false && "$DO_INSTALL" == false && \
   "$DO_ASSEMBLE" == false ]] && CHECK_ONLY=true

check_partymix() {
    if command -v partymix &>/dev/null; then
        ok "partymix found: $(partymix --version 2>/dev/null || echo 'version unknown')"
        return 0
    fi
    err "partymix not found"
    return 1
}

install_partymix() {
    require_cmd cargo "cargo (Rust toolchain — https://rustup.rs)"
    info "Installing partymix via cargo..."
    cargo install partymix
    ok "partymix installed"
}

assemble_image() {
    command -v partymix &>/dev/null || die "partymix not found — run with --install first"
    [[ -n "$BOOT_IMG" ]] || die "--boot is required"
    [[ -f "$BOOT_IMG" ]] || die "Boot partition image not found: $BOOT_IMG"

    info "Assembling MBR disk image: $OUTPUT_PATH"
    info "  Boot partition: $BOOT_IMG"

    local args=("$BOOT_IMG")
    if [[ -n "$DATA_IMG" ]]; then
        [[ -f "$DATA_IMG" ]] || die "Data partition image not found: $DATA_IMG"
        args+=("$DATA_IMG")
        info "  Data partition: $DATA_IMG"
    fi

    partymix "${args[@]}" > "$OUTPUT_PATH"

    if [[ -f "$OUTPUT_PATH" ]]; then
        local size
        size=$(du -sh "$OUTPUT_PATH" | cut -f1)
        ok "MBR disk image assembled: $OUTPUT_PATH ($size)"
    else
        die "Assembly failed — output not found: $OUTPUT_PATH"
    fi
}

if [[ "$DO_INSTALL" == true ]];  then install_partymix; fi
if [[ "$CHECK_ONLY" == true ]];  then check_partymix || suggest_install partymix; exit 0; fi
if [[ "$DO_ASSEMBLE" == true ]]; then assemble_image; fi

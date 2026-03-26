#!/usr/bin/env bash
# Create a bootable GPT disk image with ESP using UEFI-GPT-image-creator.
#
# queso-fuego/UEFI-GPT-image-creator is a self-contained C program that
# produces a GPT disk image with a FAT32 EFI System Partition and an
# optional data partition — without requiring parted, sgdisk, or root.
# IWT uses it as a lightweight alternative to sgdisk+mkfs.fat for ESP
# creation when building Windows images from scratch.
#
# Usage:
#   setup-uefi-gpt-image.sh [options]
#
# Options:
#   --check           Check tool availability only
#   --install         Build and install from source
#   --create          Create a new GPT image
#   --output PATH     Output image path (default: ./windows-gpt.img)
#   --esp-size MB     EFI System Partition size in MiB (default: 512)
#   --data-size MB    Data partition size in MiB (default: 30720 = 30 GiB)
#   --help            Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

CHECK_ONLY=false
DO_INSTALL=false
DO_CREATE=false
OUTPUT_PATH="./windows-gpt.img"
ESP_SIZE_MB=512
DATA_SIZE_MB=30720
TOOL_BIN="${IWT_TOOL_DIR:-/usr/local/bin}/uefi-gpt-image-creator"
SRC_DIR="${IWT_BUILD_DIR:-/tmp/iwt-build}/uefi-gpt-image-creator"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)      CHECK_ONLY=true; shift ;;
        --install)    DO_INSTALL=true; shift ;;
        --create)     DO_CREATE=true; shift ;;
        --output)     OUTPUT_PATH="$2"; shift 2 ;;
        --esp-size)   ESP_SIZE_MB="$2"; shift 2 ;;
        --data-size)  DATA_SIZE_MB="$2"; shift 2 ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ "$CHECK_ONLY" == false && "$DO_INSTALL" == false && \
   "$DO_CREATE" == false ]] && CHECK_ONLY=true

check_tool() {
    if [[ -x "$TOOL_BIN" ]] || command -v uefi-gpt-image-creator &>/dev/null; then
        ok "uefi-gpt-image-creator found"
        return 0
    fi
    err "uefi-gpt-image-creator not found"
    return 1
}

install_tool() {
    info "Building uefi-gpt-image-creator from source..."
    require_cmd git "git"
    require_cmd gcc "gcc (build-essential)"

    mkdir -p "$SRC_DIR"
    if [[ ! -d "$SRC_DIR/.git" ]]; then
        git clone --depth=1 \
            https://github.com/queso-fuego/UEFI-GPT-image-creator.git \
            "$SRC_DIR"
    else
        git -C "$SRC_DIR" pull --ff-only
    fi

    # The tool is a single C file — compile it
    local src
    src=$(find "$SRC_DIR" -name "*.c" | head -1)
    [[ -z "$src" ]] && die "No C source found in $SRC_DIR"

    gcc -O2 -o "$TOOL_BIN" "$src"
    chmod +x "$TOOL_BIN"
    ok "uefi-gpt-image-creator installed to $TOOL_BIN"
}

create_image() {
    local tool
    if [[ -x "$TOOL_BIN" ]]; then
        tool="$TOOL_BIN"
    elif command -v uefi-gpt-image-creator &>/dev/null; then
        tool="uefi-gpt-image-creator"
    else
        die "uefi-gpt-image-creator not found — run with --install first"
    fi

    info "Creating GPT image: $OUTPUT_PATH"
    info "  ESP:  ${ESP_SIZE_MB} MiB"
    info "  Data: ${DATA_SIZE_MB} MiB"

    "$tool" \
        --output "$OUTPUT_PATH" \
        --esp-size "${ESP_SIZE_MB}M" \
        --data-size "${DATA_SIZE_MB}M" \
        2>/dev/null || \
    # Fallback: tool may use positional args depending on version
    "$tool" "$OUTPUT_PATH" "${ESP_SIZE_MB}" "${DATA_SIZE_MB}"

    if [[ -f "$OUTPUT_PATH" ]]; then
        local size
        size=$(du -sh "$OUTPUT_PATH" | cut -f1)
        ok "GPT image created: $OUTPUT_PATH ($size)"
    else
        die "Image creation failed — output not found: $OUTPUT_PATH"
    fi
}

if [[ "$DO_INSTALL" == true ]]; then
    install_tool
fi

if [[ "$CHECK_ONLY" == true ]]; then
    check_tool || suggest_install uefi-gpt-image-creator
    exit 0
fi

if [[ "$DO_CREATE" == true ]]; then
    create_image
fi

#!/usr/bin/env bash
# dm-verity integrity for IWT disk images.
#
# dm-verity provides cryptographic integrity verification for block devices
# using a Merkle hash tree. IWT uses it to detect tampering of base images
# before they are mounted by a VM.
#
# Two backends are supported:
#   1. veritysetup (cryptsetup) — kernel dm-verity, requires root
#   2. go-dmverity              — pure Go userspace implementation, rootless
#
# Workflow:
#   1. setup-verity.sh --sign IMG       → generates IMG.verity + IMG.roothash
#   2. setup-verity.sh --verify IMG     → verifies image against stored roothash
#   3. setup-verity.sh --mount IMG MNT  → maps via dm-verity and mounts (root)
#   4. setup-verity.sh --append IMG     → appends Merkle tree to image (EROFS)
#
# Usage:
#   setup-verity.sh [options]
#
# Options:
#   --check              Check veritysetup / go-dmverity availability
#   --install            Install veritysetup (cryptsetup) and go-dmverity
#   --sign IMG           Generate Merkle tree and root hash for IMG
#   --verify IMG         Verify IMG against stored root hash
#   --mount IMG MNT      Map IMG through dm-verity and mount at MNT (requires root)
#   --umount MNT         Remove dm-verity mapping and unmount
#   --append IMG         Append Merkle tree to IMG in-place (for EROFS)
#   --info IMG           Show stored root hash and tree parameters
#   --hash-algo ALG      Hash algorithm: sha256 (default), sha512
#   --help               Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

CHECK_ONLY=false
DO_INSTALL=false
DO_SIGN=false
DO_VERIFY=false
DO_MOUNT=false
DO_UMOUNT=false
DO_APPEND=false
DO_INFO=false

IMG=""
MNT=""
HASH_ALGO="${IWT_VERITY_HASH:-sha256}"
DM_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)        CHECK_ONLY=true; shift ;;
        --install)      DO_INSTALL=true; shift ;;
        --sign)         DO_SIGN=true; IMG="$2"; shift 2 ;;
        --verify)       DO_VERIFY=true; IMG="$2"; shift 2 ;;
        --mount)        DO_MOUNT=true; IMG="$2"; MNT="$3"; shift 3 ;;
        --umount)       DO_UMOUNT=true; MNT="$2"; shift 2 ;;
        --append)       DO_APPEND=true; IMG="$2"; shift 2 ;;
        --info)         DO_INFO=true; IMG="$2"; shift 2 ;;
        --hash-algo)    HASH_ALGO="$2"; shift 2 ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ "$CHECK_ONLY" == false && "$DO_INSTALL" == false && "$DO_SIGN" == false && \
   "$DO_VERIFY" == false && "$DO_MOUNT" == false && "$DO_UMOUNT" == false && \
   "$DO_APPEND" == false && "$DO_INFO" == false ]] && CHECK_ONLY=true

roothash_file() { echo "${1}.roothash"; }
hashtree_file()  { echo "${1}.verity"; }

check_verity() {
    local ok=true
    if command -v veritysetup &>/dev/null; then
        ok "veritysetup found: $(veritysetup --version 2>/dev/null | head -1)"
    else
        warn "veritysetup not found (install cryptsetup)"
        ok=false
    fi
    if command -v go-dmverity &>/dev/null; then
        ok "go-dmverity found"
    else
        warn "go-dmverity not found (rootless fallback unavailable)"
    fi
    $ok
}

install_verity() {
    info "Installing veritysetup (cryptsetup)..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y cryptsetup-bin
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y cryptsetup
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm cryptsetup
    fi
    ok "veritysetup installed"

    # go-dmverity: pure Go, install via go install
    if command -v go &>/dev/null; then
        info "Installing go-dmverity..."
        go install github.com/anatol/go-dmverity/cmd/go-dmverity@latest
        ok "go-dmverity installed"
    else
        warn "Go not found — skipping go-dmverity (rootless verity unavailable)"
    fi
}

sign_image() {
    [[ -f "$IMG" ]] || die "Image not found: $IMG"
    local roothash_f; roothash_f=$(roothash_file "$IMG")
    local hashtree_f; hashtree_f=$(hashtree_file "$IMG")

    info "Generating dm-verity Merkle tree for: $IMG"
    info "  Hash algorithm: $HASH_ALGO"

    if command -v veritysetup &>/dev/null; then
        # veritysetup format: data-device hash-device
        # We use a separate hash file
        local root_hash
        root_hash=$(veritysetup format \
            --hash="$HASH_ALGO" \
            "$IMG" "$hashtree_f" \
            | grep "Root hash:" | awk '{print $3}')
        echo "$root_hash" > "$roothash_f"
        ok "Root hash: $root_hash"
        ok "Hash tree: $hashtree_f"
        ok "Root hash file: $roothash_f"
    elif command -v go-dmverity &>/dev/null; then
        go-dmverity format --hash="$HASH_ALGO" "$IMG" "$hashtree_f"
        # go-dmverity prints root hash to stdout
        ok "Hash tree: $hashtree_f"
    else
        die "Neither veritysetup nor go-dmverity found — run --install"
    fi
}

verify_image() {
    [[ -f "$IMG" ]] || die "Image not found: $IMG"
    local roothash_f; roothash_f=$(roothash_file "$IMG")
    local hashtree_f; hashtree_f=$(hashtree_file "$IMG")

    [[ -f "$roothash_f" ]] || die "Root hash file not found: $roothash_f (run --sign first)"
    [[ -f "$hashtree_f" ]] || die "Hash tree not found: $hashtree_f (run --sign first)"

    local stored_hash
    stored_hash=$(cat "$roothash_f")
    info "Verifying $IMG against root hash: $stored_hash"

    if command -v veritysetup &>/dev/null; then
        if veritysetup verify "$IMG" "$hashtree_f" "$stored_hash"; then
            ok "Integrity verified: $IMG"
        else
            die "Integrity check FAILED: $IMG may be tampered"
        fi
    else
        die "veritysetup required for verification"
    fi
}

mount_verity() {
    require_cmd veritysetup "cryptsetup"
    [[ -f "$IMG" ]] || die "Image not found: $IMG"
    local roothash_f; roothash_f=$(roothash_file "$IMG")
    local hashtree_f; hashtree_f=$(hashtree_file "$IMG")

    [[ -f "$roothash_f" ]] || die "Root hash file not found: $roothash_f"
    [[ -f "$hashtree_f" ]] || die "Hash tree not found: $hashtree_f"

    local stored_hash
    stored_hash=$(cat "$roothash_f")
    DM_NAME="iwt-verity-$(basename "$IMG" | tr '.' '-')"

    info "Setting up dm-verity mapping: /dev/mapper/$DM_NAME"
    sudo veritysetup open "$IMG" "$DM_NAME" "$hashtree_f" "$stored_hash"

    mkdir -p "$MNT"
    info "Mounting /dev/mapper/$DM_NAME at $MNT"
    sudo mount -o ro "/dev/mapper/$DM_NAME" "$MNT"
    ok "Mounted (verified): $MNT"
    echo "$DM_NAME" > "${MNT}/.iwt-verity-name"
}

umount_verity() {
    local dm_name_file="${MNT}/.iwt-verity-name"
    if [[ -f "$dm_name_file" ]]; then
        DM_NAME=$(cat "$dm_name_file")
    fi

    info "Unmounting $MNT..."
    sudo umount "$MNT" 2>/dev/null || true

    if [[ -n "$DM_NAME" ]] && [[ -e "/dev/mapper/$DM_NAME" ]]; then
        info "Closing dm-verity mapping: $DM_NAME"
        sudo veritysetup close "$DM_NAME"
    fi
    ok "Unmounted and mapping closed"
}

append_verity() {
    # Append Merkle tree to image in-place (used by EROFS images)
    # The appended format is compatible with kernel's built-in verity support
    [[ -f "$IMG" ]] || die "Image not found: $IMG"

    info "Appending dm-verity Merkle tree to: $IMG"
    local hashtree_f; hashtree_f=$(hashtree_file "$IMG")
    local roothash_f; roothash_f=$(roothash_file "$IMG")

    if command -v veritysetup &>/dev/null; then
        local root_hash
        root_hash=$(veritysetup format \
            --hash="$HASH_ALGO" \
            --data-block-size=4096 \
            --hash-block-size=4096 \
            "$IMG" "$hashtree_f" \
            | grep "Root hash:" | awk '{print $3}')

        # Append hash tree to image
        cat "$hashtree_f" >> "$IMG"
        echo "$root_hash" > "$roothash_f"
        ok "Merkle tree appended to $IMG"
        ok "Root hash: $root_hash"
    else
        die "veritysetup required for --append"
    fi
}

info_verity() {
    local roothash_f; roothash_f=$(roothash_file "$IMG")
    local hashtree_f; hashtree_f=$(hashtree_file "$IMG")

    bold "Verity info: $IMG"
    if [[ -f "$roothash_f" ]]; then
        echo "  Root hash: $(cat "$roothash_f")"
    else
        echo "  Root hash: (not signed)"
    fi
    if [[ -f "$hashtree_f" ]]; then
        echo "  Hash tree: $hashtree_f ($(du -sh "$hashtree_f" | cut -f1))"
    else
        echo "  Hash tree: (not found)"
    fi
    if command -v veritysetup &>/dev/null && [[ -f "$hashtree_f" ]]; then
        echo ""
        veritysetup dump "$hashtree_f" 2>/dev/null | sed 's/^/  /' || true
    fi
}

# --- Main ---

if [[ "$DO_INSTALL" == true ]]; then install_verity; fi
if [[ "$CHECK_ONLY" == true ]]; then check_verity; exit 0; fi
if [[ "$DO_SIGN" == true ]];    then sign_image; fi
if [[ "$DO_VERIFY" == true ]];  then verify_image; fi
if [[ "$DO_MOUNT" == true ]];   then mount_verity; fi
if [[ "$DO_UMOUNT" == true ]];  then umount_verity; fi
if [[ "$DO_APPEND" == true ]];  then append_verity; fi
if [[ "$DO_INFO" == true ]];    then info_verity; fi

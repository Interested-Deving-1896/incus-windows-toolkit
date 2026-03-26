#!/usr/bin/env bash
# Windows service helper library injection via SrvLib.
#
# SrvLib (github.com/nicowillis/SrvLib) is a C library that wraps the
# Windows Service Control Manager API, allowing arbitrary executables to
# register themselves as proper Windows services with start/stop/pause
# lifecycle callbacks. Unlike SvcGuest (which wraps an unmodified binary),
# SrvLib is linked into the target binary at compile time.
#
# IWT uses SrvLib when building guest-side agents from source:
#   - iwt-agent.exe: health reporter and disk-resize trigger
#   - iwt-rdp-proxy.exe: in-guest RDP session broker
#
# This script manages the SrvLib development environment on the Linux host
# (cross-compilation via MinGW-w64) and injects pre-built agent binaries
# into VM images.
#
# Usage:
#   setup-srvlib.sh [options]
#
# Options:
#   --check              Check SrvLib / MinGW cross-compile environment
#   --install            Install SrvLib headers and MinGW toolchain
#   --build TARGET       Build TARGET using SrvLib (iwt-agent, iwt-rdp-proxy)
#   --inject VM BIN      Inject compiled binary BIN into VM image
#   --list-targets       List available build targets
#   --help               Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

CHECK_ONLY=false
DO_INSTALL=false
DO_BUILD=false
DO_INJECT=false
DO_LIST=false

TARGET=""
VM=""
BIN=""

SRVLIB_DIR="${IWT_BUILD_DIR:-/tmp/iwt-build}/SrvLib"
AGENT_SRC_DIR="$IWT_ROOT/guest/agent"
AGENT_OUT_DIR="${IWT_BUILD_DIR:-/tmp/iwt-build}/agents"

# Cross-compiler prefix
MINGW_PREFIX="${IWT_MINGW_PREFIX:-x86_64-w64-mingw32}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)         CHECK_ONLY=true; shift ;;
        --install)       DO_INSTALL=true; shift ;;
        --build)         DO_BUILD=true; TARGET="$2"; shift 2 ;;
        --inject)        DO_INJECT=true; VM="$2"; BIN="$3"; shift 3 ;;
        --list-targets)  DO_LIST=true; shift ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ "$CHECK_ONLY" == false && "$DO_INSTALL" == false && "$DO_BUILD" == false && \
   "$DO_INJECT" == false && "$DO_LIST" == false ]] && CHECK_ONLY=true

check_srvlib() {
    local ok=true

    # MinGW cross-compiler
    if command -v "${MINGW_PREFIX}-gcc" &>/dev/null; then
        ok "${MINGW_PREFIX}-gcc found"
    else
        warn "MinGW cross-compiler not found: ${MINGW_PREFIX}-gcc"
        ok=false
    fi

    # SrvLib headers
    if [[ -d "$SRVLIB_DIR" ]]; then
        ok "SrvLib source: $SRVLIB_DIR"
    else
        warn "SrvLib not cloned (run --install)"
        ok=false
    fi

    # Windows SDK headers (via MinGW)
    if "${MINGW_PREFIX}-gcc" -x c -c /dev/null -o /dev/null 2>/dev/null; then
        ok "MinGW Windows headers: available"
    else
        warn "MinGW Windows headers: not available"
        ok=false
    fi

    $ok
}

install_srvlib() {
    info "Installing MinGW-w64 cross-compilation toolchain..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y \
            gcc-mingw-w64-x86-64 \
            g++-mingw-w64-x86-64 \
            mingw-w64-tools \
            mingw-w64-common
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y mingw64-gcc mingw64-gcc-c++
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm mingw-w64-gcc
    fi
    ok "MinGW-w64 installed"

    info "Cloning SrvLib..."
    require_cmd git "git"
    mkdir -p "$(dirname "$SRVLIB_DIR")"
    if [[ -d "$SRVLIB_DIR" ]]; then
        git -C "$SRVLIB_DIR" pull --ff-only
    else
        git clone --depth=1 \
            https://github.com/nicowillis/SrvLib.git \
            "$SRVLIB_DIR"
    fi

    # Build SrvLib static library
    info "Building SrvLib static library..."
    cd "$SRVLIB_DIR"
    "${MINGW_PREFIX}-gcc" -c SrvLib.c -o SrvLib.o
    "${MINGW_PREFIX}-ar" rcs libsrvlib.a SrvLib.o
    ok "SrvLib built: $SRVLIB_DIR/libsrvlib.a"
}

list_targets() {
    bold "Available build targets:"
    cat <<'TARGETS'
  iwt-agent       Health reporter: disk usage, VM state, resize triggers
  iwt-rdp-proxy   In-guest RDP session broker for multi-user access
TARGETS
}

build_target() {
    [[ -n "$TARGET" ]] || die "Target required"
    mkdir -p "$AGENT_OUT_DIR"

    case "$TARGET" in
        iwt-agent)
            _build_iwt_agent
            ;;
        iwt-rdp-proxy)
            _build_iwt_rdp_proxy
            ;;
        *)
            die "Unknown target: $TARGET (run --list-targets)"
            ;;
    esac
}

_build_iwt_agent() {
    info "Building iwt-agent.exe..."
    local src="$AGENT_SRC_DIR/iwt-agent.c"
    local out="$AGENT_OUT_DIR/iwt-agent.exe"

    # Generate minimal agent source if not present
    if [[ ! -f "$src" ]]; then
        mkdir -p "$AGENT_SRC_DIR"
        _generate_iwt_agent_source "$src"
    fi

    [[ -f "$SRVLIB_DIR/libsrvlib.a" ]] || die "SrvLib not built — run --install first"

    "${MINGW_PREFIX}-gcc" \
        -I"$SRVLIB_DIR" \
        -o "$out" \
        "$src" \
        -L"$SRVLIB_DIR" -lsrvlib \
        -ladvapi32 -lws2_32 \
        -static -mwindows

    ok "Built: $out"
}

_generate_iwt_agent_source() {
    local out="$1"
    info "Generating iwt-agent.c source..."
    cat > "$out" <<'AGENT_C'
/*
 * iwt-agent.c — IWT guest health reporter
 *
 * Reports disk usage and VM state to the host via a named pipe.
 * Installed as a Windows service using SrvLib.
 */
#include <windows.h>
#include <stdio.h>
#include "SrvLib.h"

#define PIPE_NAME "\\\\.\\pipe\\iwt-agent"
#define REPORT_INTERVAL_MS 30000

static BOOL running = TRUE;

static void report_status(HANDLE pipe) {
    ULARGE_INTEGER free_bytes, total_bytes;
    char buf[256];
    if (GetDiskFreeSpaceExA("C:\\", &free_bytes, &total_bytes, NULL)) {
        snprintf(buf, sizeof(buf),
            "{\"free_bytes\":%llu,\"total_bytes\":%llu}\n",
            free_bytes.QuadPart, total_bytes.QuadPart);
        DWORD written;
        WriteFile(pipe, buf, (DWORD)strlen(buf), &written, NULL);
    }
}

static DWORD WINAPI agent_thread(LPVOID param) {
    (void)param;
    while (running) {
        HANDLE pipe = CreateNamedPipeA(
            PIPE_NAME,
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
            1, 4096, 4096, 0, NULL);

        if (pipe == INVALID_HANDLE_VALUE) {
            Sleep(REPORT_INTERVAL_MS);
            continue;
        }

        if (ConnectNamedPipe(pipe, NULL) || GetLastError() == ERROR_PIPE_CONNECTED) {
            report_status(pipe);
            FlushFileBuffers(pipe);
            DisconnectNamedPipe(pipe);
        }
        CloseHandle(pipe);
    }
    return 0;
}

void srvlib_main(void) {
    HANDLE thread = CreateThread(NULL, 0, agent_thread, NULL, 0, NULL);
    if (thread) {
        WaitForSingleObject(thread, INFINITE);
        CloseHandle(thread);
    }
}

void srvlib_stop(void) {
    running = FALSE;
}

int main(int argc, char *argv[]) {
    return SrvLib_Run("iwt-agent", srvlib_main, srvlib_stop);
}
AGENT_C
    ok "Generated: $out"
}

_build_iwt_rdp_proxy() {
    info "Building iwt-rdp-proxy.exe..."
    local src="$AGENT_SRC_DIR/iwt-rdp-proxy.c"
    local out="$AGENT_OUT_DIR/iwt-rdp-proxy.exe"

    if [[ ! -f "$src" ]]; then
        mkdir -p "$AGENT_SRC_DIR"
        warn "iwt-rdp-proxy.c not found — stub only"
        cat > "$src" <<'STUB'
/* iwt-rdp-proxy.c — stub; full implementation pending */
#include <windows.h>
#include "SrvLib.h"
void srvlib_main(void) { Sleep(INFINITE); }
void srvlib_stop(void) {}
int main(void) { return SrvLib_Run("iwt-rdp-proxy", srvlib_main, srvlib_stop); }
STUB
    fi

    "${MINGW_PREFIX}-gcc" \
        -I"$SRVLIB_DIR" \
        -o "$out" \
        "$src" \
        -L"$SRVLIB_DIR" -lsrvlib \
        -ladvapi32 -lws2_32 \
        -static -mwindows

    ok "Built: $out"
}

inject_binary() {
    [[ -f "$BIN" ]] || die "Binary not found: $BIN"
    info "Injecting $(basename "$BIN") into VM: $VM"

    local partfs_script="$IWT_ROOT/image-pipeline/scripts/setup-partitionfs.sh"
    local vm_disk
    vm_disk=$(iwt_get_disk_path "$VM" 2>/dev/null || echo "")

    if [[ -z "$vm_disk" ]]; then
        warn "Cannot determine disk path for VM: $VM"
        warn "Copy $(basename "$BIN") to C:\\Windows\\System32\\ manually"
        return 1
    fi

    local mnt_dir
    mnt_dir=$(mktemp -d)
    trap 'rm -rf "$mnt_dir"' EXIT

    if [[ -x "$partfs_script" ]]; then
        "$partfs_script" --mount "$vm_disk" "$mnt_dir" --partition 3
    else
        sudo mount -o loop "$vm_disk" "$mnt_dir"
    fi

    local bin_name
    bin_name=$(basename "$BIN")
    local dest="$mnt_dir/Windows/System32/$bin_name"
    cp "$BIN" "$dest"
    ok "Injected: $dest"

    if [[ -x "$partfs_script" ]]; then
        "$partfs_script" --umount "$mnt_dir"
    else
        sudo umount "$mnt_dir"
    fi
}

# --- Main ---

if [[ "$DO_INSTALL" == true ]]; then install_srvlib; fi
if [[ "$CHECK_ONLY" == true ]]; then check_srvlib; exit 0; fi
if [[ "$DO_LIST" == true ]];    then list_targets; fi
if [[ "$DO_BUILD" == true ]];   then build_target; fi
if [[ "$DO_INJECT" == true ]];  then inject_binary; fi

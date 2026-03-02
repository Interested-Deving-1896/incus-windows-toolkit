#!/usr/bin/env bash
# iwt - Incus Windows Toolkit
# Unified CLI for Windows VM management on Incus.
#
# Usage: iwt <command> [subcommand] [options]

set -euo pipefail

VERSION="0.1.0"

# Resolve install location
if [[ -L "${BASH_SOURCE[0]}" ]]; then
    IWT_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && cd .. && pwd)"
else
    IWT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
fi

# If installed to /usr/local/bin, data is in /usr/local/share/iwt
if [[ ! -d "$IWT_ROOT/image-pipeline" ]]; then
    IWT_ROOT="${IWT_ROOT%/bin}/share/iwt"
fi

export IWT_ROOT

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}::${NC} $*"; }
ok()    { echo -e "${GREEN}OK${NC} $*"; }
warn()  { echo -e "${YELLOW}WARNING${NC} $*" >&2; }
err()   { echo -e "${RED}ERROR${NC} $*" >&2; }

# --- Help ---

show_help() {
    cat <<EOF
iwt - Incus Windows Toolkit v${VERSION}

Usage: iwt <command> [subcommand] [options]

Commands:
  image       Build and manage Windows VM images
  vm          Create, start, stop, and manage Windows VMs
  profiles    Install and manage Incus VM profiles
  remoteapp   Launch Windows apps as seamless Linux windows
  doctor      Check system prerequisites
  version     Show version

Run 'iwt <command> --help' for details on each command.
EOF
}

# --- Doctor (prerequisite check) ---

cmd_doctor() {
    info "Checking prerequisites..."
    local ok_count=0
    local fail_count=0

    check() {
        local name="$1" cmd="$2"
        if command -v "$cmd" &>/dev/null; then
            ok "$name ($cmd)"
            ok_count=$((ok_count + 1))
        else
            err "$name not found ($cmd)"
            fail_count=$((fail_count + 1))
        fi
    }

    check "Incus"           incus
    check "QEMU (img)"      qemu-img
    check "curl"            curl
    check "xfreerdp3"       xfreerdp3
    check "wimlib"          wimlib-imagex
    check "mkisofs"         mkisofs
    check "shellcheck"      shellcheck

    # Check KVM
    if [[ -e /dev/kvm ]]; then
        ok "KVM (/dev/kvm)"
        ok_count=$((ok_count + 1))
    else
        err "KVM not available (/dev/kvm missing)"
        fail_count=$((fail_count + 1))
    fi

    # Check architecture
    local arch
    arch=$(uname -m)
    info "Host architecture: $arch"

    # Check Incus connectivity
    if command -v incus &>/dev/null; then
        if incus info &>/dev/null; then
            ok "Incus daemon reachable"
            ok_count=$((ok_count + 1))
        else
            err "Incus daemon not reachable (is incusd running?)"
            fail_count=$((fail_count + 1))
        fi
    fi

    echo ""
    info "Results: $ok_count passed, $fail_count failed"
    [[ $fail_count -eq 0 ]] && return 0 || return 1
}

# --- Image commands ---

cmd_image() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        build)
            exec "$IWT_ROOT/image-pipeline/scripts/build-image.sh" "$@"
            ;;
        help|--help|-h)
            cat <<EOF
iwt image - Build Windows images for Incus

Subcommands:
  build     Build a Windows image from an ISO

Options (passed to build):
  --iso PATH          Path to Windows ISO (required)
  --arch ARCH         x86_64 | arm64 (default: x86_64)
  --edition EDITION   Windows edition (default: Pro)
  --slim              Strip bloatware (tiny11-style)
  --output PATH       Output image path
  --inject-drivers    Inject VirtIO + platform drivers
  --woa-drivers PATH  WOA driver directory (ARM only)
  --size SIZE         Disk size (default: 64G)

Example:
  iwt image build --iso Win11_24H2.iso --slim --arch x86_64
EOF
            ;;
        *)
            err "Unknown image subcommand: $subcmd"
            exit 1
            ;;
    esac
}

# --- VM commands ---

cmd_vm() {
    local subcmd="${1:-help}"
    shift || true

    # Source the backend for VM operations
    source "$IWT_ROOT/remoteapp/backend/incus-backend.sh"

    case "$subcmd" in
        create)
            cmd_vm_create "$@"
            ;;
        start)
            IWT_VM_NAME="${1:-$IWT_VM_NAME}"
            vm_start
            ;;
        stop)
            IWT_VM_NAME="${1:-$IWT_VM_NAME}"
            vm_stop
            ;;
        status)
            IWT_VM_NAME="${1:-$IWT_VM_NAME}"
            if vm_is_running; then
                local ip
                ip=$(vm_get_ip 2>/dev/null || echo "unknown")
                ok "$IWT_VM_NAME is running (IP: $ip)"
            else
                info "$IWT_VM_NAME is stopped"
            fi
            ;;
        rdp)
            IWT_VM_NAME="${1:-$IWT_VM_NAME}"
            shift || true
            vm_start
            vm_wait_for_rdp
            rdp_connect_full "$@"
            ;;
        help|--help|-h)
            cat <<EOF
iwt vm - Manage Windows VMs

Subcommands:
  create [options]    Create a new Windows VM
  start [name]        Start a VM
  stop [name]         Stop a VM
  status [name]       Show VM status
  rdp [name]          Open full RDP desktop session

Create options:
  --name NAME         VM name (default: windows)
  --profile PROFILE   Incus profile to use (default: windows-desktop)
  --image PATH        Path to modified ISO from 'iwt image build'
  --disk PATH         Path to QCOW2 disk image

Example:
  iwt vm create --name win11 --image windows-modified.iso
  iwt vm rdp win11
EOF
            ;;
        *)
            err "Unknown vm subcommand: $subcmd"
            exit 1
            ;;
    esac
}

cmd_vm_create() {
    local name="windows"
    local profile="windows-desktop"
    local image=""
    local disk=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)    name="$2"; shift 2 ;;
            --profile) profile="$2"; shift 2 ;;
            --image)   image="$2"; shift 2 ;;
            --disk)    disk="$2"; shift 2 ;;
            *)         err "Unknown option: $1"; exit 1 ;;
        esac
    done

    # Detect architecture
    local arch
    arch=$(uname -m)
    [[ "$arch" == "aarch64" ]] && arch="arm64" || arch="x86_64"

    # Check if profile exists, install if not
    if ! incus profile show "$profile" &>/dev/null; then
        info "Profile '$profile' not found. Installing..."
        cmd_profiles install
    fi

    info "Creating VM: $name (profile: $profile, arch: $arch)"
    incus init "$name" --vm --empty --profile "$profile"

    if [[ -n "$image" ]]; then
        info "Attaching install ISO: $image"
        incus config device add "$name" install disk source="$(realpath "$image")"
    fi

    if [[ -n "$disk" ]]; then
        info "Attaching disk image: $disk"
        incus config device add "$name" data disk source="$(realpath "$disk")"
    fi

    ok "VM '$name' created. Start with: iwt vm start $name"
}

# --- Profile commands ---

cmd_profiles() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        install)
            cmd_profiles_install "$@"
            ;;
        list)
            info "Available profiles:"
            find "$IWT_ROOT/profiles" -name '*.yaml' -printf "  %P\n" | sort
            ;;
        help|--help|-h)
            cat <<EOF
iwt profiles - Manage Incus VM profiles

Subcommands:
  install [--arch ARCH]   Install profiles into Incus
  list                    List available profile files

Options:
  --arch ARCH    Install only for this architecture (x86_64|arm64)
                 Default: auto-detect from host

Example:
  iwt profiles install
  iwt profiles install --arch arm64
EOF
            ;;
        *)
            err "Unknown profiles subcommand: $subcmd"
            exit 1
            ;;
    esac
}

cmd_profiles_install() {
    local arch=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --arch) arch="$2"; shift 2 ;;
            *)      err "Unknown option: $1"; exit 1 ;;
        esac
    done

    # Auto-detect architecture
    if [[ -z "$arch" ]]; then
        local host_arch
        host_arch=$(uname -m)
        [[ "$host_arch" == "aarch64" ]] && arch="arm64" || arch="x86_64"
    fi

    local profile_dir="$IWT_ROOT/profiles/$arch"
    if [[ ! -d "$profile_dir" ]]; then
        err "No profiles found for architecture: $arch"
        exit 1
    fi

    for profile_file in "$profile_dir"/*.yaml; do
        local profile_name
        profile_name=$(basename "$profile_file" .yaml)
        info "Installing profile: $profile_name (from $arch/$(basename "$profile_file"))"

        if incus profile show "$profile_name" &>/dev/null; then
            incus profile edit "$profile_name" < "$profile_file"
            ok "Updated: $profile_name"
        else
            incus profile create "$profile_name"
            incus profile edit "$profile_name" < "$profile_file"
            ok "Created: $profile_name"
        fi
    done
}

# --- RemoteApp commands ---

cmd_remoteapp() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        launch)
            exec "$IWT_ROOT/remoteapp/backend/launch-app.sh" "$@"
            ;;
        install)
            exec "$IWT_ROOT/remoteapp/freedesktop/generate-desktop-entries.sh" "$@"
            ;;
        discover)
            source "$IWT_ROOT/remoteapp/backend/incus-backend.sh"
            info "Discovering installed Windows applications..."
            vm_list_installed_apps
            ;;
        config)
            local conf="$IWT_ROOT/remoteapp/freedesktop/apps.conf"
            info "App config: $conf"
            if [[ -n "${EDITOR:-}" ]]; then
                "$EDITOR" "$conf"
            else
                cat "$conf"
            fi
            ;;
        help|--help|-h)
            cat <<EOF
iwt remoteapp - Run Windows apps as seamless Linux windows

Subcommands:
  launch <app>    Launch a Windows app (exe name or full path)
  install         Generate .desktop files for Linux app menus
  discover        List installed Windows applications
  config          View/edit the app configuration

Examples:
  iwt remoteapp launch notepad
  iwt remoteapp launch "C:\\Program Files\\app.exe"
  iwt remoteapp install
  iwt remoteapp discover
EOF
            ;;
        *)
            err "Unknown remoteapp subcommand: $subcmd"
            exit 1
            ;;
    esac
}

# --- Main dispatch ---

main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        image)      cmd_image "$@" ;;
        vm)         cmd_vm "$@" ;;
        profiles)   cmd_profiles "$@" ;;
        remoteapp)  cmd_remoteapp "$@" ;;
        doctor)     cmd_doctor "$@" ;;
        version)    echo "iwt v${VERSION}" ;;
        help|--help|-h) show_help ;;
        *)
            err "Unknown command: $cmd"
            show_help
            exit 1
            ;;
    esac
}

main "$@"

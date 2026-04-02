#!/usr/bin/env bash
# iwt - Incus Windows Toolkit
# Unified CLI for Windows VM management on Incus.
#
# Usage: iwt <command> [subcommand] [options]

set -euo pipefail

VERSION="1.1.0"

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

# Source shared library
source "$IWT_ROOT/cli/lib.sh"

# Load user config
load_config

# --- Help ---

show_help() {
    cat <<EOF
iwt - Incus Windows Toolkit v${VERSION}

Usage: iwt <command> [subcommand] [options]

Commands:
  image       Build, pack, and manage Windows VM images
  vm          Create, start, stop, and manage Windows VMs
  disk        Live disk image resize (embiggen-disk)
  rescue      Build and inject Buildroot rescue environments
  guest       Guest tool management (SvcGuest, serviceman, SrvLib)
  apps        Windows app store (install app bundles via winget)
  cloud       Sync backups to cloud storage (S3, B2, rclone)
  fleet       Multi-VM orchestration (start-all, stop-all, backup-all)
  profiles    Install and manage Incus VM profiles
  remoteapp   Launch Windows apps as seamless Linux windows
  tui         Launch interactive terminal UI
  dashboard   Launch web monitoring dashboard
  update      Check for updates and self-update
  doctor      Check system prerequisites
  config      Manage IWT configuration
  version     Show version

Run 'iwt <command> --help' for details on each command.
EOF
}

# --- Doctor (prerequisite check) ---

cmd_doctor() {
    local auto_install=false
    [[ "${1:-}" == "--install" ]] && auto_install=true

    info "Checking prerequisites..."
    local ok_count=0
    local fail_count=0
    local failed_cmds=()

    check() {
        local name="$1" cmd="$2"
        if command -v "$cmd" &>/dev/null; then
            ok "$name ($cmd)"
            ok_count=$((ok_count + 1))
        else
            err "$name not found ($cmd)"
            fail_count=$((fail_count + 1))
            failed_cmds+=("$cmd")
        fi
    }

    check "Incus"           incus
    check "QEMU (img)"      qemu-img
    check "curl"            curl
    check "xfreerdp3"       xfreerdp3
    check "wimlib"          wimlib-imagex
    check "hivex"           hivexsh

    # Check for at least one ISO tool
    if command -v xorriso &>/dev/null; then
        ok "ISO tool (xorriso)"
        ok_count=$((ok_count + 1))
    elif command -v mkisofs &>/dev/null; then
        ok "ISO tool (mkisofs)"
        ok_count=$((ok_count + 1))
    else
        err "ISO tool not found (need xorriso or mkisofs)"
        fail_count=$((fail_count + 1))
        failed_cmds+=("xorriso")
    fi

    check "shellcheck"      shellcheck

    # Check KVM
    if [[ -e /dev/kvm ]]; then
        ok "KVM (/dev/kvm)"
        ok_count=$((ok_count + 1))
    elif [[ -r /proc/cpuinfo ]] && grep -qE '(vmx|svm)' /proc/cpuinfo; then
        warn "KVM supported by CPU but /dev/kvm missing (load kvm module?)"
        fail_count=$((fail_count + 1))
    else
        err "KVM not available (/dev/kvm missing)"
        fail_count=$((fail_count + 1))
    fi

    # Architecture
    local arch
    arch=$(detect_arch)
    info "Host architecture: $arch"

    # Incus connectivity
    if command -v incus &>/dev/null; then
        if incus info &>/dev/null 2>&1; then
            ok "Incus daemon reachable"
            ok_count=$((ok_count + 1))
        else
            err "Incus daemon not reachable (is incusd running?)"
            fail_count=$((fail_count + 1))
        fi
    fi

    # --- Btrfs checks ---
    echo ""
    info "Btrfs storage (IWT_STORAGE_BACKEND=${IWT_STORAGE_BACKEND:-btrfs}):"
    if check_btrfs_host; then
        ok "  Btrfs kernel module"
        ok_count=$((ok_count + 1))
    else
        warn "  Btrfs kernel module not loaded (run: modprobe btrfs)"
        failed_cmds+=(btrfs-module)
    fi
    if check_btrfs_progs; then
        ok "  btrfs-progs (btrfs, mkfs.btrfs)"
        ok_count=$((ok_count + 1))
    else
        err "  btrfs-progs not found"
        fail_count=$((fail_count + 1))
        failed_cmds+=(btrfs)
    fi
    if incus storage list --format csv 2>/dev/null | grep -q ',btrfs,'; then
        ok "  Incus btrfs pool exists"
        ok_count=$((ok_count + 1))
    else
        info "  No Incus btrfs pool yet (create with: iwt vm storage create-pool)"
    fi

    # --- DwarFS checks ---
    echo ""
    info "DwarFS image format (IWT_IMAGE_FORMAT=${IWT_IMAGE_FORMAT:-dwarfs}):"
    if check_dwarfs_host; then
        ok "  DwarFS tools (mkdwarfs, dwarfs, dwarfsextract)"
        ok_count=$((ok_count + 1))
    else
        err "  DwarFS tools not found"
        fail_count=$((fail_count + 1))
        failed_cmds+=(mkdwarfs)
    fi
    if check_fuse_host; then
        ok "  FUSE (/dev/fuse + fusermount)"
        ok_count=$((ok_count + 1))
    else
        err "  FUSE not available (needed for DwarFS share mounts)"
        fail_count=$((fail_count + 1))
        failed_cmds+=(fusermount)
    fi

    # --- bdfs (btrfs-dwarfs-framework) checks ---
    echo ""
    info "bdfs hybrid storage (IWT_BDFS_ENABLED=${IWT_BDFS_ENABLED:-false}):"
    if check_bdfs_host; then
        ok "  bdfs CLI + bdfs_daemon"
        ok_count=$((ok_count + 1))
    else
        warn "  bdfs not found (optional; build from https://github.com/Interested-Deving-1896/btrfs-dwarfs-framework)"
    fi
    if check_bdfs_module; then
        ok "  btrfs_dwarfs kernel module"
        ok_count=$((ok_count + 1))
    else
        warn "  btrfs_dwarfs module not loaded (optional; run: sudo insmod btrfs_dwarfs.ko)"
    fi
    if check_bdfs_daemon; then
        ok "  bdfs_daemon running"
        ok_count=$((ok_count + 1))
    else
        warn "  bdfs_daemon not running (optional; start with: iwt vm storage bdfs-daemon start)"
    fi

    # Check shares.state for stale entries (blend not mounted or VM not running)
    local bdfs_state_file="${IWT_BDFS_RUNTIME:-/run/iwt/bdfs}/shares.state"
    if [[ -f "$bdfs_state_file" && -s "$bdfs_state_file" ]]; then
        local stale_count=0
        while IFS='|' read -r blend_mount vm_name share_name _cache _btrfs_uuid _dwarfs_uuid; do
            [[ -n "$share_name" ]] || continue
            if ! mountpoint -q "$blend_mount" 2>/dev/null; then
                warn "  Stale bdfs share '$share_name': blend not mounted at $blend_mount"
                warn "    Remount: iwt vm storage bdfs-blend mount --mountpoint $blend_mount ..."
                stale_count=$((stale_count + 1))
            fi
            if ! incus info "$vm_name" &>/dev/null 2>&1; then
                warn "  Stale bdfs share '$share_name': VM '$vm_name' not found"
                warn "    Clean up: iwt vm storage bdfs-unshare --vm $vm_name --name $share_name"
                stale_count=$((stale_count + 1))
            elif ! incus config device show "$vm_name" 2>/dev/null | grep -q "^${share_name}:"; then
                warn "  Stale bdfs share '$share_name': not attached to VM '$vm_name' (state file out of sync)"
                warn "    Clean up: iwt vm storage bdfs-unshare --vm $vm_name --name $share_name"
                stale_count=$((stale_count + 1))
            fi
        done < "$bdfs_state_file"
        if [[ $stale_count -eq 0 ]]; then
            ok "  bdfs shares.state: all entries healthy"
            ok_count=$((ok_count + 1))
        else
            fail_count=$((fail_count + stale_count))
        fi
    fi

    # Check demote timers are active if shares exist
    if [[ -f "$bdfs_state_file" && -s "$bdfs_state_file" ]]; then
        if systemctl list-timers "iwt-bdfs-demote*" --no-pager 2>/dev/null | grep -q "iwt-bdfs-demote"; then
            ok "  bdfs demote timer(s) active"
            ok_count=$((ok_count + 1))
        else
            warn "  No bdfs demote timer found — BTRFS upper layer may grow unbounded"
            warn "    Schedule one: iwt vm storage bdfs-demote-schedule --blend-mount <path> --interval 24h"
        fi
    fi

    # --- EROFS checks ---
    echo ""
    info "EROFS image format (IWT_IMAGE_FORMAT=${IWT_IMAGE_FORMAT:-dwarfs}):"
    if check_erofs_host; then
        ok "  erofs-utils (mkfs.erofs, dump.erofs)"
        ok_count=$((ok_count + 1))
    else
        warn "  erofs-utils not found (optional; needed for IWT_IMAGE_FORMAT=erofs)"
        # Not a hard failure — EROFS is optional
    fi
    if check_erofs_kernel; then
        ok "  Kernel EROFS support"
        ok_count=$((ok_count + 1))
    else
        warn "  Kernel EROFS not detected (erofsfuse fallback will be used)"
    fi

    # --- fuse-overlayfs checks ---
    echo ""
    info "Overlay storage (IWT_STORAGE_BACKEND=${IWT_STORAGE_BACKEND:-btrfs}):"
    if check_fuse_overlayfs_host; then
        ok "  fuse-overlayfs"
        ok_count=$((ok_count + 1))
    else
        warn "  fuse-overlayfs not found (optional; needed for rootless overlay backend)"
    fi

    # --- dm-verity checks ---
    echo ""
    info "Image integrity (dm-verity):"
    if check_verity_host; then
        ok "  veritysetup (cryptsetup)"
        ok_count=$((ok_count + 1))
    else
        warn "  veritysetup not found (optional; needed for --with-verity image signing)"
    fi

    # --- Guest service tools ---
    echo ""
    info "Guest service tools:"
    if [[ -f "${IWT_CACHE_DIR:-$HOME/.cache/iwt}/svcguest/SvcGuest.exe" ]]; then
        ok "  SvcGuest.exe (cached)"
        ok_count=$((ok_count + 1))
    else
        warn "  SvcGuest.exe not cached (run: iwt guest svcguest --install)"
    fi
    if command -v serviceman &>/dev/null; then
        ok "  serviceman"
        ok_count=$((ok_count + 1))
    else
        warn "  serviceman not found (optional; run: iwt guest serviceman --install)"
    fi
    if command -v "${IWT_MINGW_PREFIX:-x86_64-w64-mingw32}-gcc" &>/dev/null; then
        ok "  MinGW cross-compiler (${IWT_MINGW_PREFIX:-x86_64-w64-mingw32}-gcc)"
        ok_count=$((ok_count + 1))
    else
        warn "  MinGW cross-compiler not found (optional; needed for iwt guest srvlib --build)"
    fi

    # --- Image pipeline tools ---
    echo ""
    info "Image pipeline tools:"
    for tool in mkosi partitionfs partsfs; do
        if command -v "$tool" &>/dev/null; then
            ok "  $tool"
            ok_count=$((ok_count + 1))
        else
            warn "  $tool not found (optional)"
        fi
    done
    if command -v cargo &>/dev/null; then
        ok "  cargo (for partymix)"
        ok_count=$((ok_count + 1))
    else
        warn "  cargo not found (optional; needed for partymix MBR assembly)"
    fi

    echo ""
    info "Results: $ok_count passed, $fail_count failed"

    # Show install suggestions for failures
    if [[ $fail_count -gt 0 ]]; then
        echo ""
        info "Install suggestions:"
        for cmd in "${failed_cmds[@]}"; do
            suggest_install "$cmd"
        done

        if [[ "$auto_install" == true ]]; then
            echo ""
            info "Auto-install is not yet implemented. Install the packages above manually."
        fi
    fi

    [[ $fail_count -eq 0 ]] && return 0 || return 1
}

# --- Config commands ---

cmd_config() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        init)
            init_config
            ;;
        show)
            if [[ -f "$IWT_CONFIG_FILE" ]]; then
                cat "$IWT_CONFIG_FILE"
            else
                info "No config file found. Run 'iwt config init' to create one."
            fi
            ;;
        edit)
            if [[ ! -f "$IWT_CONFIG_FILE" ]]; then
                init_config
            fi
            "${EDITOR:-vi}" "$IWT_CONFIG_FILE"
            ;;
        path)
            echo "$IWT_CONFIG_FILE"
            ;;
        help|--help|-h)
            cat <<EOF
iwt config - Manage IWT configuration

Subcommands:
  init    Create default config file
  show    Display current config
  edit    Open config in \$EDITOR
  path    Print config file path

Config location: \$HOME/.config/iwt/config
Override with: IWT_CONFIG_FILE=/path/to/config
EOF
            ;;
        *)
            err "Unknown config subcommand: $subcmd"
            exit 1
            ;;
    esac
}

# --- Image commands ---

cmd_image() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        build)
            exec "$IWT_ROOT/image-pipeline/scripts/build-image.sh" "$@"
            ;;
        download)
            exec "$IWT_ROOT/image-pipeline/scripts/download-iso.sh" "$@"
            ;;
        drivers)
            exec "$IWT_ROOT/image-pipeline/scripts/manage-drivers.sh" "$@"
            ;;
        list)
            exec "$IWT_ROOT/image-pipeline/scripts/download-iso.sh" --list-versions
            ;;
        pack)
            exec "$IWT_ROOT/storage/setup-dwarfs.sh" pack "$@"
            ;;
        unpack)
            exec "$IWT_ROOT/storage/setup-dwarfs.sh" unpack "$@"
            ;;
        help|--help|-h)
            cat <<EOF
iwt image - Build, pack, and download Windows images for Incus

Subcommands:
  download    Download a Windows ISO from Microsoft
  build       Build an Incus-ready image from an ISO
  drivers     Download and manage VirtIO drivers and WinBtrfs
  pack        Pack a built image into a compressed .dwarfs archive
  unpack      Extract a .dwarfs archive to a directory
  list        List available Windows versions

Download options:
  --version VER         10 | 11 | server-2022 | server-2025 (default: 11)
  --lang LANG           Language (default: "English (United States)")
  --arch ARCH           x86_64 | arm64 (default: auto-detect)
  --output-dir DIR      Download directory (default: current directory)
  --list-langs          List available languages for a version

Build options:
  --iso PATH            Path to Windows ISO (required)
  --arch ARCH           x86_64 | arm64 (default: auto-detect)
  --edition EDITION     Windows edition (default: Pro)
  --slim                Strip bloatware (tiny11-style)
  --output PATH         Output image path
  --inject-drivers      Inject VirtIO + platform drivers
  --inject-winbtrfs     Inject WinBtrfs driver (default: IWT_INJECT_WINBTRFS)
  --woa-drivers PATH    WOA driver directory (ARM only)
  --size SIZE           Disk size (default: 64G)
  --keep-work           Preserve work directory for debugging

Pack/Unpack options:
  --source PATH         Source directory or .qcow2 / .dwarfs file (required)
  --output PATH         Output path
  --level N             DwarFS compression level 1-9 (default: 7)

Examples:
  iwt image list
  iwt image download --version 11
  iwt image build --iso Win11_24H2.iso --slim --inject-drivers --inject-winbtrfs
  iwt image pack --source windows-x86_64.qcow2
  iwt image unpack --source windows-x86_64.dwarfs
  iwt image drivers winbtrfs download
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
            elif vm_exists; then
                info "$IWT_VM_NAME is stopped"
            else
                err "VM '$IWT_VM_NAME' does not exist"
                return 1
            fi
            ;;
        list)
            info "Incus VMs:"
            incus list --format table type=virtual-machine
            ;;
        rdp)
            IWT_VM_NAME="${1:-$IWT_VM_NAME}"
            shift || true
            vm_start
            vm_wait_for_rdp
            rdp_connect_full "$@"
            ;;
        snapshot)
            cmd_vm_snapshot "$@"
            ;;
        share)
            cmd_vm_share "$@"
            ;;
        gpu)
            cmd_vm_gpu "$@"
            ;;
        usb)
            cmd_vm_usb "$@"
            ;;
        net)
            cmd_vm_net "$@"
            ;;
        setup-guest)
            exec "$IWT_ROOT/guest/setup-guest.sh" "$@"
            ;;
        storage)
            cmd_vm_storage "$@"
            ;;
        template)
            cmd_vm_template "$@"
            ;;
        backup)
            exec "$IWT_ROOT/cli/backup.sh" "$@"
            ;;
        export)
            source "$IWT_ROOT/cli/backup.sh"
            cmd_export "$@"
            ;;
        import)
            source "$IWT_ROOT/cli/backup.sh"
            cmd_import "$@"
            ;;
        first-boot)
            exec "$IWT_ROOT/guest/first-boot.sh" "$@"
            ;;
        monitor)
            exec "$IWT_ROOT/cli/monitor.sh" "$@"
            ;;
        harden)
            exec "$IWT_ROOT/security/harden-vm.sh" "$@"
            ;;
        security-audit)
            exec "$IWT_ROOT/guest/setup-security-audit.sh" "$@"
            ;;
        secure-boot)
            exec "$IWT_ROOT/guest/setup-secure-boot-check.sh" "$@"
            ;;
        help|--help|-h)
            cat <<EOF
iwt vm - Manage Windows VMs

Subcommands:
  create [options]    Create a new Windows VM
  start [name]        Start a VM
  stop [name]         Stop a VM
  status [name]       Show VM status
  list                List all Incus VMs
  rdp [name]          Open full RDP desktop session
  setup-guest [opts]  Install guest tools (WinFsp, VirtIO, WinBtrfs) in a running VM
  storage <action>    Manage Btrfs storage pools and DwarFS shares
  template <action>   List and inspect VM templates/presets
  backup <action>     Backup and restore VMs
  export [name]       Publish VM as reusable Incus image
  import <path>       Import VM from backup or image
  first-boot [opts]   Run first-boot PowerShell scripts in a VM
  monitor <action>    VM resource monitoring and stats
  harden [opts]       Security hardening (Secure Boot, TPM, isolation)
  security-audit      Run Windows security posture audit inside the VM
  secure-boot         Audit UEFI Secure Boot variables inside the VM
  snapshot <action>   Manage VM snapshots
  share <action>      Manage shared folders
  gpu <action>        Manage GPU passthrough
  usb <action>        Manage USB device passthrough
  net <action>        Manage networking and port forwarding

Create options:
  --name NAME         VM name (default: windows)
  --template NAME     Use a preset template (gaming, dev, server, minimal)
  --profile PROFILE   Incus profile to use (default: windows-desktop)
  --image PATH        Path to modified ISO from 'iwt image build'
  --disk PATH         Path to QCOW2 disk image

Setup-guest options:
  --all                 Install everything and run all checks (default)
  --install-winfsp      Install WinFsp only
  --install-virtio      Install VirtIO guest tools only
  --install-winbtrfs    Install WinBtrfs driver only
  --security-audit      Run security audit after setup
  --secure-boot-check   Run Secure Boot variable audit after setup
  --check               Only check status, don't install
  --vm NAME             Target VM

Security-audit options:
  --vm NAME             Target VM
  --report FILE         Save JSON report to FILE
  --json                Output raw JSON
  --fail-on-warn        Exit 1 on any warnings (useful in CI)

Secure-boot options:
  --vm NAME             Target VM
  --apply-dbx-update    Apply pending DBX updates
  --apply-2023-certs    Apply 2023 KEK/DB certificate updates
  --apply-revocations   Apply DBX + revoke Windows Production PCA 2011
  --report FILE         Save JSON report to FILE

Example:
  iwt vm create --template gaming --name my-gaming-vm
  iwt vm create --name win11 --image windows-modified.iso
  iwt vm rdp win11
  iwt vm backup create win11
  iwt vm first-boot --vm win11 --run "winget install Git.Git"
  iwt vm net forward 8080 --to 80
  iwt vm usb attach 046d:c52b --name logitech

Run 'iwt vm net --help', 'iwt vm usb --help', etc. for details.
EOF
            ;;
        *)
            err "Unknown vm subcommand: $subcmd"
            exit 1
            ;;
    esac
}

# --- VM storage subcommand ---

cmd_vm_storage() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        create-pool|attach-btrfs|detach-btrfs|list-pools|check)
            exec "$IWT_ROOT/storage/setup-btrfs-pool.sh" "$subcmd" "$@"
            ;;
        mount-share|umount-share|list-shares)
            exec "$IWT_ROOT/storage/setup-dwarfs.sh" "$subcmd" "$@"
            ;;
        dwarfs-check)
            exec "$IWT_ROOT/storage/setup-dwarfs.sh" check "$@"
            ;;

        # bdfs (btrfs-dwarfs-framework) subcommands
        bdfs-partition)
            exec "$IWT_ROOT/storage/setup-bdfs.sh" partition "$@"
            ;;
        bdfs-blend)
            exec "$IWT_ROOT/storage/setup-bdfs.sh" blend "$@"
            ;;
        bdfs-export)
            exec "$IWT_ROOT/storage/setup-bdfs.sh" export "$@"
            ;;
        bdfs-import)
            exec "$IWT_ROOT/storage/setup-bdfs.sh" import "$@"
            ;;
        bdfs-snapshot)
            exec "$IWT_ROOT/storage/setup-bdfs.sh" snapshot "$@"
            ;;
        bdfs-promote)
            exec "$IWT_ROOT/storage/setup-bdfs.sh" promote "$@"
            ;;
        bdfs-demote)
            exec "$IWT_ROOT/storage/setup-bdfs.sh" demote "$@"
            ;;
        bdfs-status)
            exec "$IWT_ROOT/storage/setup-bdfs.sh" status "$@"
            ;;
        bdfs-daemon)
            exec "$IWT_ROOT/storage/setup-bdfs.sh" daemon "$@"
            ;;
        bdfs-check)
            exec "$IWT_ROOT/storage/setup-bdfs.sh" check "$@"
            ;;
        bdfs-share)
            exec "$IWT_ROOT/storage/setup-bdfs.sh" share "$@"
            ;;
        bdfs-unshare)
            exec "$IWT_ROOT/storage/setup-bdfs.sh" unshare "$@"
            ;;
        bdfs-list-shares)
            exec "$IWT_ROOT/storage/setup-bdfs.sh" list-shares "$@"
            ;;
        bdfs-demote-schedule)
            exec "$IWT_ROOT/storage/setup-bdfs.sh" demote-schedule "$@"
            ;;
        bdfs-demote-run)
            exec "$IWT_ROOT/storage/setup-bdfs.sh" demote-run "$@"
            ;;
        bdfs-remount-all)
            exec "$IWT_ROOT/storage/setup-bdfs.sh" remount-all "$@"
            ;;
        bdfs-blend-persist)
            exec "$IWT_ROOT/storage/setup-bdfs.sh" blend-persist "$@"
            ;;
        bdfs-install-units)
            exec "$IWT_ROOT/storage/setup-bdfs.sh" install-units "${2:-install}"
            ;;
        bdfs-uninstall-units)
            exec "$IWT_ROOT/storage/setup-bdfs.sh" install-units "uninstall"
            ;;

        # EROFS subcommands
        erofs-pack)
            exec "$IWT_ROOT/storage/setup-erofs.sh" --pack "$@"
            ;;
        erofs-unpack)
            exec "$IWT_ROOT/storage/setup-erofs.sh" --unpack "$@"
            ;;
        erofs-mount)
            exec "$IWT_ROOT/storage/setup-erofs.sh" --mount "$@"
            ;;
        erofs-umount)
            exec "$IWT_ROOT/storage/setup-erofs.sh" --umount "$@"
            ;;
        erofs-check)
            exec "$IWT_ROOT/storage/setup-erofs.sh" --check "$@"
            ;;
        erofs-install)
            exec "$IWT_ROOT/storage/setup-erofs.sh" --install "$@"
            ;;
        # fuse-overlayfs subcommands
        overlay-create)
            exec "$IWT_ROOT/storage/setup-fuse-overlayfs.sh" --create "$@"
            ;;
        overlay-mount)
            exec "$IWT_ROOT/storage/setup-fuse-overlayfs.sh" --mount "$@"
            ;;
        overlay-umount)
            exec "$IWT_ROOT/storage/setup-fuse-overlayfs.sh" --umount "$@"
            ;;
        overlay-commit)
            exec "$IWT_ROOT/storage/setup-fuse-overlayfs.sh" --commit "$@"
            ;;
        overlay-status)
            exec "$IWT_ROOT/storage/setup-fuse-overlayfs.sh" --status "$@"
            ;;
        overlay-check)
            exec "$IWT_ROOT/storage/setup-fuse-overlayfs.sh" --check "$@"
            ;;
        # dm-verity subcommands
        verity-sign)
            exec "$IWT_ROOT/storage/setup-verity.sh" --sign "$@"
            ;;
        verity-verify)
            exec "$IWT_ROOT/storage/setup-verity.sh" --verify "$@"
            ;;
        verity-mount)
            exec "$IWT_ROOT/storage/setup-verity.sh" --mount "$@"
            ;;
        verity-umount)
            exec "$IWT_ROOT/storage/setup-verity.sh" --umount "$@"
            ;;
        verity-info)
            exec "$IWT_ROOT/storage/setup-verity.sh" --info "$@"
            ;;
        verity-check)
            exec "$IWT_ROOT/storage/setup-verity.sh" --check "$@"
            ;;
        help|--help|-h)
            cat <<EOF
iwt vm storage - Manage storage pools, image formats, and integrity

Btrfs subcommands:
  create-pool       Create a Btrfs-backed Incus storage pool
  attach-btrfs      Pass a Btrfs block device/image through to a VM
  detach-btrfs      Remove a Btrfs block device from a VM
  list-pools        List Incus storage pools and Btrfs status
  check             Check host Btrfs support

DwarFS subcommands:
  mount-share       Mount a .dwarfs archive and expose it to a VM via virtiofs
  umount-share      Unmount a DwarFS virtiofs share
  list-shares       List active DwarFS mounts
  dwarfs-check      Check host DwarFS tool availability

bdfs subcommands (btrfs-dwarfs-framework hybrid storage):
  bdfs-partition    add|remove|list|show bdfs partitions
  bdfs-blend        mount|umount the unified BTRFS+DwarFS namespace
  bdfs-export       Export a BTRFS subvolume to a compressed DwarFS image
  bdfs-import       Import a DwarFS image into a BTRFS subvolume
  bdfs-snapshot     CoW snapshot of a DwarFS image's BTRFS container
  bdfs-promote      Make a DwarFS-backed path writable (extract to BTRFS)
  bdfs-demote       Compress a BTRFS subvolume into a DwarFS image
  bdfs-share            Expose a blend namespace to a Windows VM via virtiofs
  bdfs-unshare          Remove a blend virtiofs share from a VM
  bdfs-list-shares      List active bdfs virtiofs shares
  bdfs-demote-schedule  Install/remove systemd timer for automatic demote
  bdfs-demote-run       Run a single demote pass (invoked by the timer)
  bdfs-remount-all      Re-attach all registered shares after reboot/crash
  bdfs-blend-persist    Declare blend namespaces that mount at boot
  bdfs-install-units    Install systemd units for boot-time recovery
  bdfs-uninstall-units  Remove systemd units
  bdfs-status           Show bdfs partition and blend status
  bdfs-daemon       start|stop|status bdfs_daemon
  bdfs-check        Verify bdfs host prerequisites

EROFS subcommands:
  erofs-pack SRC DST    Pack directory into EROFS image
  erofs-unpack SRC DST  Extract EROFS image to directory
  erofs-mount IMG MNT   Mount EROFS image (kernel or erofsfuse)
  erofs-umount MNT      Unmount EROFS image
  erofs-check           Check erofs-utils availability
  erofs-install         Install erofs-utils

Overlay subcommands (rootless fuse-overlayfs):
  overlay-create VM     Create overlay stack for VM
  overlay-mount VM      Mount overlay for VM
  overlay-umount VM     Unmount overlay for VM
  overlay-commit VM     Flatten upper layer into base
  overlay-status VM     Show overlay status
  overlay-check         Check fuse-overlayfs availability

dm-verity subcommands:
  verity-sign IMG       Generate Merkle tree and root hash
  verity-verify IMG     Verify image against stored root hash
  verity-mount IMG MNT  Map through dm-verity and mount (requires root)
  verity-umount MNT     Remove dm-verity mapping and unmount
  verity-info IMG       Show root hash and tree parameters
  verity-check          Check veritysetup availability

Examples:
  iwt vm storage create-pool
  iwt vm storage erofs-pack /mnt/rootfs rootfs.erofs
  iwt vm storage verity-sign rootfs.erofs
  iwt vm storage overlay-create win11
  iwt vm storage overlay-mount win11
EOF
            ;;
        *)
            err "Unknown storage subcommand: $subcmd"
            exec "$IWT_ROOT/storage/setup-btrfs-pool.sh" help
            ;;
    esac
}

# --- Disk subcommand ---

cmd_disk() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        resize)
            exec "$IWT_ROOT/storage/setup-embiggen-disk.sh" --resize "$@"
            ;;
        info)
            exec "$IWT_ROOT/storage/setup-embiggen-disk.sh" --info "$@"
            ;;
        check)
            exec "$IWT_ROOT/storage/setup-embiggen-disk.sh" --check "$@"
            ;;
        install)
            exec "$IWT_ROOT/storage/setup-embiggen-disk.sh" --install "$@"
            ;;
        help|--help|-h)
            cat <<EOF
iwt disk - Live disk image resize

Subcommands:
  resize IMG SIZE   Resize disk image to SIZE (e.g. 20G, +5G)
  info IMG          Show current image and partition sizes
  check             Check embiggen-disk availability
  install           Install embiggen-disk

Examples:
  iwt disk resize ~/.local/share/incus/storage-pools/iwt-btrfs/virtual-machines/win11/disk.qcow2 +10G
  iwt disk info win11.qcow2
EOF
            ;;
        *)
            err "Unknown disk subcommand: $subcmd"
            exit 1
            ;;
    esac
}

# --- Rescue subcommand ---

cmd_rescue() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        check)
            exec "$IWT_ROOT/image-pipeline/scripts/setup-buildroot.sh" --check "$@"
            ;;
        install)
            exec "$IWT_ROOT/image-pipeline/scripts/setup-buildroot.sh" --install "$@"
            ;;
        configure)
            exec "$IWT_ROOT/image-pipeline/scripts/setup-buildroot.sh" --configure "$@"
            ;;
        build)
            exec "$IWT_ROOT/image-pipeline/scripts/setup-buildroot.sh" --build "$@"
            ;;
        inject)
            exec "$IWT_ROOT/image-pipeline/scripts/setup-buildroot.sh" --inject "$@"
            ;;
        uki-build)
            exec "$IWT_ROOT/storage/setup-verity-squash-root.sh" --build "$@"
            ;;
        uki-verify)
            exec "$IWT_ROOT/storage/setup-verity-squash-root.sh" --verify "$@"
            ;;
        help|--help|-h)
            cat <<EOF
iwt rescue - Build and inject rescue environments for Windows VMs

Subcommands:
  check             Check Buildroot prerequisites
  install           Install Buildroot and dependencies
  configure         Generate IWT Buildroot defconfig
  build             Build the rescue image (30-90 min first run)
  inject VM         Attach rescue image to VM as secondary boot disk
  uki-build SRC DST Build a verity-protected UKI from rootfs directory
  uki-verify UKI    Verify UKI integrity

Examples:
  iwt rescue check
  iwt rescue install
  iwt rescue configure
  iwt rescue build
  iwt rescue inject win11
  iwt rescue uki-build /mnt/rescue-rootfs rescue.efi
EOF
            ;;
        *)
            err "Unknown rescue subcommand: $subcmd"
            exit 1
            ;;
    esac
}

# --- Guest tools subcommand ---

cmd_guest() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        svcguest)
            exec "$IWT_ROOT/guest/setup-svcguest.sh" "$@"
            ;;
        serviceman)
            exec "$IWT_ROOT/guest/setup-serviceman.sh" "$@"
            ;;
        srvlib)
            exec "$IWT_ROOT/guest/setup-srvlib.sh" "$@"
            ;;
        winbtrfs)
            exec "$IWT_ROOT/guest/setup-winbtrfs.sh" "$@"
            ;;
        winfsp)
            exec "$IWT_ROOT/guest/setup-winfsp.sh" "$@"
            ;;
        help|--help|-h)
            cat <<EOF
iwt guest - Guest tool management

Subcommands:
  svcguest [opts]   Manage SvcGuest Windows service host
  serviceman [opts] Manage host-side daemons via serviceman
  srvlib [opts]     Build and inject SrvLib-based Windows agents
  winbtrfs [opts]   Manage WinBtrfs driver
  winfsp [opts]     Manage WinFsp driver

Examples:
  iwt guest svcguest --install
  iwt guest svcguest --inject win11
  iwt guest serviceman --add iwt-monitor "$IWT_ROOT/cli/monitor.sh"
  iwt guest srvlib --install
  iwt guest srvlib --build iwt-agent
  iwt guest srvlib --inject win11 /tmp/iwt-build/agents/iwt-agent.exe
EOF
            ;;
        *)
            err "Unknown guest subcommand: $subcmd"
            exit 1
            ;;
    esac
}

cmd_vm_create() {
    local name="windows"
    local profile="windows-desktop"
    local image=""
    local disk=""
    local template=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)     name="$2"; shift 2 ;;
            --profile)  profile="$2"; shift 2 ;;
            --template) template="$2"; shift 2 ;;
            --image)    image="$2"; shift 2 ;;
            --disk)     disk="$2"; shift 2 ;;
            *)          err "Unknown option: $1"; exit 1 ;;
        esac
    done

    # Apply template if specified
    local tpl_cpu="" tpl_mem="" tpl_disk="" gpu_overlay=""
    if [[ -n "$template" ]]; then
        source "$IWT_ROOT/templates/engine.sh"
        local tpl_file
        tpl_file=$(template_path "$template")
        [[ -f "$tpl_file" ]] || die "Template not found: $template (available: $(find "$IWT_ROOT/templates/" -name '*.yaml' -exec basename {} .yaml \; 2>/dev/null | tr '\n' ' '))"

        # Template values (CLI flags override template)
        profile=$(template_get "$tpl_file" "profile" "$profile")
        tpl_cpu=$(template_get_nested "$tpl_file" "resources" "cpu")
        tpl_mem=$(template_get_nested "$tpl_file" "resources" "memory")
        tpl_disk=$(template_get_nested "$tpl_file" "resources" "disk")
        gpu_overlay=$(template_get "$tpl_file" "gpu_overlay")

        info "Using template: $template"
    fi

    # Check if VM already exists
    if incus info "$name" &>/dev/null; then
        die "VM '$name' already exists. Delete it first: incus delete $name"
    fi

    # Check if profile exists, install if not
    if ! incus profile show "$profile" &>/dev/null; then
        info "Profile '$profile' not found. Installing..."
        cmd_profiles install
    fi

    info "Creating VM: $name (profile: $profile)"
    incus init "$name" --vm --empty --profile "$profile"

    # Apply GPU overlay profile if specified
    if [[ -n "$gpu_overlay" && "$gpu_overlay" != "none" ]]; then
        local gpu_profile="gpu-${gpu_overlay}"
        if incus profile show "$gpu_profile" &>/dev/null; then
            info "Applying GPU overlay: $gpu_profile"
            incus profile add "$name" "$gpu_profile"
        else
            warn "GPU profile '$gpu_profile' not found; skipping overlay"
        fi
    fi

    # Apply template resource overrides
    if [[ -n "$tpl_cpu" ]]; then
        incus config set "$name" limits.cpu="$tpl_cpu"
    fi
    if [[ -n "$tpl_mem" ]]; then
        incus config set "$name" limits.memory="$tpl_mem"
    fi
    if [[ -n "$tpl_disk" ]]; then
        incus config device set "$name" root size="$tpl_disk"
    fi

    # Apply template config overrides
    if [[ -n "$template" ]]; then
        local boot_autostart
        boot_autostart=$(template_get_nested "$tpl_file" "config" "boot.autostart")
        if [[ -n "$boot_autostart" ]]; then
            incus config set "$name" boot.autostart="$boot_autostart"
        fi
        local boot_priority
        boot_priority=$(template_get_nested "$tpl_file" "config" "boot.autostart.priority")
        if [[ -n "$boot_priority" ]]; then
            incus config set "$name" boot.autostart.priority="$boot_priority"
        fi
    fi

    # Apply template device additions
    if [[ -n "$template" ]]; then
        while IFS='|' read -r dev_name dev_key dev_val; do
            [[ -n "$dev_name" ]] || continue
            # Skip root device (handled above via size override)
            [[ "$dev_name" == "root" ]] && continue
            local dev_type
            dev_type=$(template_get_nested "$tpl_file" "devices" "type" "disk")
            # Add device if it doesn't exist, or set property
            if ! incus config device get "$name" "$dev_name" type &>/dev/null 2>&1; then
                incus config device add "$name" "$dev_name" "$dev_type" "${dev_key}=${dev_val}" 2>/dev/null || true
            else
                incus config device set "$name" "$dev_name" "${dev_key}=${dev_val}" 2>/dev/null || true
            fi
        done < <(template_get_devices "$tpl_file")
    fi

    if [[ -n "$image" ]]; then
        [[ -f "$image" ]] || die "ISO not found: $image"
        info "Attaching install ISO: $image"
        incus config device add "$name" install disk source="$(realpath "$image")"
    fi

    if [[ -n "$disk" ]]; then
        [[ -f "$disk" ]] || die "Disk image not found: $disk"
        info "Attaching disk image: $disk"
        incus config device add "$name" data disk source="$(realpath "$disk")"
    fi

    # Store template name and first-boot scripts in VM metadata for post-install
    if [[ -n "$template" ]]; then
        incus config set "$name" user.iwt.template="$template"

        # Save first-boot scripts to config for later execution
        local boot_scripts
        boot_scripts=$(template_get_first_boot_scripts "$tpl_file" | base64 -w0)
        if [[ -n "$boot_scripts" ]]; then
            incus config set "$name" user.iwt.first_boot="$boot_scripts"
        fi
    fi

    ok "VM '$name' created. Start with: iwt vm start $name"
    if [[ -n "$template" ]]; then
        info "Template '$template' applied. After Windows install, run: iwt vm setup-guest --vm $name"
    fi
}

# --- Template subcommand ---

cmd_vm_template() {
    local subcmd="${1:-help}"
    shift || true

    source "$IWT_ROOT/templates/engine.sh"

    case "$subcmd" in
        list|ls)
            bold "Available VM templates:"
            echo ""
            template_list
            ;;
        show)
            local name="${1:?Usage: iwt vm template show <name>}"
            template_show "$name"
            ;;
        help|--help|-h)
            cat <<EOF
iwt vm template - Manage VM templates/presets

Subcommands:
  list          List available templates
  show <name>   Show template details

Available templates:
$(template_list 2>/dev/null || echo "  (none)")

Templates are YAML files in: $IWT_ROOT/templates/
Create custom templates by copying an existing one.

Usage with vm create:
  iwt vm create --template gaming --name my-vm
  iwt vm create --template dev --name dev-vm
  iwt vm create --template server --name srv
EOF
            ;;
        *)
            err "Unknown template subcommand: $subcmd"
            exit 1
            ;;
    esac
}

cmd_vm_snapshot() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        create)
            local snap_name=""
            local stateful=false
            local vm_name=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --name)     snap_name="$2"; shift 2 ;;
                    --stateful) stateful=true; shift ;;
                    --vm)       vm_name="$2"; shift 2 ;;
                    *)          err "Unknown option: $1"; exit 1 ;;
                esac
            done

            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            snapshot_create "$snap_name" "$stateful"
            ;;
        restore)
            local snap_name=""
            local stateful=false
            local vm_name=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --stateful) stateful=true; shift ;;
                    --vm)       vm_name="$2"; shift 2 ;;
                    -*)         err "Unknown option: $1"; exit 1 ;;
                    *)          snap_name="$1"; shift ;;
                esac
            done

            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            [[ -n "$snap_name" ]] || die "Usage: iwt vm snapshot restore <name> [--stateful] [--vm NAME]"
            snapshot_restore "$snap_name" "$stateful"
            ;;
        delete|rm)
            local snap_name=""
            local vm_name=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --vm) vm_name="$2"; shift 2 ;;
                    -*)   err "Unknown option: $1"; exit 1 ;;
                    *)    snap_name="$1"; shift ;;
                esac
            done

            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            [[ -n "$snap_name" ]] || die "Usage: iwt vm snapshot delete <name> [--vm NAME]"
            snapshot_delete "$snap_name"
            ;;
        list|ls)
            local vm_name=""
            [[ "${1:-}" == "--vm" ]] && { vm_name="$2"; shift 2; }
            [[ -n "${1:-}" && "${1:-}" != -* ]] && { vm_name="$1"; shift; }
            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            snapshot_list
            ;;
        auto)
            cmd_vm_snapshot_auto "$@"
            ;;
        help|--help|-h)
            cat <<EOF
iwt vm snapshot - Manage VM snapshots

Subcommands:
  create [options]        Create a snapshot
  restore <name>          Restore a snapshot
  delete <name>           Delete a snapshot
  list [vm-name]          List snapshots
  auto <action>           Manage auto-snapshot schedule

Create options:
  --name NAME             Snapshot name (auto-generated if omitted)
  --stateful              Capture running VM state (memory + disk)
  --vm NAME               Target VM (default: \$IWT_VM_NAME)

Auto subcommands:
  auto set <schedule>     Set cron schedule (e.g. "@daily", "0 6 * * *")
  auto show               Show current schedule
  auto disable            Disable auto-snapshots

Auto options:
  --expiry DURATION       Auto-delete after duration (e.g. "7d", "30d")
  --pattern PATTERN       Snapshot naming pattern (default: "iwt-snap%d")

Examples:
  iwt vm snapshot create --name pre-update
  iwt vm snapshot create --stateful --name checkpoint
  iwt vm snapshot list
  iwt vm snapshot restore pre-update
  iwt vm snapshot delete pre-update
  iwt vm snapshot auto set "@daily" --expiry 7d
  iwt vm snapshot auto show
  iwt vm snapshot auto disable
EOF
            ;;
        *)
            err "Unknown snapshot subcommand: $subcmd"
            exit 1
            ;;
    esac
}

cmd_vm_snapshot_auto() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        set)
            local schedule="${1:?Usage: iwt vm snapshot auto set <schedule> [--expiry DURATION] [--pattern PATTERN]}"
            shift
            local expiry=""
            local pattern="iwt-snap%d"
            local vm_name=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --expiry)  expiry="$2"; shift 2 ;;
                    --pattern) pattern="$2"; shift 2 ;;
                    --vm)      vm_name="$2"; shift 2 ;;
                    *)         err "Unknown option: $1"; exit 1 ;;
                esac
            done

            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            snapshot_schedule_set "$schedule" "$expiry" "$pattern"
            ;;
        show)
            local vm_name=""
            [[ "${1:-}" == "--vm" ]] && { vm_name="$2"; shift 2; }
            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            snapshot_schedule_show
            ;;
        disable)
            local vm_name=""
            [[ "${1:-}" == "--vm" ]] && { vm_name="$2"; shift 2; }
            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            snapshot_schedule_disable
            ;;
        help|--help|-h)
            echo "Usage: iwt vm snapshot auto <set|show|disable> [options]"
            echo "Run 'iwt vm snapshot --help' for details."
            ;;
        *)
            err "Unknown auto subcommand: $subcmd"
            exit 1
            ;;
    esac
}

cmd_vm_share() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        add)
            local host_path=""
            local share_name=""
            local drive_letter=""
            local vm_name=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --name)   share_name="$2"; shift 2 ;;
                    --drive)  drive_letter="$2"; shift 2 ;;
                    --vm)     vm_name="$2"; shift 2 ;;
                    -*)       err "Unknown option: $1"; exit 1 ;;
                    *)        host_path="$1"; shift ;;
                esac
            done

            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            [[ -n "$host_path" ]] || die "Usage: iwt vm share add <host_path> [--name NAME] [--drive LETTER] [--vm NAME]"
            share_add "$host_path" "$share_name" "$drive_letter"
            ;;
        remove|rm)
            local share_name=""
            local vm_name=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --vm) vm_name="$2"; shift 2 ;;
                    -*)   err "Unknown option: $1"; exit 1 ;;
                    *)    share_name="$1"; shift ;;
                esac
            done

            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            [[ -n "$share_name" ]] || die "Usage: iwt vm share remove <name> [--vm NAME]"
            share_remove "$share_name"
            ;;
        list|ls)
            local vm_name=""
            [[ "${1:-}" == "--vm" ]] && { vm_name="$2"; shift 2; }
            [[ -n "${1:-}" && "${1:-}" != -* ]] && { vm_name="$1"; shift; }
            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"

            bold "Shared folders on $IWT_VM_NAME:"
            printf "  %-15s %-40s %s\n" "NAME" "HOST PATH" "GUEST PATH"
            printf "  %-15s %-40s %s\n" "----" "---------" "----------"
            share_list
            ;;
        mount)
            local share_name=""
            local drive_letter=""
            local vm_name=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --vm) vm_name="$2"; shift 2 ;;
                    -*)   err "Unknown option: $1"; exit 1 ;;
                    *)
                        if [[ -z "$share_name" ]]; then
                            share_name="$1"
                        else
                            drive_letter="$1"
                        fi
                        shift
                        ;;
                esac
            done

            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            [[ -n "$share_name" ]] || die "Usage: iwt vm share mount <name> <drive_letter> [--vm NAME]"
            [[ -n "$drive_letter" ]] || die "Drive letter required (e.g. S)"
            share_mount_in_guest "$share_name" "$drive_letter"
            ;;
        mount-all)
            local vm_name=""
            [[ "${1:-}" == "--vm" ]] && { vm_name="$2"; shift 2; }
            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            share_mount_all
            ;;
        config)
            local conf="$IWT_ROOT/remoteapp/freedesktop/shares.conf"
            if [[ "${1:-}" == "edit" ]]; then
                "${EDITOR:-vi}" "$conf"
            else
                info "Share drive map config: $conf"
                cat "$conf"
            fi
            ;;
        help|--help|-h)
            cat <<EOF
iwt vm share - Manage shared folders between host and Windows VM

Subcommands:
  add <path> [opts]       Share a host directory with the VM
  remove <name>           Remove a shared folder
  list                    List shared folders
  mount <name> <letter>   Map a share to a Windows drive letter
  mount-all               Mount all shares from shares.conf
  config [edit]           View/edit drive letter mappings

Add options:
  --name NAME             Share name (default: directory basename)
  --drive LETTER          Auto-mount as this drive letter (e.g. P)
  --vm NAME               Target VM (default: \$IWT_VM_NAME)

Drive letter mounting requires WinFsp or VirtIO-FS in the guest.
The guest tools installer (setup-guest-tools.ps1) installs WinFsp
if the MSI is bundled in the image.

Examples:
  iwt vm share add ~/Projects --name projects --drive P
  iwt vm share add /data/media --name media
  iwt vm share list
  iwt vm share mount media M
  iwt vm share mount-all
  iwt vm share remove projects
  iwt vm share config edit
EOF
            ;;
        *)
            err "Unknown share subcommand: $subcmd"
            exit 1
            ;;
    esac
}

cmd_vm_net() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        forward|fwd)
            cmd_vm_net_forward "$@"
            ;;
        nic)
            cmd_vm_net_nic "$@"
            ;;
        status)
            local vm_name=""
            [[ "${1:-}" == "--vm" ]] && { vm_name="$2"; shift 2; }
            [[ -n "${1:-}" && "${1:-}" != -* ]] && { vm_name="$1"; shift; }
            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            net_status
            ;;
        help|--help|-h)
            cat <<EOF
iwt vm net - Manage networking and port forwarding

Subcommands:
  forward <action>    Manage port forwards
  nic <action>        Manage network interfaces
  status              Show networking status (IP, NICs, forwards)

Forward subcommands:
  forward add <port> [opts]   Forward a host port to the VM
  forward remove <name>       Remove a port forward
  forward remove --all        Remove all IWT port forwards
  forward list                List port forwards

Forward options:
  --to PORT                   VM port (default: same as listen port)
  --proto PROTO               tcp | udp (default: tcp)
  --listen ADDR               Listen address (default: 0.0.0.0)
  --name NAME                 Forward name (default: proto-port)
  --vm NAME                   Target VM

NIC subcommands:
  nic add <name> [opts]       Add a network interface
  nic remove <name>           Remove a network interface

NIC options:
  --network NETWORK           Incus network (default: incusbr0)
  --type TYPE                 bridged | macvlan | sriov | physical (default: bridged)

Examples:
  iwt vm net status
  iwt vm net forward add 8080
  iwt vm net forward add 3000 --to 3000 --name webapp
  iwt vm net forward add 53 --proto udp --name dns
  iwt vm net forward list
  iwt vm net forward remove webapp
  iwt vm net nic add eth1 --network incusbr1
  iwt vm net nic remove eth1
EOF
            ;;
        *)
            err "Unknown net subcommand: $subcmd"
            exit 1
            ;;
    esac
}

cmd_vm_net_forward() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        add)
            local listen_port=""
            local connect_port=""
            local protocol="tcp"
            local listen_addr="0.0.0.0"
            local fwd_name=""
            local vm_name=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --to)     connect_port="$2"; shift 2 ;;
                    --proto)  protocol="$2"; shift 2 ;;
                    --listen) listen_addr="$2"; shift 2 ;;
                    --name)   fwd_name="$2"; shift 2 ;;
                    --vm)     vm_name="$2"; shift 2 ;;
                    -*)       err "Unknown option: $1"; exit 1 ;;
                    *)        listen_port="$1"; shift ;;
                esac
            done

            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            [[ -n "$listen_port" ]] || die "Usage: iwt vm net forward add <port> [--to PORT] [--proto tcp|udp]"
            [[ -z "$connect_port" ]] && connect_port="$listen_port"

            net_forward_add "$listen_port" "$connect_port" "$protocol" "$listen_addr" "$fwd_name"
            ;;
        remove|rm)
            local fwd_name=""
            local vm_name=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --vm)  vm_name="$2"; shift 2 ;;
                    --all) [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
                           net_forward_remove_all; return ;;
                    -*)    err "Unknown option: $1"; exit 1 ;;
                    *)     fwd_name="$1"; shift ;;
                esac
            done

            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            [[ -n "$fwd_name" ]] || die "Usage: iwt vm net forward remove <name> or --all"
            net_forward_remove "$fwd_name"
            ;;
        list|ls)
            local vm_name=""
            [[ "${1:-}" == "--vm" ]] && { vm_name="$2"; shift 2; }
            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"

            bold "Port forwards on $IWT_VM_NAME:"
            printf "  %-20s %-30s    %s\n" "NAME" "LISTEN" "CONNECT"
            printf "  %-20s %-30s    %s\n" "----" "------" "-------"
            net_forward_list
            ;;
        help|--help|-h)
            echo "Usage: iwt vm net forward <add|remove|list> [options]"
            echo "Run 'iwt vm net --help' for details."
            ;;
        *)
            err "Unknown forward subcommand: $subcmd"
            exit 1
            ;;
    esac
}

cmd_vm_net_nic() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        add)
            local nic_name=""
            local network="incusbr0"
            local nic_type="bridged"
            local vm_name=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --network) network="$2"; shift 2 ;;
                    --type)    nic_type="$2"; shift 2 ;;
                    --vm)      vm_name="$2"; shift 2 ;;
                    -*)        err "Unknown option: $1"; exit 1 ;;
                    *)         nic_name="$1"; shift ;;
                esac
            done

            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            [[ -n "$nic_name" ]] || die "Usage: iwt vm net nic add <name> [--network NET] [--type TYPE]"
            net_nic_add "$nic_name" "$network" "$nic_type"
            ;;
        remove|rm)
            local nic_name=""
            local vm_name=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --vm) vm_name="$2"; shift 2 ;;
                    -*)   err "Unknown option: $1"; exit 1 ;;
                    *)    nic_name="$1"; shift ;;
                esac
            done

            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            [[ -n "$nic_name" ]] || die "Usage: iwt vm net nic remove <name>"
            net_nic_remove "$nic_name"
            ;;
        help|--help|-h)
            echo "Usage: iwt vm net nic <add|remove> [options]"
            echo "Run 'iwt vm net --help' for details."
            ;;
        *)
            err "Unknown nic subcommand: $subcmd"
            exit 1
            ;;
    esac
}

cmd_vm_usb() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        attach)
            local vendor_id=""
            local product_id=""
            local device_name=""
            local required="true"
            local vm_name=""

            # First two positional args are vendor_id and product_id
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --name)     device_name="$2"; shift 2 ;;
                    --optional) required="false"; shift ;;
                    --vm)       vm_name="$2"; shift 2 ;;
                    -*)         err "Unknown option: $1"; exit 1 ;;
                    *)
                        if [[ -z "$vendor_id" ]]; then
                            vendor_id="$1"
                        elif [[ -z "$product_id" ]]; then
                            product_id="$1"
                        else
                            err "Unexpected argument: $1"; exit 1
                        fi
                        shift
                        ;;
                esac
            done

            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"

            # Support vendor:product shorthand (e.g. 046d:c52b)
            if [[ "$vendor_id" == *:* && -z "$product_id" ]]; then
                product_id="${vendor_id##*:}"
                vendor_id="${vendor_id%%:*}"
            fi

            [[ -n "$vendor_id" && -n "$product_id" ]] || \
                die "Usage: iwt vm usb attach <vendor_id> <product_id> [--name NAME] [--optional]"

            usb_attach "$vendor_id" "$product_id" "$device_name" "$required"
            ;;
        detach)
            local device_name=""
            local vm_name=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --vm)  vm_name="$2"; shift 2 ;;
                    --all) [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
                           usb_detach_all; return ;;
                    -*)    err "Unknown option: $1"; exit 1 ;;
                    *)     device_name="$1"; shift ;;
                esac
            done

            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            [[ -n "$device_name" ]] || die "Usage: iwt vm usb detach <name> [--vm NAME] or --all"
            usb_detach "$device_name"
            ;;
        list)
            local vm_name=""
            [[ "${1:-}" == "--vm" ]] && { vm_name="$2"; shift 2; }
            [[ -n "${1:-}" && "${1:-}" != -* ]] && { vm_name="$1"; shift; }
            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"

            bold "USB devices on $IWT_VM_NAME:"
            printf "  %-20s %-10s %s\n" "NAME" "ID" "MODE"
            printf "  %-20s %-10s %s\n" "----" "--" "----"
            usb_list_vm
            ;;
        list-host)
            bold "USB devices on host:"
            usb_list_host
            ;;
        help|--help|-h)
            cat <<EOF
iwt vm usb - Manage USB device passthrough

USB devices support hotplugging -- attach and detach while the VM is running.

Subcommands:
  attach <vid> <pid>      Attach a USB device by vendor:product ID
  detach <name>           Detach a USB device
  detach --all            Detach all IWT USB devices
  list                    List USB devices attached to the VM
  list-host               List USB devices on the host

Attach options:
  <vid> <pid>             Vendor and product ID (hex, e.g. 046d c52b)
  <vid:pid>               Shorthand (e.g. 046d:c52b)
  --name NAME             Device name (default: vid-pid)
  --optional              Don't block VM start if device is missing
  --vm NAME               Target VM

Examples:
  iwt vm usb list-host
  iwt vm usb attach 046d:c52b --name logitech-receiver
  iwt vm usb attach 0bda 8153 --name usb-ethernet --optional
  iwt vm usb list
  iwt vm usb detach logitech-receiver
  iwt vm usb detach --all
EOF
            ;;
        *)
            err "Unknown usb subcommand: $subcmd"
            exit 1
            ;;
    esac
}

cmd_vm_gpu() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        attach)
            local gpu_type="physical"
            local pci_addr=""
            local vendor_id=""
            local product_id=""
            local mdev_profile=""
            local vm_name=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --type)      gpu_type="$2"; shift 2 ;;
                    --pci)       pci_addr="$2"; shift 2 ;;
                    --vendor)    vendor_id="$2"; shift 2 ;;
                    --product)   product_id="$2"; shift 2 ;;
                    --mdev)      mdev_profile="$2"; shift 2 ;;
                    --vm)        vm_name="$2"; shift 2 ;;
                    *)           err "Unknown option: $1"; exit 1 ;;
                esac
            done

            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            gpu_attach "$gpu_type" "$pci_addr" "$vendor_id" "$product_id" "$mdev_profile"
            ;;
        detach)
            local vm_name=""
            [[ "${1:-}" == "--vm" ]] && { vm_name="$2"; shift 2; }
            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            gpu_detach
            ;;
        status)
            local vm_name=""
            [[ "${1:-}" == "--vm" ]] && { vm_name="$2"; shift 2; }
            [[ -n "${1:-}" && "${1:-}" != -* ]] && { vm_name="$1"; shift; }
            [[ -n "$vm_name" ]] && IWT_VM_NAME="$vm_name"
            gpu_status
            ;;
        list-host)
            gpu_list_host
            ;;
        iommu)
            local subcmd2="${1:-check}"
            shift || true
            case "$subcmd2" in
                check)  gpu_check_iommu ;;
                groups) gpu_show_iommu_groups ;;
                *)      err "Unknown iommu subcommand: $subcmd2"; exit 1 ;;
            esac
            ;;
        looking-glass|lg)
            local subcmd2="${1:-launch}"
            shift || true
            case "$subcmd2" in
                check)  looking_glass_check ;;
                launch) looking_glass_launch "$@" ;;
                *)      err "Unknown looking-glass subcommand: $subcmd2"; exit 1 ;;
            esac
            ;;
        help|--help|-h)
            cat <<EOF
iwt vm gpu - Manage GPU passthrough

Subcommands:
  attach [options]        Attach a GPU to the VM (VM must be stopped)
  detach                  Remove GPU from the VM
  status                  Show GPU device status
  list-host               List GPUs available on the host
  iommu check             Check IOMMU status
  iommu groups            Show IOMMU groups and devices
  looking-glass check     Check looking-glass prerequisites
  looking-glass launch    Launch looking-glass client

Attach options:
  --type TYPE             physical | mdev | sriov (default: physical)
  --pci ADDRESS           PCI address (e.g. 0000:01:00.0)
  --vendor ID             Vendor ID (e.g. 10de for NVIDIA)
  --product ID            Product ID
  --mdev PROFILE          mdev profile name (required for --type mdev)
  --vm NAME               Target VM

GPU profiles (apply as overlays):
  vfio-passthrough        Full physical GPU passthrough
  mdev-virtual-gpu        Intel GVT-g / NVIDIA vGPU
  sriov-gpu               SR-IOV virtual function
  looking-glass           VFIO + IVSHMEM for looking-glass

Examples:
  iwt vm gpu list-host
  iwt vm gpu iommu check
  iwt vm gpu iommu groups
  iwt vm gpu attach --type physical --pci 0000:01:00.0
  iwt vm gpu attach --type mdev --mdev i915-GVTg_V5_4
  iwt vm gpu status
  iwt vm gpu detach
  iwt vm gpu looking-glass check
  iwt vm gpu looking-glass launch
EOF
            ;;
        *)
            err "Unknown gpu subcommand: $subcmd"
            exit 1
            ;;
    esac
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
        show)
            local profile_name="${1:?Usage: iwt profiles show <name>}"
            local arch
            arch=$(detect_arch)
            local profile_file="$IWT_ROOT/profiles/$arch/$profile_name.yaml"
            if [[ ! -f "$profile_file" ]]; then
                # Try the other arch
                profile_file=$(find "$IWT_ROOT/profiles" -name "$profile_name.yaml" -print -quit)
            fi
            if [[ -n "$profile_file" && -f "$profile_file" ]]; then
                cat "$profile_file"
            else
                die "Profile not found: $profile_name"
            fi
            ;;
        diff)
            # Show differences between local profile files and what's in Incus
            local arch
            arch=$(detect_arch)
            local profile_dir="$IWT_ROOT/profiles/$arch"
            for profile_file in "$profile_dir"/*.yaml; do
                local pname
                pname=$(basename "$profile_file" .yaml)
                if incus profile show "$pname" &>/dev/null; then
                    info "Diff for $pname:"
                    diff <(incus profile show "$pname") "$profile_file" || true
                else
                    info "$pname: not installed in Incus"
                fi
            done
            ;;
        help|--help|-h)
            cat <<EOF
iwt profiles - Manage Incus VM profiles

Subcommands:
  install [--arch ARCH]   Install profiles into Incus
  list                    List available profile files
  show <name>             Display a profile's YAML
  diff                    Compare local profiles with Incus

Options:
  --arch ARCH    Install only for this architecture (x86_64|arm64)
                 Default: auto-detect from host

Example:
  iwt profiles install
  iwt profiles show windows-desktop
  iwt profiles diff
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
    local include_gpu=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --arch) arch="$2"; shift 2 ;;
            --gpu)  include_gpu=true; shift ;;
            *)      err "Unknown option: $1"; exit 1 ;;
        esac
    done

    if [[ -z "$arch" ]]; then
        arch=$(detect_arch)
    fi

    local profile_dir="$IWT_ROOT/profiles/$arch"
    if [[ ! -d "$profile_dir" ]]; then
        die "No profiles found for architecture: $arch"
    fi

    require_cmd incus

    # Install arch-specific profiles
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

    # Install GPU overlay profiles if requested
    if [[ "$include_gpu" == true ]]; then
        local gpu_dir="$IWT_ROOT/profiles/gpu"
        if [[ -d "$gpu_dir" ]]; then
            for profile_file in "$gpu_dir"/*.yaml; do
                local profile_name
                profile_name=$(basename "$profile_file" .yaml)
                info "Installing GPU profile: $profile_name"

                if incus profile show "$profile_name" &>/dev/null; then
                    incus profile edit "$profile_name" < "$profile_file"
                    ok "Updated: $profile_name"
                else
                    incus profile create "$profile_name"
                    incus profile edit "$profile_name" < "$profile_file"
                    ok "Created: $profile_name"
                fi
            done
        fi
    fi
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
            if [[ "${1:-}" == "edit" ]]; then
                "${EDITOR:-vi}" "$conf"
            else
                info "App config: $conf"
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
  config [edit]   View or edit the app configuration

Examples:
  iwt remoteapp launch notepad
  iwt remoteapp launch "C:\\Program Files\\app.exe"
  iwt remoteapp install
  iwt remoteapp discover
  iwt remoteapp config edit
EOF
            ;;
        *)
            err "Unknown remoteapp subcommand: $subcmd"
            exit 1
            ;;
    esac
}

# --- Tab completion ---

cmd_completion() {
    local shell="${1:-bash}"
    case "$shell" in
        bash)
            cat <<'COMP'
_iwt_completions() {
    local cur prev commands
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    commands="image vm disk rescue guest profiles remoteapp doctor config version help"

    case "$prev" in
        iwt)
            COMPREPLY=($(compgen -W "$commands" -- "$cur"))
            ;;
        image)
            COMPREPLY=($(compgen -W "download build drivers pack unpack list help" -- "$cur"))
            ;;
        vm)
            COMPREPLY=($(compgen -W "create start stop status list rdp snapshot share gpu usb net setup-guest storage template backup export import first-boot monitor harden security-audit secure-boot help" -- "$cur"))
            ;;
        profiles)
            COMPREPLY=($(compgen -W "install list show diff help" -- "$cur"))
            ;;
        remoteapp)
            COMPREPLY=($(compgen -W "launch install discover config help" -- "$cur"))
            ;;
        config)
            COMPREPLY=($(compgen -W "init show edit path help" -- "$cur"))
            ;;
    esac
}
complete -F _iwt_completions iwt
COMP
            ;;
        zsh)
            cat <<'COMP'
#compdef iwt
_iwt() {
    local -a commands=(
        'image:Build and manage Windows VM images'
        'vm:Create, start, stop, and manage Windows VMs'
        'profiles:Install and manage Incus VM profiles'
        'remoteapp:Launch Windows apps as seamless Linux windows'
        'doctor:Check system prerequisites'
        'config:Manage IWT configuration'
        'version:Show version'
    )
    _arguments '1:command:->cmd' '*::arg:->args'
    case $state in
        cmd) _describe 'command' commands ;;
        args)
            case $words[1] in
                image)     _values 'subcommand' download build drivers pack unpack list help ;;
                vm)        _values 'subcommand' create start stop status list rdp snapshot share gpu usb net setup-guest storage template backup export import first-boot monitor harden security-audit secure-boot help ;;
                profiles)  _values 'subcommand' install list show diff help ;;
                remoteapp) _values 'subcommand' launch install discover config help ;;
                config)    _values 'subcommand' init show edit path help ;;
            esac
            ;;
    esac
}
_iwt
COMP
            ;;
        *)
            err "Unsupported shell: $shell (use bash or zsh)"
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
        disk)       cmd_disk "$@" ;;
        rescue)     cmd_rescue "$@" ;;
        guest)      cmd_guest "$@" ;;
        apps)       exec "$IWT_ROOT/guest/app-store.sh" "$@" ;;
        cloud)      exec "$IWT_ROOT/cli/cloud-sync.sh" "$@" ;;
        fleet)      exec "$IWT_ROOT/cli/fleet.sh" "$@" ;;
        profiles)   cmd_profiles "$@" ;;
        remoteapp)  cmd_remoteapp "$@" ;;
        tui)        exec "$IWT_ROOT/tui/iwt-tui.sh" "$@" ;;
        dashboard)  exec "$IWT_ROOT/cli/web-dashboard.sh" "$@" ;;
        update)     exec "$IWT_ROOT/cli/update.sh" "$@" ;;
        doctor)     cmd_doctor "$@" ;;
        config)     cmd_config "$@" ;;
        completion) cmd_completion "$@" ;;
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

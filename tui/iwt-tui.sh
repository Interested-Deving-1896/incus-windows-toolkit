#!/usr/bin/env bash
# IWT Terminal UI
# Interactive menu-driven interface for the Incus Windows Toolkit.
#
# Requires: dialog (or whiptail as fallback)
#
# Usage: iwt-tui.sh
#    or: iwt tui

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(dirname "$SCRIPT_DIR")"
IWT_CMD="$IWT_ROOT/cli/iwt.sh"

source "$IWT_ROOT/cli/lib.sh"
load_config

# --- Dialog backend ---

DIALOG=""
export DIALOG_OK=0
export DIALOG_CANCEL=1
export DIALOG_ESC=255

_detect_dialog() {
    if command -v dialog &>/dev/null; then
        DIALOG="dialog"
    elif command -v whiptail &>/dev/null; then
        DIALOG="whiptail"
    else
        die "Neither dialog nor whiptail found. Install one: sudo apt install dialog"
    fi
}

# Wrapper: run dialog and capture selection to stdout
_dlg() {
    "$DIALOG" --backtitle "IWT - Incus Windows Toolkit" "$@" 3>&1 1>&2 2>&3
}

_dlg_menu() {
    local title="$1" text="$2"
    shift 2
    _dlg --title "$title" --menu "$text" 0 0 0 "$@"
}

_dlg_input() {
    local title="$1" text="$2" default="${3:-}"
    _dlg --title "$title" --inputbox "$text" 0 60 "$default"
}

_dlg_yesno() {
    local title="$1" text="$2"
    "$DIALOG" --backtitle "IWT - Incus Windows Toolkit" \
        --title "$title" --yesno "$text" 0 0 3>&1 1>&2 2>&3
}

_dlg_msgbox() {
    local title="$1" text="$2"
    "$DIALOG" --backtitle "IWT - Incus Windows Toolkit" \
        --title "$title" --msgbox "$text" 0 0
}

_dlg_checklist() {
    local title="$1" text="$2"
    shift 2
    _dlg --title "$title" --checklist "$text" 0 0 0 "$@"
}

# Run a command and show output in a scrollable box
_run_and_show() {
    local title="$1"
    shift
    local output
    output=$("$@" 2>&1) || true
    "$DIALOG" --backtitle "IWT - Incus Windows Toolkit" \
        --title "$title" --programbox 20 78 <<< "$output"
}

# Run a command, show output, then pause
_run_cmd() {
    local title="$1"
    shift
    local output
    output=$("$@" 2>&1) || true
    # Strip ANSI color codes for dialog
    output=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')
    _dlg_msgbox "$title" "$output"
}

# --- Main Menu ---

menu_main() {
    while true; do
        local choice
        choice=$(_dlg_menu "Main Menu" "Select an action:" \
            "vm"        "Manage Windows VMs" \
            "image"     "Build & download Windows images" \
            "profiles"  "Manage Incus profiles" \
            "doctor"    "Check prerequisites" \
            "config"    "IWT configuration" \
            "quit"      "Exit") || break

        case "$choice" in
            vm)       menu_vm ;;
            image)    menu_image ;;
            profiles) menu_profiles ;;
            doctor)   _run_cmd "Doctor" "$IWT_CMD" doctor ;;
            config)   menu_config ;;
            quit)     break ;;
        esac
    done
}

# --- VM Menu ---

menu_vm() {
    while true; do
        local choice
        choice=$(_dlg_menu "VM Management" "Select an action:" \
            "status"    "Show VM status" \
            "start"     "Start a VM" \
            "stop"      "Stop a VM" \
            "create"    "Create a new VM" \
            "rdp"       "Open RDP desktop session" \
            "snapshot"  "Manage snapshots" \
            "share"     "Manage shared folders" \
            "gpu"       "Manage GPU passthrough" \
            "usb"       "Manage USB devices" \
            "net"       "Manage networking" \
            "remoteapp" "Launch Windows apps" \
            "back"      "Back to main menu") || break

        case "$choice" in
            status)    menu_vm_status ;;
            start)     menu_vm_action "start" ;;
            stop)      menu_vm_action "stop" ;;
            create)    menu_vm_create ;;
            rdp)       menu_vm_action "rdp" ;;
            snapshot)  menu_snapshot ;;
            share)     menu_share ;;
            gpu)       menu_gpu ;;
            usb)       menu_usb ;;
            net)       menu_net ;;
            remoteapp) menu_remoteapp ;;
            back)      break ;;
        esac
    done
}

_pick_vm() {
    # Let user pick a VM name or type one
    local default="${IWT_VM_NAME:-windows}"
    _dlg_input "Select VM" "VM name:" "$default"
}

menu_vm_status() {
    local vm
    vm=$(_pick_vm) || return
    _run_cmd "VM Status: $vm" "$IWT_CMD" vm status "$vm"
}

menu_vm_action() {
    local action="$1"
    local vm
    vm=$(_pick_vm) || return
    _run_cmd "VM $action: $vm" "$IWT_CMD" vm "$action" "$vm"
}

menu_vm_create() {
    local name profile

    name=$(_dlg_input "Create VM" "VM name:" "windows") || return
    profile=$(_dlg_menu "Create VM" "Select profile:" \
        "windows-desktop" "Desktop with display, TPM, shared folders" \
        "windows-server"  "Headless server configuration") || return

    _run_cmd "Creating VM" "$IWT_CMD" vm create --name "$name" --profile "$profile"
}

# --- Snapshot Menu ---

menu_snapshot() {
    local vm
    vm=$(_pick_vm) || return

    while true; do
        local choice
        choice=$(_dlg_menu "Snapshots: $vm" "Select an action:" \
            "list"    "List snapshots" \
            "create"  "Create a snapshot" \
            "restore" "Restore a snapshot" \
            "delete"  "Delete a snapshot" \
            "auto"    "Configure auto-snapshots" \
            "back"    "Back") || break

        case "$choice" in
            list)
                _run_cmd "Snapshots" IWT_VM_NAME="$vm" "$IWT_CMD" vm snapshot list
                ;;
            create)
                local snap_name
                snap_name=$(_dlg_input "Create Snapshot" "Snapshot name (leave empty for auto):") || continue
                if [[ -n "$snap_name" ]]; then
                    _run_cmd "Create Snapshot" IWT_VM_NAME="$vm" "$IWT_CMD" vm snapshot create --name "$snap_name"
                else
                    _run_cmd "Create Snapshot" IWT_VM_NAME="$vm" "$IWT_CMD" vm snapshot create
                fi
                ;;
            restore)
                local snap_name
                snap_name=$(_dlg_input "Restore Snapshot" "Snapshot name:") || continue
                [[ -n "$snap_name" ]] || continue
                if _dlg_yesno "Confirm" "Restore snapshot '$snap_name'? The VM will be stopped."; then
                    _run_cmd "Restore" IWT_VM_NAME="$vm" "$IWT_CMD" vm snapshot restore "$snap_name"
                fi
                ;;
            delete)
                local snap_name
                snap_name=$(_dlg_input "Delete Snapshot" "Snapshot name:") || continue
                [[ -n "$snap_name" ]] || continue
                if _dlg_yesno "Confirm" "Delete snapshot '$snap_name'?"; then
                    _run_cmd "Delete" IWT_VM_NAME="$vm" "$IWT_CMD" vm snapshot delete "$snap_name"
                fi
                ;;
            auto)
                local schedule
                schedule=$(_dlg_menu "Auto-Snapshot" "Select schedule:" \
                    "@hourly"  "Every hour" \
                    "@daily"   "Every day" \
                    "@weekly"  "Every week" \
                    "disable"  "Disable auto-snapshots" \
                    "show"     "Show current schedule") || continue

                if [[ "$schedule" == "disable" ]]; then
                    _run_cmd "Disable" IWT_VM_NAME="$vm" "$IWT_CMD" vm snapshot auto disable
                elif [[ "$schedule" == "show" ]]; then
                    _run_cmd "Schedule" IWT_VM_NAME="$vm" "$IWT_CMD" vm snapshot auto show
                else
                    local expiry
                    expiry=$(_dlg_input "Expiry" "Auto-delete after (e.g. 7d, 30d):" "7d") || continue
                    _run_cmd "Configure" IWT_VM_NAME="$vm" "$IWT_CMD" vm snapshot auto set "$schedule" --expiry "$expiry"
                fi
                ;;
            back) break ;;
        esac
    done
}

# --- Share Menu ---

menu_share() {
    local vm
    vm=$(_pick_vm) || return

    while true; do
        local choice
        choice=$(_dlg_menu "Shared Folders: $vm" "Select an action:" \
            "list"    "List shared folders" \
            "add"     "Add a shared folder" \
            "mount"   "Mount a share as drive letter" \
            "remove"  "Remove a shared folder" \
            "back"    "Back") || break

        case "$choice" in
            list)
                _run_cmd "Shares" IWT_VM_NAME="$vm" "$IWT_CMD" vm share list
                ;;
            add)
                local host_path share_name drive
                host_path=$(_dlg_input "Add Share" "Host directory path:") || continue
                [[ -n "$host_path" ]] || continue
                share_name=$(_dlg_input "Add Share" "Share name (leave empty for auto):") || continue
                drive=$(_dlg_input "Add Share" "Drive letter (leave empty to skip):") || continue

                local args=(vm share add "$host_path")
                [[ -n "$share_name" ]] && args+=(--name "$share_name")
                [[ -n "$drive" ]] && args+=(--drive "$drive")
                _run_cmd "Add Share" IWT_VM_NAME="$vm" "$IWT_CMD" "${args[@]}"
                ;;
            mount)
                local share_name drive
                share_name=$(_dlg_input "Mount Share" "Share name:") || continue
                drive=$(_dlg_input "Mount Share" "Drive letter (e.g. S):") || continue
                [[ -n "$share_name" && -n "$drive" ]] || continue
                _run_cmd "Mount" IWT_VM_NAME="$vm" "$IWT_CMD" vm share mount "$share_name" "$drive"
                ;;
            remove)
                local share_name
                share_name=$(_dlg_input "Remove Share" "Share name:") || continue
                [[ -n "$share_name" ]] || continue
                _run_cmd "Remove" IWT_VM_NAME="$vm" "$IWT_CMD" vm share remove "$share_name"
                ;;
            back) break ;;
        esac
    done
}

# --- GPU Menu ---

menu_gpu() {
    local vm
    vm=$(_pick_vm) || return

    while true; do
        local choice
        choice=$(_dlg_menu "GPU: $vm" "Select an action:" \
            "status"    "Show GPU status" \
            "list-host" "List host GPUs" \
            "attach"    "Attach a GPU" \
            "detach"    "Detach GPU" \
            "iommu"     "Check IOMMU status" \
            "lg-check"  "Check looking-glass" \
            "lg-launch" "Launch looking-glass" \
            "back"      "Back") || break

        case "$choice" in
            status)
                _run_cmd "GPU Status" IWT_VM_NAME="$vm" "$IWT_CMD" vm gpu status
                ;;
            list-host)
                _run_cmd "Host GPUs" "$IWT_CMD" vm gpu list-host
                ;;
            attach)
                local gpu_type
                gpu_type=$(_dlg_menu "Attach GPU" "GPU type:" \
                    "physical" "Full VFIO passthrough" \
                    "mdev"     "Virtual GPU (GVT-g / vGPU)" \
                    "sriov"    "SR-IOV virtual function") || continue

                local pci_addr
                pci_addr=$(_dlg_input "Attach GPU" "PCI address (e.g. 0000:01:00.0):") || continue

                local args=(vm gpu attach --type "$gpu_type")
                [[ -n "$pci_addr" ]] && args+=(--pci "$pci_addr")

                if [[ "$gpu_type" == "mdev" ]]; then
                    local mdev_profile
                    mdev_profile=$(_dlg_input "Attach GPU" "mdev profile (e.g. i915-GVTg_V5_4):") || continue
                    args+=(--mdev "$mdev_profile")
                fi

                _run_cmd "Attach GPU" IWT_VM_NAME="$vm" "$IWT_CMD" "${args[@]}"
                ;;
            detach)
                if _dlg_yesno "Confirm" "Detach GPU from $vm?"; then
                    _run_cmd "Detach GPU" IWT_VM_NAME="$vm" "$IWT_CMD" vm gpu detach
                fi
                ;;
            iommu)
                _run_cmd "IOMMU" "$IWT_CMD" vm gpu iommu check
                ;;
            lg-check)
                _run_cmd "Looking Glass" "$IWT_CMD" vm gpu looking-glass check
                ;;
            lg-launch)
                # Launch directly (not in dialog -- it needs the terminal)
                clear
                IWT_VM_NAME="$vm" "$IWT_CMD" vm gpu looking-glass launch || true
                ;;
            back) break ;;
        esac
    done
}

# --- USB Menu ---

menu_usb() {
    local vm
    vm=$(_pick_vm) || return

    while true; do
        local choice
        choice=$(_dlg_menu "USB Devices: $vm" "Select an action:" \
            "list"      "List attached USB devices" \
            "list-host" "List host USB devices" \
            "attach"    "Attach a USB device" \
            "detach"    "Detach a USB device" \
            "detach-all" "Detach all USB devices" \
            "back"      "Back") || break

        case "$choice" in
            list)
                _run_cmd "VM USB Devices" IWT_VM_NAME="$vm" "$IWT_CMD" vm usb list
                ;;
            list-host)
                _run_cmd "Host USB Devices" "$IWT_CMD" vm usb list-host
                ;;
            attach)
                local vid_pid dev_name
                vid_pid=$(_dlg_input "Attach USB" "Vendor:Product ID (e.g. 046d:c52b):") || continue
                [[ -n "$vid_pid" ]] || continue
                dev_name=$(_dlg_input "Attach USB" "Device name (leave empty for auto):") || continue

                local args=(vm usb attach "$vid_pid")
                [[ -n "$dev_name" ]] && args+=(--name "$dev_name")
                _run_cmd "Attach USB" IWT_VM_NAME="$vm" "$IWT_CMD" "${args[@]}"
                ;;
            detach)
                local dev_name
                dev_name=$(_dlg_input "Detach USB" "Device name:") || continue
                [[ -n "$dev_name" ]] || continue
                _run_cmd "Detach USB" IWT_VM_NAME="$vm" "$IWT_CMD" vm usb detach "$dev_name"
                ;;
            detach-all)
                if _dlg_yesno "Confirm" "Detach all USB devices from $vm?"; then
                    _run_cmd "Detach All" IWT_VM_NAME="$vm" "$IWT_CMD" vm usb detach --all
                fi
                ;;
            back) break ;;
        esac
    done
}

# --- Networking Menu ---

menu_net() {
    local vm
    vm=$(_pick_vm) || return

    while true; do
        local choice
        choice=$(_dlg_menu "Networking: $vm" "Select an action:" \
            "status"     "Show network status" \
            "fwd-list"   "List port forwards" \
            "fwd-add"    "Add port forward" \
            "fwd-remove" "Remove port forward" \
            "nic-add"    "Add network interface" \
            "nic-remove" "Remove network interface" \
            "back"       "Back") || break

        case "$choice" in
            status)
                _run_cmd "Network Status" IWT_VM_NAME="$vm" "$IWT_CMD" vm net status
                ;;
            fwd-list)
                _run_cmd "Port Forwards" IWT_VM_NAME="$vm" "$IWT_CMD" vm net forward list
                ;;
            fwd-add)
                local listen_port connect_port proto fwd_name
                listen_port=$(_dlg_input "Port Forward" "Host port:") || continue
                [[ -n "$listen_port" ]] || continue
                connect_port=$(_dlg_input "Port Forward" "VM port (default: same):" "$listen_port") || continue
                proto=$(_dlg_menu "Port Forward" "Protocol:" \
                    "tcp" "TCP" \
                    "udp" "UDP") || continue
                fwd_name=$(_dlg_input "Port Forward" "Name (leave empty for auto):") || continue

                local args=(vm net forward add "$listen_port" --to "$connect_port" --proto "$proto")
                [[ -n "$fwd_name" ]] && args+=(--name "$fwd_name")
                _run_cmd "Add Forward" IWT_VM_NAME="$vm" "$IWT_CMD" "${args[@]}"
                ;;
            fwd-remove)
                local fwd_name
                fwd_name=$(_dlg_input "Remove Forward" "Forward name:") || continue
                [[ -n "$fwd_name" ]] || continue
                _run_cmd "Remove Forward" IWT_VM_NAME="$vm" "$IWT_CMD" vm net forward remove "$fwd_name"
                ;;
            nic-add)
                local nic_name network nic_type
                nic_name=$(_dlg_input "Add NIC" "NIC name (e.g. eth1):") || continue
                [[ -n "$nic_name" ]] || continue
                network=$(_dlg_input "Add NIC" "Network:" "incusbr0") || continue
                nic_type=$(_dlg_menu "Add NIC" "NIC type:" \
                    "bridged"  "Bridged (default)" \
                    "macvlan"  "MACVLAN" \
                    "sriov"    "SR-IOV" \
                    "physical" "Physical NIC passthrough") || continue
                _run_cmd "Add NIC" IWT_VM_NAME="$vm" "$IWT_CMD" vm net nic add "$nic_name" --network "$network" --type "$nic_type"
                ;;
            nic-remove)
                local nic_name
                nic_name=$(_dlg_input "Remove NIC" "NIC name:") || continue
                [[ -n "$nic_name" ]] || continue
                _run_cmd "Remove NIC" IWT_VM_NAME="$vm" "$IWT_CMD" vm net nic remove "$nic_name"
                ;;
            back) break ;;
        esac
    done
}

# --- RemoteApp Menu ---

menu_remoteapp() {
    while true; do
        local choice
        choice=$(_dlg_menu "RemoteApp" "Select an action:" \
            "launch"   "Launch a Windows app" \
            "install"  "Generate .desktop entries" \
            "discover" "Discover installed apps" \
            "config"   "View app config" \
            "back"     "Back") || break

        case "$choice" in
            launch)
                local app
                app=$(_dlg_input "Launch App" "App name or exe path (e.g. notepad):") || continue
                [[ -n "$app" ]] || continue
                # Launch directly -- needs the terminal
                clear
                "$IWT_CMD" remoteapp launch "$app" || true
                ;;
            install)
                _run_cmd "Install Desktop Entries" "$IWT_CMD" remoteapp install
                ;;
            discover)
                _run_cmd "Discover Apps" "$IWT_CMD" remoteapp discover
                ;;
            config)
                _run_cmd "App Config" "$IWT_CMD" remoteapp config
                ;;
            back) break ;;
        esac
    done
}

# --- Image Menu ---

menu_image() {
    while true; do
        local choice
        choice=$(_dlg_menu "Image Management" "Select an action:" \
            "list"     "List available Windows versions" \
            "download" "Download a Windows ISO" \
            "build"    "Build an Incus-ready image" \
            "back"     "Back") || break

        case "$choice" in
            list)
                _run_cmd "Available Versions" "$IWT_CMD" image list
                ;;
            download)
                local version lang arch
                version=$(_dlg_menu "Download ISO" "Windows version:" \
                    "11"          "Windows 11" \
                    "10"          "Windows 10" \
                    "server-2025" "Windows Server 2025" \
                    "server-2022" "Windows Server 2022") || continue

                lang=$(_dlg_input "Download ISO" "Language:" "English (United States)") || continue
                arch=$(_dlg_menu "Download ISO" "Architecture:" \
                    "x86_64" "x86_64 (64-bit Intel/AMD)" \
                    "arm64"  "ARM64 (Apple Silicon, Pi, etc.)") || continue

                # Download runs long -- use clear + direct execution
                clear
                "$IWT_CMD" image download --version "$version" --lang "$lang" --arch "$arch" || true
                echo ""
                read -rp "Press Enter to continue..."
                ;;
            build)
                local iso_path
                iso_path=$(_dlg_input "Build Image" "Path to Windows ISO:") || continue
                [[ -n "$iso_path" ]] || continue

                local slim="no"
                _dlg_yesno "Build Image" "Strip bloatware (tiny11-style)?" && slim="yes"

                clear
                local args=(image build --iso "$iso_path")
                [[ "$slim" == "yes" ]] && args+=(--slim)
                "$IWT_CMD" "${args[@]}" || true
                echo ""
                read -rp "Press Enter to continue..."
                ;;
            back) break ;;
        esac
    done
}

# --- Profiles Menu ---

menu_profiles() {
    while true; do
        local choice
        choice=$(_dlg_menu "Profiles" "Select an action:" \
            "list"    "List available profiles" \
            "install" "Install profiles into Incus" \
            "show"    "Show a profile" \
            "back"    "Back") || break

        case "$choice" in
            list)
                _run_cmd "Profiles" "$IWT_CMD" profiles list
                ;;
            install)
                local gpu="no"
                _dlg_yesno "Install Profiles" "Also install GPU overlay profiles?" && gpu="yes"

                local args=(profiles install)
                [[ "$gpu" == "yes" ]] && args+=(--gpu)
                _run_cmd "Install Profiles" "$IWT_CMD" "${args[@]}"
                ;;
            show)
                local name
                name=$(_dlg_input "Show Profile" "Profile name:" "windows-desktop") || continue
                [[ -n "$name" ]] || continue
                _run_cmd "Profile: $name" "$IWT_CMD" profiles show "$name"
                ;;
            back) break ;;
        esac
    done
}

# --- Config Menu ---

menu_config() {
    while true; do
        local choice
        choice=$(_dlg_menu "Configuration" "Select an action:" \
            "show" "Show current config" \
            "init" "Create default config" \
            "edit" "Edit config file" \
            "path" "Show config file path" \
            "back" "Back") || break

        case "$choice" in
            show) _run_cmd "Config" "$IWT_CMD" config show ;;
            init) _run_cmd "Init Config" "$IWT_CMD" config init ;;
            edit)
                clear
                "$IWT_CMD" config edit || true
                ;;
            path) _run_cmd "Config Path" "$IWT_CMD" config path ;;
            back) break ;;
        esac
    done
}

# --- Main ---

main() {
    _detect_dialog
    menu_main
    clear
}

main "$@"

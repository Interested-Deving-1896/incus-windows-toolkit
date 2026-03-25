#!/usr/bin/env bash
# IWT test runner.
# Runs unit tests (no Incus/QEMU required) and optionally integration tests.
#
# Usage:
#   run-tests.sh              Run unit tests only
#   run-tests.sh --all        Run unit + integration tests (requires Incus)
#   run-tests.sh --lint       Run shellcheck only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$IWT_ROOT/cli/lib.sh"

PASSED=0
FAILED=0
SKIPPED=0

run_test() {
    local name="$1"
    shift
    if "$@" 2>/dev/null; then
        ok "PASS: $name"
        PASSED=$((PASSED + 1))
    else
        err "FAIL: $name"
        FAILED=$((FAILED + 1))
    fi
}

skip_test() {
    local name="$1" reason="$2"
    warn "SKIP: $name ($reason)"
    SKIPPED=$((SKIPPED + 1))
}

# --- Unit tests (no external deps) ---

test_cli_help() {
    "$IWT_ROOT/cli/iwt.sh" help | grep -q "Incus Windows Toolkit"
}

test_cli_version() {
    "$IWT_ROOT/cli/iwt.sh" version | grep -qP '^iwt v\d+\.\d+\.\d+'
}

test_cli_subcommands() {
    "$IWT_ROOT/cli/iwt.sh" image --help | grep -q "build"
    "$IWT_ROOT/cli/iwt.sh" vm --help | grep -q "create"
    "$IWT_ROOT/cli/iwt.sh" profiles --help | grep -q "install"
    "$IWT_ROOT/cli/iwt.sh" remoteapp --help | grep -q "launch"
    "$IWT_ROOT/cli/iwt.sh" config --help | grep -q "init"
}

test_cli_unknown_command() {
    ! "$IWT_ROOT/cli/iwt.sh" nonexistent 2>/dev/null
}

test_config_init() {
    local tmp_config
    tmp_config=$(mktemp)
    rm "$tmp_config"
    IWT_CONFIG_FILE="$tmp_config" "$IWT_ROOT/cli/iwt.sh" config init
    [[ -f "$tmp_config" ]]
    grep -q "IWT_VM_NAME" "$tmp_config"
    rm -f "$tmp_config"
}

test_config_show() {
    local tmp_config
    tmp_config=$(mktemp)
    IWT_CONFIG_FILE="$tmp_config" "$IWT_ROOT/cli/iwt.sh" config init 2>/dev/null
    IWT_CONFIG_FILE="$tmp_config" "$IWT_ROOT/cli/iwt.sh" config show | grep -q "IWT_VM_NAME"
    rm -f "$tmp_config"
}

test_completion_bash() {
    "$IWT_ROOT/cli/iwt.sh" completion bash | grep -q "_iwt_completions"
}

test_completion_zsh() {
    "$IWT_ROOT/cli/iwt.sh" completion zsh | grep -q "compdef"
}

test_profiles_list() {
    "$IWT_ROOT/cli/iwt.sh" profiles list | grep -q "windows-desktop"
}

test_profiles_show() {
    "$IWT_ROOT/cli/iwt.sh" profiles show windows-desktop | grep -q "description:"
}

test_profiles_validate() {
    "$IWT_ROOT/profiles/validate.sh"
}

test_lib_detect_arch() {
    source "$IWT_ROOT/cli/lib.sh"
    local arch
    arch=$(detect_arch)
    [[ "$arch" =~ ^(x86_64|arm64)$ ]]
}

test_lib_arch_to_windows() {
    source "$IWT_ROOT/cli/lib.sh"
    [[ "$(arch_to_windows x86_64)" == "amd64" ]]
    [[ "$(arch_to_windows arm64)" == "arm64" ]]
}

test_lib_arch_to_qemu() {
    source "$IWT_ROOT/cli/lib.sh"
    [[ "$(arch_to_qemu x86_64)" == "x86_64" ]]
    [[ "$(arch_to_qemu arm64)" == "aarch64" ]]
}

test_lib_human_size() {
    source "$IWT_ROOT/cli/lib.sh"
    [[ "$(human_size 1073741824)" == "1G" ]]
    [[ "$(human_size 1048576)" == "1M" ]]
    [[ "$(human_size 1024)" == "1K" ]]
    [[ "$(human_size 500)" == "500B" ]]
}

test_build_image_requires_iso() {
    ! "$IWT_ROOT/image-pipeline/scripts/build-image.sh" 2>/dev/null
}

test_download_list_versions() {
    local out
    out=$("$IWT_ROOT/image-pipeline/scripts/download-iso.sh" --list-versions)
    echo "$out" | grep -q "11"
    echo "$out" | grep -q "server-2022"
}

test_download_list_langs() {
    local out
    out=$("$IWT_ROOT/image-pipeline/scripts/download-iso.sh" --list-langs --version 11)
    echo "$out" | grep -q "English"
    out=$("$IWT_ROOT/image-pipeline/scripts/download-iso.sh" --list-langs --version server-2022)
    echo "$out" | grep -q "English"
}

test_download_help() {
    "$IWT_ROOT/image-pipeline/scripts/download-iso.sh" --help | grep -q "version"
}

test_cli_image_list() {
    local output
    output=$("$IWT_ROOT/cli/iwt.sh" image list 2>&1)
    echo "$output" | grep -q "Consumer"
}

test_cli_image_download_help() {
    "$IWT_ROOT/cli/iwt.sh" image --help | grep -q "download"
}

test_cli_vm_snapshot_help() {
    "$IWT_ROOT/cli/iwt.sh" vm snapshot --help | grep -q "create"
    "$IWT_ROOT/cli/iwt.sh" vm snapshot --help | grep -q "restore"
    "$IWT_ROOT/cli/iwt.sh" vm snapshot --help | grep -q "auto"
}

test_cli_vm_help_mentions_snapshot() {
    "$IWT_ROOT/cli/iwt.sh" vm --help | grep -q "snapshot"
}

test_backend_snapshot_functions_exist() {
    source "$IWT_ROOT/remoteapp/backend/incus-backend.sh"
    declare -f snapshot_create &>/dev/null
    declare -f snapshot_restore &>/dev/null
    declare -f snapshot_delete &>/dev/null
    declare -f snapshot_list &>/dev/null
    declare -f snapshot_schedule_set &>/dev/null
    declare -f snapshot_schedule_show &>/dev/null
    declare -f snapshot_schedule_disable &>/dev/null
}

test_cli_vm_share_help() {
    "$IWT_ROOT/cli/iwt.sh" vm share --help | grep -q "add"
    "$IWT_ROOT/cli/iwt.sh" vm share --help | grep -q "mount"
    "$IWT_ROOT/cli/iwt.sh" vm share --help | grep -q "remove"
}

test_cli_vm_help_mentions_share() {
    "$IWT_ROOT/cli/iwt.sh" vm --help | grep -q "share"
}

test_backend_share_functions_exist() {
    source "$IWT_ROOT/remoteapp/backend/incus-backend.sh"
    declare -f share_add &>/dev/null
    declare -f share_remove &>/dev/null
    declare -f share_list &>/dev/null
    declare -f share_mount_in_guest &>/dev/null
    declare -f share_mount_all &>/dev/null
}

test_shares_conf_exists() {
    [[ -f "$IWT_ROOT/remoteapp/freedesktop/shares.conf" ]]
}

test_cli_vm_gpu_help() {
    "$IWT_ROOT/cli/iwt.sh" vm gpu --help | grep -q "attach"
    "$IWT_ROOT/cli/iwt.sh" vm gpu --help | grep -q "looking-glass"
    "$IWT_ROOT/cli/iwt.sh" vm gpu --help | grep -q "iommu"
}

test_cli_vm_help_mentions_gpu() {
    "$IWT_ROOT/cli/iwt.sh" vm --help | grep -q "gpu"
}

test_backend_gpu_functions_exist() {
    source "$IWT_ROOT/remoteapp/backend/incus-backend.sh"
    declare -f gpu_attach &>/dev/null
    declare -f gpu_detach &>/dev/null
    declare -f gpu_status &>/dev/null
    declare -f gpu_list_host &>/dev/null
    declare -f gpu_check_iommu &>/dev/null
    declare -f looking_glass_check &>/dev/null
    declare -f looking_glass_launch &>/dev/null
}

test_gpu_profiles_validate() {
    "$IWT_ROOT/profiles/validate.sh"
}

test_gpu_setup_scripts_exist() {
    [[ -x "$IWT_ROOT/gpu/setup-vfio.sh" ]]
    [[ -x "$IWT_ROOT/gpu/setup-looking-glass.sh" ]]
}

test_cli_vm_usb_help() {
    "$IWT_ROOT/cli/iwt.sh" vm usb --help | grep -q "attach"
    "$IWT_ROOT/cli/iwt.sh" vm usb --help | grep -q "detach"
    "$IWT_ROOT/cli/iwt.sh" vm usb --help | grep -q "list-host"
}

test_cli_vm_help_mentions_usb() {
    "$IWT_ROOT/cli/iwt.sh" vm --help | grep -q "usb"
}

test_backend_usb_functions_exist() {
    source "$IWT_ROOT/remoteapp/backend/incus-backend.sh"
    declare -f usb_attach &>/dev/null
    declare -f usb_detach &>/dev/null
    declare -f usb_detach_all &>/dev/null
    declare -f usb_list_host &>/dev/null
    declare -f usb_list_vm &>/dev/null
}

test_cli_vm_net_help() {
    "$IWT_ROOT/cli/iwt.sh" vm net --help | grep -q "forward"
    "$IWT_ROOT/cli/iwt.sh" vm net --help | grep -q "nic"
    "$IWT_ROOT/cli/iwt.sh" vm net --help | grep -q "status"
}

test_cli_vm_help_mentions_net() {
    "$IWT_ROOT/cli/iwt.sh" vm --help | grep -q "net"
}

test_backend_net_functions_exist() {
    source "$IWT_ROOT/remoteapp/backend/incus-backend.sh"
    declare -f net_forward_add &>/dev/null
    declare -f net_forward_remove &>/dev/null
    declare -f net_forward_list &>/dev/null
    declare -f net_status &>/dev/null
    declare -f net_nic_add &>/dev/null
    declare -f net_nic_remove &>/dev/null
}

test_apps_conf_format() {
    local conf="$IWT_ROOT/remoteapp/freedesktop/apps.conf"
    [[ -f "$conf" ]]
    # Every non-comment, non-empty line should have 4 pipe-separated fields
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue
        local fields
        fields=$(echo "$line" | tr '|' '\n' | wc -l)
        [[ "$fields" -eq 4 ]] || return 1
    done < "$conf"
}

# --- TUI tests ---

test_tui_script_exists() {
    [[ -f "$IWT_ROOT/tui/iwt-tui.sh" ]]
}

test_tui_script_executable() {
    [[ -x "$IWT_ROOT/tui/iwt-tui.sh" ]]
}

test_tui_has_shebang() {
    local first_line
    first_line=$(head -1 "$IWT_ROOT/tui/iwt-tui.sh")
    [[ "$first_line" == "#!/usr/bin/env bash" ]]
}

test_tui_has_main_menu() {
    local content
    content=$(cat "$IWT_ROOT/tui/iwt-tui.sh")
    echo "$content" | grep -q 'menu_main'
}

test_tui_has_dialog_detection() {
    local content
    content=$(cat "$IWT_ROOT/tui/iwt-tui.sh")
    echo "$content" | grep -q 'dialog\|whiptail'
}

test_cli_help_mentions_tui() {
    local output
    output=$("$IWT_ROOT/cli/iwt.sh" help 2>&1)
    echo "$output" | grep -q 'tui'
}

test_cli_tui_dispatch_exists() {
    local content
    content=$(cat "$IWT_ROOT/cli/iwt.sh")
    echo "$content" | grep -q 'tui).*iwt-tui'
}

# --- VirtIO driver management tests ---

test_manage_drivers_script_exists() {
    [[ -x "$IWT_ROOT/image-pipeline/scripts/manage-drivers.sh" ]]
}

test_manage_drivers_help() {
    local output
    output=$("$IWT_ROOT/image-pipeline/scripts/manage-drivers.sh" help 2>&1)
    echo "$output" | grep -q 'download'
    echo "$output" | grep -q 'verify'
}

test_cli_image_drivers_dispatch() {
    grep -q 'drivers)' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'manage-drivers' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_image_help_mentions_drivers() {
    local output
    output=$("$IWT_ROOT/cli/iwt.sh" image help 2>&1)
    echo "$output" | grep -q 'drivers'
}

test_build_has_virtio_download() {
    grep -q 'download_virtio_iso' "$IWT_ROOT/image-pipeline/scripts/build-image.sh"
    grep -q 'virtio-win-guest-tools' "$IWT_ROOT/image-pipeline/scripts/build-image.sh"
}

# --- ARM64 pipeline tests ---

test_download_arm64_functions() {
    grep -q 'uup_find_arm64_build' "$IWT_ROOT/image-pipeline/scripts/download-iso.sh"
    grep -q 'uup_get_download_urls' "$IWT_ROOT/image-pipeline/scripts/download-iso.sh"
    grep -q 'uup_convert_to_iso' "$IWT_ROOT/image-pipeline/scripts/download-iso.sh"
    grep -q 'lang_name_to_code' "$IWT_ROOT/image-pipeline/scripts/download-iso.sh"
}

test_lang_name_to_code_mapping() {
    grep -q '"English (United States)") echo "en-us"' "$IWT_ROOT/image-pipeline/scripts/download-iso.sh"
    grep -q '"Japanese").*echo "ja-jp"' "$IWT_ROOT/image-pipeline/scripts/download-iso.sh"
    grep -q '"Chinese (Simplified)").*echo "zh-cn"' "$IWT_ROOT/image-pipeline/scripts/download-iso.sh"
}

test_download_help_mentions_arm64() {
    local output
    output=$("$IWT_ROOT/image-pipeline/scripts/download-iso.sh" --help 2>&1)
    echo "$output" | grep -q 'arm64'
}

# --- Guest setup tests ---

test_guest_setup_script_exists() {
    [[ -x "$IWT_ROOT/guest/setup-guest.sh" ]]
}

test_winfsp_setup_script_exists() {
    [[ -x "$IWT_ROOT/guest/setup-winfsp.sh" ]]
}

test_guest_setup_help() {
    local output
    output=$("$IWT_ROOT/guest/setup-guest.sh" --help 2>&1)
    echo "$output" | grep -q 'install-winfsp'
    echo "$output" | grep -q 'install-virtio'
}

test_winfsp_setup_help() {
    local output
    output=$("$IWT_ROOT/guest/setup-winfsp.sh" --help 2>&1)
    echo "$output" | grep -q 'WinFsp'
}

test_cli_vm_setup_guest_dispatch() {
    grep -q 'setup-guest)' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'guest/setup-guest' "$IWT_ROOT/cli/iwt.sh"
}

# --- WinBtrfs tests ---

test_winbtrfs_setup_script_exists() {
    [[ -x "$IWT_ROOT/guest/setup-winbtrfs.sh" ]]
}

test_winbtrfs_setup_help() {
    local output
    output=$("$IWT_ROOT/guest/setup-winbtrfs.sh" --help 2>&1)
    echo "$output" | grep -q 'WinBtrfs'
    echo "$output" | grep -q '\-\-vm'
    echo "$output" | grep -q '\-\-version'
    echo "$output" | grep -q '\-\-check'
}

test_winbtrfs_setup_has_check_function() {
    grep -q 'winbtrfs_check()' "$IWT_ROOT/guest/setup-winbtrfs.sh"
}

test_winbtrfs_setup_has_install_function() {
    grep -q 'winbtrfs_install()' "$IWT_ROOT/guest/setup-winbtrfs.sh"
}

test_winbtrfs_setup_has_url_resolver() {
    grep -q 'winbtrfs_get_download_url()' "$IWT_ROOT/guest/setup-winbtrfs.sh"
}

test_winbtrfs_setup_uses_github_api() {
    grep -q 'maharmstone/btrfs' "$IWT_ROOT/guest/setup-winbtrfs.sh"
}

test_winbtrfs_setup_has_secureboot_note() {
    grep -q 'Secure Boot' "$IWT_ROOT/guest/setup-winbtrfs.sh"
}

test_guest_setup_has_winbtrfs_flag() {
    local output
    output=$("$IWT_ROOT/guest/setup-guest.sh" --help 2>&1)
    echo "$output" | grep -q 'install-winbtrfs'
}

test_guest_setup_all_includes_winbtrfs() {
    grep -q 'INSTALL_WINBTRFS=true' "$IWT_ROOT/guest/setup-guest.sh"
}

test_guest_setup_status_checks_winbtrfs() {
    grep -q 'WinBtrfs' "$IWT_ROOT/guest/setup-guest.sh"
    grep -q 'btrfs\.sys' "$IWT_ROOT/guest/setup-guest.sh"
}

test_guest_setup_calls_winbtrfs_script() {
    grep -q 'setup-winbtrfs.sh' "$IWT_ROOT/guest/setup-guest.sh"
}

test_build_image_has_inject_winbtrfs_flag() {
    grep -q '\-\-inject-winbtrfs' "$IWT_ROOT/image-pipeline/scripts/build-image.sh"
}

test_build_image_has_inject_winbtrfs_function() {
    grep -q 'inject_winbtrfs_driver()' "$IWT_ROOT/image-pipeline/scripts/build-image.sh"
}

test_build_image_calls_inject_winbtrfs() {
    grep -q 'inject_winbtrfs_driver' "$IWT_ROOT/image-pipeline/scripts/build-image.sh"
}

test_build_image_winbtrfs_respects_env_var() {
    grep -q 'IWT_INJECT_WINBTRFS' "$IWT_ROOT/image-pipeline/scripts/build-image.sh"
}

test_manage_drivers_has_winbtrfs_subcommand() {
    local output
    output=$("$IWT_ROOT/image-pipeline/scripts/manage-drivers.sh" help 2>&1)
    echo "$output" | grep -q 'winbtrfs'
}

test_manage_drivers_winbtrfs_download_help() {
    local output
    output=$("$IWT_ROOT/image-pipeline/scripts/manage-drivers.sh" winbtrfs help 2>&1)
    echo "$output" | grep -q 'download'
    echo "$output" | grep -q 'list'
    echo "$output" | grep -q 'verify'
    echo "$output" | grep -q 'clean'
}

test_manage_drivers_winbtrfs_uses_github_api() {
    grep -q 'maharmstone/btrfs' "$IWT_ROOT/image-pipeline/scripts/manage-drivers.sh"
}

test_cli_image_help_mentions_winbtrfs() {
    local output
    output=$("$IWT_ROOT/cli/iwt.sh" image help 2>&1)
    echo "$output" | grep -q 'inject-winbtrfs'
}

# --- Btrfs storage pool tests ---

test_btrfs_pool_script_exists() {
    [[ -x "$IWT_ROOT/storage/setup-btrfs-pool.sh" ]]
}

test_btrfs_pool_script_has_shebang() {
    local first_line
    first_line=$(head -1 "$IWT_ROOT/storage/setup-btrfs-pool.sh")
    [[ "$first_line" == "#!/usr/bin/env bash" ]]
}

test_btrfs_pool_usage() {
    local output
    output=$("$IWT_ROOT/storage/setup-btrfs-pool.sh" help 2>&1)
    echo "$output" | grep -q 'create-pool'
    echo "$output" | grep -q 'attach-btrfs'
    echo "$output" | grep -q 'detach-btrfs'
    echo "$output" | grep -q 'list-pools'
    echo "$output" | grep -q 'check'
}

test_btrfs_pool_has_create_function() {
    grep -q 'cmd_create_pool()' "$IWT_ROOT/storage/setup-btrfs-pool.sh"
}

test_btrfs_pool_has_attach_function() {
    grep -q 'cmd_attach_btrfs()' "$IWT_ROOT/storage/setup-btrfs-pool.sh"
}

test_btrfs_pool_has_detach_function() {
    grep -q 'cmd_detach_btrfs()' "$IWT_ROOT/storage/setup-btrfs-pool.sh"
}

test_btrfs_pool_has_check_function() {
    grep -q 'cmd_check()' "$IWT_ROOT/storage/setup-btrfs-pool.sh"
}

test_btrfs_pool_uses_incus_storage() {
    grep -q 'incus storage' "$IWT_ROOT/storage/setup-btrfs-pool.sh"
}

test_btrfs_pool_attach_uses_incus_device() {
    grep -q 'incus config device add' "$IWT_ROOT/storage/setup-btrfs-pool.sh"
}

test_cli_vm_storage_dispatch() {
    grep -q 'storage)' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'cmd_vm_storage' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_vm_storage_help() {
    local output
    output=$("$IWT_ROOT/cli/iwt.sh" vm storage help 2>&1)
    echo "$output" | grep -q 'create-pool'
    echo "$output" | grep -q 'attach-btrfs'
    echo "$output" | grep -q 'mount-share'
}

test_cli_vm_help_mentions_storage() {
    local output
    output=$("$IWT_ROOT/cli/iwt.sh" vm help 2>&1)
    echo "$output" | grep -q 'storage'
}

# --- DwarFS tests ---

test_dwarfs_script_exists() {
    [[ -x "$IWT_ROOT/storage/setup-dwarfs.sh" ]]
}

test_dwarfs_script_has_shebang() {
    local first_line
    first_line=$(head -1 "$IWT_ROOT/storage/setup-dwarfs.sh")
    [[ "$first_line" == "#!/usr/bin/env bash" ]]
}

test_dwarfs_usage() {
    local output
    output=$("$IWT_ROOT/storage/setup-dwarfs.sh" help 2>&1)
    echo "$output" | grep -q 'pack'
    echo "$output" | grep -q 'unpack'
    echo "$output" | grep -q 'mount-share'
    echo "$output" | grep -q 'umount-share'
    echo "$output" | grep -q 'list-shares'
    echo "$output" | grep -q 'check'
}

test_dwarfs_has_pack_function() {
    grep -q 'cmd_pack()' "$IWT_ROOT/storage/setup-dwarfs.sh"
}

test_dwarfs_has_unpack_function() {
    grep -q 'cmd_unpack()' "$IWT_ROOT/storage/setup-dwarfs.sh"
}

test_dwarfs_has_mount_function() {
    grep -q 'cmd_mount_share()' "$IWT_ROOT/storage/setup-dwarfs.sh"
}

test_dwarfs_has_umount_function() {
    grep -q 'cmd_umount_share()' "$IWT_ROOT/storage/setup-dwarfs.sh"
}

test_dwarfs_has_check_function() {
    grep -q 'cmd_check()' "$IWT_ROOT/storage/setup-dwarfs.sh"
}

test_dwarfs_pack_requires_source() {
    ! "$IWT_ROOT/storage/setup-dwarfs.sh" pack 2>/dev/null
}

test_dwarfs_unpack_requires_source() {
    ! "$IWT_ROOT/storage/setup-dwarfs.sh" unpack 2>/dev/null
}

test_dwarfs_pack_uses_mkdwarfs() {
    grep -q 'mkdwarfs' "$IWT_ROOT/storage/setup-dwarfs.sh"
}

test_dwarfs_unpack_uses_dwarfsextract() {
    grep -q 'dwarfsextract' "$IWT_ROOT/storage/setup-dwarfs.sh"
}

test_dwarfs_mount_uses_fuse() {
    grep -q 'dwarfs.*FUSE\|FUSE.*dwarfs\|dwarfs "\$archive"' "$IWT_ROOT/storage/setup-dwarfs.sh"
}

test_dwarfs_mount_attaches_virtiofs() {
    grep -q 'incus config device add' "$IWT_ROOT/storage/setup-dwarfs.sh"
}

test_dwarfs_check_lists_tools() {
    grep -q 'mkdwarfs' "$IWT_ROOT/storage/setup-dwarfs.sh"
    grep -q 'dwarfsextract' "$IWT_ROOT/storage/setup-dwarfs.sh"
    grep -q 'fusermount' "$IWT_ROOT/storage/setup-dwarfs.sh"
}

test_cli_image_pack_dispatch() {
    grep -q "pack)" "$IWT_ROOT/cli/iwt.sh"
    grep -q 'setup-dwarfs.sh.*pack' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_image_unpack_dispatch() {
    grep -q "unpack)" "$IWT_ROOT/cli/iwt.sh"
    grep -q 'setup-dwarfs.sh.*unpack' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_image_help_mentions_pack() {
    local output
    output=$("$IWT_ROOT/cli/iwt.sh" image help 2>&1)
    echo "$output" | grep -q 'pack'
    echo "$output" | grep -q 'unpack'
}

test_cli_vm_storage_mount_share_dispatch() {
    grep -q 'mount-share' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'setup-dwarfs.sh' "$IWT_ROOT/cli/iwt.sh"
}

# --- lib.sh Btrfs/DwarFS helpers ---

test_lib_has_check_btrfs_host() {
    grep -q 'check_btrfs_host()' "$IWT_ROOT/cli/lib.sh"
}

test_lib_has_check_btrfs_progs() {
    grep -q 'check_btrfs_progs()' "$IWT_ROOT/cli/lib.sh"
}

test_lib_has_check_dwarfs_host() {
    grep -q 'check_dwarfs_host()' "$IWT_ROOT/cli/lib.sh"
}

test_lib_has_check_fuse_host() {
    grep -q 'check_fuse_host()' "$IWT_ROOT/cli/lib.sh"
}

test_lib_suggest_install_btrfs() {
    grep -q 'btrfs-progs' "$IWT_ROOT/cli/lib.sh"
}

test_lib_suggest_install_dwarfs() {
    grep -q 'dwarfs-tools' "$IWT_ROOT/cli/lib.sh"
}

test_lib_suggest_install_fusermount() {
    grep -q 'fusermount' "$IWT_ROOT/cli/lib.sh"
}

# --- Default config tests ---

test_config_default_has_storage_backend() {
    local tmp_config
    tmp_config=$(mktemp)
    rm "$tmp_config"
    IWT_CONFIG_FILE="$tmp_config" "$IWT_ROOT/cli/iwt.sh" config init 2>/dev/null
    grep -q 'IWT_STORAGE_BACKEND=btrfs' "$tmp_config"
    rm -f "$tmp_config"
}

test_config_default_has_image_format() {
    local tmp_config
    tmp_config=$(mktemp)
    rm "$tmp_config"
    IWT_CONFIG_FILE="$tmp_config" "$IWT_ROOT/cli/iwt.sh" config init 2>/dev/null
    grep -q 'IWT_IMAGE_FORMAT=dwarfs' "$tmp_config"
    rm -f "$tmp_config"
}

test_config_default_has_inject_winbtrfs() {
    local tmp_config
    tmp_config=$(mktemp)
    rm "$tmp_config"
    IWT_CONFIG_FILE="$tmp_config" "$IWT_ROOT/cli/iwt.sh" config init 2>/dev/null
    grep -q 'IWT_INJECT_WINBTRFS=true' "$tmp_config"
    rm -f "$tmp_config"
}

test_config_default_has_storage_pool() {
    local tmp_config
    tmp_config=$(mktemp)
    rm "$tmp_config"
    IWT_CONFIG_FILE="$tmp_config" "$IWT_ROOT/cli/iwt.sh" config init 2>/dev/null
    grep -q 'IWT_STORAGE_POOL=iwt-btrfs' "$tmp_config"
    rm -f "$tmp_config"
}

test_config_default_has_dwarfs_compress_level() {
    local tmp_config
    tmp_config=$(mktemp)
    rm "$tmp_config"
    IWT_CONFIG_FILE="$tmp_config" "$IWT_ROOT/cli/iwt.sh" config init 2>/dev/null
    grep -q 'IWT_DWARFS_COMPRESS_LEVEL' "$tmp_config"
    rm -f "$tmp_config"
}

# --- Doctor checks for Btrfs/DwarFS ---

test_doctor_checks_btrfs() {
    grep -q 'check_btrfs_host' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'check_btrfs_progs' "$IWT_ROOT/cli/iwt.sh"
}

test_doctor_checks_dwarfs() {
    grep -q 'check_dwarfs_host' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'check_fuse_host' "$IWT_ROOT/cli/iwt.sh"
}

test_doctor_output_mentions_btrfs() {
    grep -q 'Btrfs' "$IWT_ROOT/cli/iwt.sh"
}

test_doctor_output_mentions_dwarfs() {
    grep -q 'DwarFS' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_vm_help_mentions_setup_guest() {
    local output
    output=$("$IWT_ROOT/cli/iwt.sh" vm help 2>&1)
    echo "$output" | grep -q 'setup-guest'
}

test_tui_has_setup_guest() {
    grep -q 'menu_setup_guest' "$IWT_ROOT/tui/iwt-tui.sh"
    grep -q 'setup-guest' "$IWT_ROOT/tui/iwt-tui.sh"
}

# --- Template tests ---

test_template_files_exist() {
    [[ -f "$IWT_ROOT/templates/gaming.yaml" ]]
    [[ -f "$IWT_ROOT/templates/dev.yaml" ]]
    [[ -f "$IWT_ROOT/templates/server.yaml" ]]
    [[ -f "$IWT_ROOT/templates/minimal.yaml" ]]
}

test_template_engine_exists() {
    [[ -f "$IWT_ROOT/templates/engine.sh" ]]
}

test_template_engine_functions() {
    grep -q 'template_list' "$IWT_ROOT/templates/engine.sh"
    grep -q 'template_get' "$IWT_ROOT/templates/engine.sh"
    grep -q 'template_show' "$IWT_ROOT/templates/engine.sh"
    grep -q 'template_get_first_boot_scripts' "$IWT_ROOT/templates/engine.sh"
}

test_template_yaml_has_description() {
    for tpl in "$IWT_ROOT/templates"/*.yaml; do
        [[ -f "$tpl" ]] || continue
        grep -q '^description:' "$tpl" || return 1
    done
}

test_template_yaml_has_profile() {
    for tpl in "$IWT_ROOT/templates"/*.yaml; do
        [[ -f "$tpl" ]] || continue
        grep -q '^profile:' "$tpl" || return 1
    done
}

test_cli_vm_create_accepts_template() {
    grep -q '\-\-template' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_vm_template_dispatch() {
    grep -q 'template)' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'cmd_vm_template' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_vm_help_mentions_template() {
    local output
    output=$("$IWT_ROOT/cli/iwt.sh" vm help 2>&1)
    echo "$output" | grep -q 'template'
}

# --- Backup tests ---

test_backup_script_exists() {
    [[ -x "$IWT_ROOT/cli/backup.sh" ]]
}

test_backup_help() {
    local output
    output=$("$IWT_ROOT/cli/backup.sh" help 2>&1)
    echo "$output" | grep -q 'create'
    echo "$output" | grep -q 'restore'
    echo "$output" | grep -q 'export'
}

test_cli_vm_backup_dispatch() {
    grep -q 'backup)' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'backup.sh' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_vm_export_dispatch() {
    grep -q 'export)' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'cmd_export' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_vm_import_dispatch() {
    grep -q 'import)' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'cmd_import' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_vm_help_mentions_backup() {
    local output
    output=$("$IWT_ROOT/cli/iwt.sh" vm help 2>&1)
    echo "$output" | grep -q 'backup'
    echo "$output" | grep -q 'export'
    echo "$output" | grep -q 'import'
}

test_tui_has_backup_menu() {
    grep -q 'menu_backup' "$IWT_ROOT/tui/iwt-tui.sh"
}

# --- First-boot tests ---

test_first_boot_script_exists() {
    [[ -x "$IWT_ROOT/guest/first-boot.sh" ]]
}

test_first_boot_help() {
    local output
    output=$("$IWT_ROOT/guest/first-boot.sh" --help 2>&1)
    echo "$output" | grep -q 'script'
    echo "$output" | grep -q 'from-template'
}

test_cli_vm_first_boot_dispatch() {
    grep -q 'first-boot)' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'first-boot.sh' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_vm_help_mentions_first_boot() {
    local output
    output=$("$IWT_ROOT/cli/iwt.sh" vm help 2>&1)
    echo "$output" | grep -q 'first-boot'
}

test_templates_have_first_boot() {
    # At least gaming and dev templates should have first_boot sections
    grep -q 'first_boot:' "$IWT_ROOT/templates/gaming.yaml"
    grep -q 'first_boot:' "$IWT_ROOT/templates/dev.yaml"
}

# --- Makefile tests ---

test_makefile_has_install() {
    grep -q '^install:' "$IWT_ROOT/Makefile"
    grep -q '^uninstall:' "$IWT_ROOT/Makefile"
}

test_makefile_has_version() {
    grep -q 'VERSION' "$IWT_ROOT/Makefile"
}

test_man_page_source_exists() {
    [[ -f "$IWT_ROOT/doc/iwt.1.md" ]]
}

# --- Packaging tests ---

test_aur_pkgbuild_exists() {
    [[ -f "$IWT_ROOT/packaging/aur/PKGBUILD" ]]
    grep -q 'pkgname=incus-windows-toolkit' "$IWT_ROOT/packaging/aur/PKGBUILD"
}

test_deb_control_exists() {
    [[ -f "$IWT_ROOT/packaging/deb/control" ]]
}

test_rpm_spec_exists() {
    [[ -f "$IWT_ROOT/packaging/rpm/iwt.spec" ]]
}

# --- README tests ---

test_readme_has_feature_matrix() {
    grep -q 'Feature Matrix' "$IWT_ROOT/README.md"
}

test_readme_has_quick_start() {
    grep -q 'Quick Start' "$IWT_ROOT/README.md"
}

test_readme_has_architecture() {
    grep -q 'Architecture' "$IWT_ROOT/README.md"
}

# --- Monitor tests ---

test_monitor_script_exists() {
    [[ -x "$IWT_ROOT/cli/monitor.sh" ]]
}

test_monitor_help() {
    local output
    output=$("$IWT_ROOT/cli/monitor.sh" help 2>&1)
    echo "$output" | grep -q 'status'
    echo "$output" | grep -q 'stats'
    echo "$output" | grep -q 'health'
}

test_cli_vm_monitor_dispatch() {
    grep -q 'monitor)' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'monitor.sh' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_vm_help_mentions_monitor() {
    local output
    output=$("$IWT_ROOT/cli/iwt.sh" vm help 2>&1)
    echo "$output" | grep -q 'monitor'
}

# --- Fleet tests ---

test_fleet_script_exists() {
    [[ -x "$IWT_ROOT/cli/fleet.sh" ]]
}

test_fleet_help() {
    local output
    output=$("$IWT_ROOT/cli/fleet.sh" help 2>&1)
    echo "$output" | grep -q 'start-all'
    echo "$output" | grep -q 'stop-all'
    echo "$output" | grep -q 'backup-all'
}

test_cli_fleet_dispatch() {
    grep -q 'fleet)' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'fleet.sh' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_help_mentions_fleet() {
    local output
    output=$("$IWT_ROOT/cli/iwt.sh" help 2>&1)
    echo "$output" | grep -q 'fleet'
}

test_tui_has_fleet_menu() {
    grep -q 'menu_fleet' "$IWT_ROOT/tui/iwt-tui.sh"
}

test_tui_has_monitor_menu() {
    grep -q 'menu_monitor' "$IWT_ROOT/tui/iwt-tui.sh"
}

# --- Update tests ---

test_update_script_exists() {
    [[ -x "$IWT_ROOT/cli/update.sh" ]]
}

test_update_help() {
    local output
    output=$("$IWT_ROOT/cli/update.sh" help 2>&1)
    echo "$output" | grep -q 'check'
    echo "$output" | grep -q 'install'
}

test_cli_update_dispatch() {
    grep -q 'update)' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'update.sh' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_help_mentions_update() {
    local output
    output=$("$IWT_ROOT/cli/iwt.sh" help 2>&1)
    echo "$output" | grep -q 'update'
}

# --- App store tests ---

test_app_store_script_exists() {
    [[ -x "$IWT_ROOT/guest/app-store.sh" ]]
}

test_app_store_help() {
    local output
    output=$("$IWT_ROOT/guest/app-store.sh" help 2>&1)
    echo "$output" | grep -q 'install'
    echo "$output" | grep -q 'search'
}

test_app_store_list() {
    local output
    output=$("$IWT_ROOT/guest/app-store.sh" list 2>&1)
    echo "$output" | grep -q 'dev'
    echo "$output" | grep -q 'gaming'
}

test_cli_apps_dispatch() {
    grep -q 'apps)' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'app-store.sh' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_help_mentions_apps() {
    local output
    output=$("$IWT_ROOT/cli/iwt.sh" help 2>&1)
    echo "$output" | grep -q 'apps'
}

# --- Cloud sync tests ---

test_cloud_sync_script_exists() {
    [[ -x "$IWT_ROOT/cli/cloud-sync.sh" ]]
}

test_cloud_sync_help() {
    local output
    output=$("$IWT_ROOT/cli/cloud-sync.sh" help 2>&1)
    echo "$output" | grep -q 'push'
    echo "$output" | grep -q 'pull'
}

test_cli_cloud_dispatch() {
    grep -q 'cloud)' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'cloud-sync.sh' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_help_mentions_cloud() {
    local output
    output=$("$IWT_ROOT/cli/iwt.sh" help 2>&1)
    echo "$output" | grep -q 'cloud'
}

# --- Dashboard tests ---

test_dashboard_script_exists() {
    [[ -x "$IWT_ROOT/cli/web-dashboard.sh" ]]
}

test_dashboard_help() {
    local output
    output=$("$IWT_ROOT/cli/web-dashboard.sh" --help 2>&1)
    echo "$output" | grep -q 'port'
}

test_dashboard_html_output() {
    local output
    output=$("$IWT_ROOT/cli/web-dashboard.sh" --html 2>&1)
    echo "$output" | grep -q 'IWT Dashboard'
    echo "$output" | grep -q '<table>'
}

test_cli_dashboard_dispatch() {
    grep -q 'dashboard)' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'web-dashboard.sh' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_help_mentions_dashboard() {
    local output
    output=$("$IWT_ROOT/cli/iwt.sh" help 2>&1)
    echo "$output" | grep -q 'dashboard'
}

# --- Hardening tests ---

test_harden_script_exists() {
    [[ -x "$IWT_ROOT/security/harden-vm.sh" ]]
}

test_harden_help() {
    local output
    output=$("$IWT_ROOT/security/harden-vm.sh" --help 2>&1)
    echo "$output" | grep -q 'secure-boot'
    echo "$output" | grep -q 'tpm'
}

test_apparmor_profile_exists() {
    [[ -f "$IWT_ROOT/security/apparmor-iwt" ]]
}

test_cli_vm_harden_dispatch() {
    grep -q 'harden)' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'harden-vm.sh' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_vm_help_mentions_harden() {
    local output
    output=$("$IWT_ROOT/cli/iwt.sh" vm help 2>&1)
    echo "$output" | grep -q 'harden'
}

# --- Community files tests ---

test_contributing_exists() {
    [[ -f "$IWT_ROOT/CONTRIBUTING.md" ]]
}

test_issue_templates_exist() {
    [[ -f "$IWT_ROOT/.github/ISSUE_TEMPLATE/bug_report.md" ]]
    [[ -f "$IWT_ROOT/.github/ISSUE_TEMPLATE/feature_request.md" ]]
}

test_readme_has_badges() {
    grep -q 'badge.svg' "$IWT_ROOT/README.md"
}

test_changelog_exists() {
    [[ -f "$IWT_ROOT/CHANGELOG.md" ]]
}

test_license_exists() {
    [[ -f "$IWT_ROOT/LICENSE" ]]
}

# --- Lint ---

test_shellcheck() {
    find "$IWT_ROOT" -name '*.sh' -exec shellcheck -x -S warning {} +
}

# --- Integration tests (require Incus) ---

test_incus_profiles_install() {
    "$IWT_ROOT/cli/iwt.sh" profiles install
    incus profile show windows-desktop | grep -q "description:"
}

test_incus_vm_create_delete() {
    local name="iwt-test-$$"
    "$IWT_ROOT/cli/iwt.sh" vm create --name "$name"
    incus info "$name" | grep -q "Status:"
    incus delete "$name" --force
}

test_incus_snapshot_lifecycle() {
    local name="iwt-snap-test-$$"
    "$IWT_ROOT/cli/iwt.sh" vm create --name "$name"

    # Create snapshot
    IWT_VM_NAME="$name" "$IWT_ROOT/cli/iwt.sh" vm snapshot create --name test-snap

    # List snapshots
    IWT_VM_NAME="$name" "$IWT_ROOT/cli/iwt.sh" vm snapshot list | grep -q "test-snap"

    # Delete snapshot
    IWT_VM_NAME="$name" "$IWT_ROOT/cli/iwt.sh" vm snapshot delete test-snap

    # Cleanup
    incus delete "$name" --force
}

test_incus_template_create() {
    local name="iwt-tpl-test-$$"
    "$IWT_ROOT/cli/iwt.sh" vm create --template minimal --name "$name"

    # Verify template metadata was stored
    local tpl
    tpl=$(incus config get "$name" user.iwt.template 2>/dev/null || echo "")
    [[ "$tpl" == "minimal" ]]

    # Verify resource overrides applied
    local cpu
    cpu=$(incus config get "$name" limits.cpu 2>/dev/null || echo "")
    [[ "$cpu" == "2" ]]

    incus delete "$name" --force
}

test_incus_backup_restore() {
    local name="iwt-bak-test-$$"
    "$IWT_ROOT/cli/iwt.sh" vm create --name "$name"

    # Create backup
    local output
    output=$(IWT_VM_NAME="$name" "$IWT_ROOT/cli/backup.sh" create "$name" 2>&1)
    echo "$output" | grep -q "Backup created"

    # List backups
    "$IWT_ROOT/cli/backup.sh" list | grep -q "$name"

    # Cleanup VM
    incus delete "$name" --force

    # Restore from backup
    local backup_file
    backup_file=$(find "${IWT_BACKUP_DIR:-$HOME/.local/share/iwt/backups}" -name "${name}-*" -print -quit 2>/dev/null || true)
    if [[ -n "$backup_file" ]]; then
        "$IWT_ROOT/cli/backup.sh" restore "$backup_file" --name "$name"
        incus info "$name" | grep -q "Status:"
        incus delete "$name" --force
        # Clean up backup
        "$IWT_ROOT/cli/backup.sh" delete "$(basename "$backup_file")"
    fi
}

test_incus_export_import() {
    local name="iwt-exp-test-$$"
    "$IWT_ROOT/cli/iwt.sh" vm create --name "$name"

    # Export as image
    local alias="iwt-test-image-$$"
    source "$IWT_ROOT/cli/backup.sh"
    IWT_VM_NAME="$name" cmd_export "$name" --alias "$alias"

    # Verify image exists
    incus image info "$alias" | grep -q "Architecture:"

    # Cleanup
    incus delete "$name" --force
    incus image delete "$alias"
}

test_incus_monitor_health() {
    local output
    output=$("$IWT_ROOT/cli/monitor.sh" health 2>&1)
    echo "$output" | grep -q "Incus daemon"
}

test_incus_fleet_list() {
    local output
    output=$("$IWT_ROOT/cli/fleet.sh" list 2>&1)
    echo "$output" | grep -q "VMs\|No VMs"
}

# --- Runner ---

# --- Security audit test functions ---

test_security_audit_script_exists() {
    [[ -f "$IWT_ROOT/guest/setup-security-audit.sh" ]]
}

test_security_audit_is_executable() {
    [[ -x "$IWT_ROOT/guest/setup-security-audit.sh" ]]
}

test_security_audit_help() {
    local out
    out=$("$IWT_ROOT/guest/setup-security-audit.sh" --help 2>&1)
    echo "$out" | grep -q '\-\-vm'
    echo "$out" | grep -q '\-\-report'
    echo "$out" | grep -q '\-\-json'
}

test_security_audit_has_ps_payload() {
    grep -q 'AUDIT_SCRIPT=' "$IWT_ROOT/guest/setup-security-audit.sh"
}

test_security_audit_checks_defender() {
    grep -q 'Get-MpComputerStatus\|AntivirusEnabled' "$IWT_ROOT/guest/setup-security-audit.sh"
}

test_security_audit_checks_firewall() {
    grep -q 'Get-NetFirewallProfile' "$IWT_ROOT/guest/setup-security-audit.sh"
}

test_security_audit_checks_uac() {
    grep -q 'EnableLUA\|UAC' "$IWT_ROOT/guest/setup-security-audit.sh"
}

test_security_audit_checks_bitlocker() {
    grep -q 'Get-BitLockerVolume\|BitLocker' "$IWT_ROOT/guest/setup-security-audit.sh"
}

test_security_audit_checks_smbv1() {
    grep -q 'EnableSMB1Protocol\|SMBv1' "$IWT_ROOT/guest/setup-security-audit.sh"
}

test_security_audit_checks_secureboot() {
    grep -q 'Confirm-SecureBootUEFI\|SecureBoot' "$IWT_ROOT/guest/setup-security-audit.sh"
}

test_security_audit_checks_rdp() {
    grep -q 'fDenyTSConnections\|RDP' "$IWT_ROOT/guest/setup-security-audit.sh"
}

test_security_audit_checks_laps() {
    grep -q 'AdmPwdEnabled\|LAPS' "$IWT_ROOT/guest/setup-security-audit.sh"
}

test_security_audit_checks_auditpolicy() {
    grep -q 'auditpol\|AuditPolicy' "$IWT_ROOT/guest/setup-security-audit.sh"
}

test_security_audit_has_display_fn() {
    grep -q 'display_audit_results()' "$IWT_ROOT/guest/setup-security-audit.sh"
}

test_security_audit_has_json_flag() {
    grep -q '\-\-json' "$IWT_ROOT/guest/setup-security-audit.sh"
    grep -q 'JSON_OUTPUT' "$IWT_ROOT/guest/setup-security-audit.sh"
}

test_security_audit_has_report_flag() {
    grep -q '\-\-report' "$IWT_ROOT/guest/setup-security-audit.sh"
    grep -q 'REPORT_FILE' "$IWT_ROOT/guest/setup-security-audit.sh"
}

test_security_audit_has_fail_on_warn() {
    grep -q '\-\-fail-on-warn' "$IWT_ROOT/guest/setup-security-audit.sh"
    grep -q 'FAIL_ON_WARN' "$IWT_ROOT/guest/setup-security-audit.sh"
}

test_cli_vm_security_audit_dispatch() {
    grep -q 'security-audit)' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'setup-security-audit.sh' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_vm_help_mentions_security_audit() {
    local out
    out=$("$IWT_ROOT/cli/iwt.sh" vm help 2>&1)
    echo "$out" | grep -q 'security-audit'
}

# --- Secure Boot check test functions ---

test_sb_check_script_exists() {
    [[ -f "$IWT_ROOT/guest/setup-secure-boot-check.sh" ]]
}

test_sb_check_is_executable() {
    [[ -x "$IWT_ROOT/guest/setup-secure-boot-check.sh" ]]
}

test_sb_check_help() {
    local out
    out=$("$IWT_ROOT/guest/setup-secure-boot-check.sh" --help 2>&1)
    echo "$out" | grep -q '\-\-vm'
    echo "$out" | grep -q '\-\-apply-dbx-update'
    echo "$out" | grep -q '\-\-apply-2023-certs'
}

test_sb_check_has_ps_payload() {
    grep -q 'SB_AUDIT_SCRIPT=' "$IWT_ROOT/guest/setup-secure-boot-check.sh"
}

test_sb_check_checks_pk() {
    grep -q 'Get-SecureBootUEFI.*PK\|Name PK' "$IWT_ROOT/guest/setup-secure-boot-check.sh"
}

test_sb_check_checks_kek() {
    grep -q 'KEK\|Microsoft.*KEK' "$IWT_ROOT/guest/setup-secure-boot-check.sh"
}

test_sb_check_checks_db() {
    grep -q '"db"\|Name db\|MicrosoftPCA' "$IWT_ROOT/guest/setup-secure-boot-check.sh"
}

test_sb_check_checks_dbx() {
    grep -q '"dbx"\|Name dbx\|DBX' "$IWT_ROOT/guest/setup-secure-boot-check.sh"
}

test_sb_check_checks_available_updates() {
    grep -q 'AvailableUpdates' "$IWT_ROOT/guest/setup-secure-boot-check.sh"
}

test_sb_check_checks_bootmgr() {
    grep -q 'bootmgfw.efi\|BootManager' "$IWT_ROOT/guest/setup-secure-boot-check.sh"
}

test_sb_check_has_apply_dbx() {
    grep -q '\-\-apply-dbx-update' "$IWT_ROOT/guest/setup-secure-boot-check.sh"
    grep -q 'APPLY_DBX' "$IWT_ROOT/guest/setup-secure-boot-check.sh"
}

test_sb_check_has_apply_2023() {
    grep -q '\-\-apply-2023-certs' "$IWT_ROOT/guest/setup-secure-boot-check.sh"
    grep -q 'APPLY_2023' "$IWT_ROOT/guest/setup-secure-boot-check.sh"
}

test_sb_check_has_apply_revocations() {
    grep -q '\-\-apply-revocations' "$IWT_ROOT/guest/setup-secure-boot-check.sh"
    grep -q 'APPLY_REVOCATIONS' "$IWT_ROOT/guest/setup-secure-boot-check.sh"
}

test_sb_check_has_display_fn() {
    grep -q 'display_sb_results()' "$IWT_ROOT/guest/setup-secure-boot-check.sh"
}

test_sb_check_has_json_flag() {
    grep -q '\-\-json' "$IWT_ROOT/guest/setup-secure-boot-check.sh"
    grep -q 'JSON_OUTPUT' "$IWT_ROOT/guest/setup-secure-boot-check.sh"
}

test_cli_vm_secure_boot_dispatch() {
    grep -q 'secure-boot)' "$IWT_ROOT/cli/iwt.sh"
    grep -q 'setup-secure-boot-check.sh' "$IWT_ROOT/cli/iwt.sh"
}

test_cli_vm_help_mentions_secure_boot() {
    local out
    out=$("$IWT_ROOT/cli/iwt.sh" vm help 2>&1)
    echo "$out" | grep -q 'secure-boot'
}

# --- setup-guest.sh integration test functions ---

test_guest_setup_has_security_audit_flag() {
    grep -q '\-\-security-audit' "$IWT_ROOT/guest/setup-guest.sh"
    grep -q 'RUN_SECURITY_AUDIT' "$IWT_ROOT/guest/setup-guest.sh"
}

test_guest_setup_has_sb_check_flag() {
    grep -q '\-\-secure-boot-check' "$IWT_ROOT/guest/setup-guest.sh"
    grep -q 'RUN_SB_CHECK' "$IWT_ROOT/guest/setup-guest.sh"
}

test_guest_setup_all_runs_audits() {
    # --all should set both audit flags
    grep -A5 '\-\-all)' "$IWT_ROOT/guest/setup-guest.sh" | grep -q 'RUN_SECURITY_AUDIT=true'
    grep -A5 '\-\-all)' "$IWT_ROOT/guest/setup-guest.sh" | grep -q 'RUN_SB_CHECK=true'
}

test_guest_setup_calls_security_audit() {
    grep -q 'setup-security-audit.sh' "$IWT_ROOT/guest/setup-guest.sh"
}

test_guest_setup_calls_sb_check() {
    grep -q 'setup-secure-boot-check.sh' "$IWT_ROOT/guest/setup-guest.sh"
}

test_guest_setup_has_winbtrfs_status() {
    grep -q 'btrfs\.sys\|WinBtrfs' "$IWT_ROOT/guest/setup-guest.sh"
}

run_unit_tests() {
    bold "Unit Tests"
    echo ""

    run_test "CLI help"                test_cli_help
    run_test "CLI version"             test_cli_version
    run_test "CLI subcommands"         test_cli_subcommands
    run_test "CLI unknown command"     test_cli_unknown_command
    run_test "Config init"             test_config_init
    run_test "Config show"             test_config_show
    run_test "Completion bash"         test_completion_bash
    run_test "Completion zsh"          test_completion_zsh
    run_test "Profiles list"           test_profiles_list
    run_test "Profiles show"           test_profiles_show
    run_test "Profiles validate"       test_profiles_validate
    run_test "Lib detect_arch"         test_lib_detect_arch
    run_test "Lib arch_to_windows"     test_lib_arch_to_windows
    run_test "Lib arch_to_qemu"        test_lib_arch_to_qemu
    run_test "Lib human_size"          test_lib_human_size
    run_test "Build requires --iso"    test_build_image_requires_iso
    run_test "Download list versions"  test_download_list_versions
    run_test "Download list langs"     test_download_list_langs
    run_test "Download help"           test_download_help
    run_test "CLI image list"          test_cli_image_list
    run_test "CLI image download help" test_cli_image_download_help
    run_test "CLI vm snapshot help"    test_cli_vm_snapshot_help
    run_test "CLI vm help has snapshot" test_cli_vm_help_mentions_snapshot
    run_test "Backend snapshot funcs"  test_backend_snapshot_functions_exist
    run_test "CLI vm share help"       test_cli_vm_share_help
    run_test "CLI vm help has share"   test_cli_vm_help_mentions_share
    run_test "Backend share funcs"     test_backend_share_functions_exist
    run_test "shares.conf exists"      test_shares_conf_exists
    run_test "CLI vm gpu help"         test_cli_vm_gpu_help
    run_test "CLI vm help has gpu"     test_cli_vm_help_mentions_gpu
    run_test "Backend gpu funcs"       test_backend_gpu_functions_exist
    run_test "GPU profiles validate"   test_gpu_profiles_validate
    run_test "GPU setup scripts exist" test_gpu_setup_scripts_exist
    run_test "CLI vm usb help"         test_cli_vm_usb_help
    run_test "CLI vm help has usb"     test_cli_vm_help_mentions_usb
    run_test "Backend usb funcs"       test_backend_usb_functions_exist
    run_test "CLI vm net help"         test_cli_vm_net_help
    run_test "CLI vm help has net"     test_cli_vm_help_mentions_net
    run_test "Backend net funcs"       test_backend_net_functions_exist
    run_test "apps.conf format"        test_apps_conf_format
    run_test "TUI script exists"       test_tui_script_exists
    run_test "TUI script executable"   test_tui_script_executable
    run_test "TUI has shebang"         test_tui_has_shebang
    run_test "TUI has main menu"       test_tui_has_main_menu
    run_test "TUI has dialog detect"   test_tui_has_dialog_detection
    run_test "CLI help mentions tui"   test_cli_help_mentions_tui
    run_test "CLI tui dispatch exists" test_cli_tui_dispatch_exists
    run_test "Driver mgmt script"      test_manage_drivers_script_exists
    run_test "Driver mgmt help"        test_manage_drivers_help
    run_test "CLI image drivers"       test_cli_image_drivers_dispatch
    run_test "CLI image help drivers"  test_cli_image_help_mentions_drivers
    run_test "Build has VirtIO dl"     test_build_has_virtio_download
    run_test "ARM64 download funcs"    test_download_arm64_functions
    run_test "ARM64 lang mapping"      test_lang_name_to_code_mapping
    run_test "Download help arm64"     test_download_help_mentions_arm64
    run_test "Guest setup script"      test_guest_setup_script_exists
    run_test "WinFsp setup script"     test_winfsp_setup_script_exists
    run_test "Guest setup help"        test_guest_setup_help
    run_test "WinFsp setup help"       test_winfsp_setup_help
    run_test "CLI vm setup-guest"      test_cli_vm_setup_guest_dispatch
    run_test "CLI vm help setup"       test_cli_vm_help_mentions_setup_guest
    run_test "TUI has setup-guest"     test_tui_has_setup_guest
    run_test "Template files exist"    test_template_files_exist
    run_test "Template engine exists"  test_template_engine_exists
    run_test "Template engine funcs"   test_template_engine_functions
    run_test "Templates have desc"     test_template_yaml_has_description
    run_test "Templates have profile"  test_template_yaml_has_profile
    run_test "CLI create --template"   test_cli_vm_create_accepts_template
    run_test "CLI vm template cmd"     test_cli_vm_template_dispatch
    run_test "CLI vm help template"    test_cli_vm_help_mentions_template
    run_test "Backup script exists"    test_backup_script_exists
    run_test "Backup help"             test_backup_help
    run_test "CLI vm backup dispatch"  test_cli_vm_backup_dispatch
    run_test "CLI vm export dispatch"  test_cli_vm_export_dispatch
    run_test "CLI vm import dispatch"  test_cli_vm_import_dispatch
    run_test "CLI vm help backup"      test_cli_vm_help_mentions_backup
    run_test "TUI has backup menu"     test_tui_has_backup_menu
    run_test "First-boot script"       test_first_boot_script_exists
    run_test "First-boot help"         test_first_boot_help
    run_test "CLI vm first-boot"       test_cli_vm_first_boot_dispatch
    run_test "CLI vm help first-boot"  test_cli_vm_help_mentions_first_boot
    run_test "Templates have hooks"    test_templates_have_first_boot
    run_test "Makefile install"        test_makefile_has_install
    run_test "Makefile version"        test_makefile_has_version
    run_test "Man page source"         test_man_page_source_exists
    run_test "AUR PKGBUILD"            test_aur_pkgbuild_exists
    run_test "Deb control"             test_deb_control_exists
    run_test "RPM spec"                test_rpm_spec_exists
    run_test "README feature matrix"   test_readme_has_feature_matrix
    run_test "README quick start"      test_readme_has_quick_start
    run_test "README architecture"     test_readme_has_architecture
    run_test "Monitor script"          test_monitor_script_exists
    run_test "Monitor help"            test_monitor_help
    run_test "CLI vm monitor"          test_cli_vm_monitor_dispatch
    run_test "CLI vm help monitor"     test_cli_vm_help_mentions_monitor
    run_test "Fleet script"            test_fleet_script_exists
    run_test "Fleet help"              test_fleet_help
    run_test "CLI fleet dispatch"      test_cli_fleet_dispatch
    run_test "CLI help fleet"          test_cli_help_mentions_fleet
    run_test "TUI has fleet"           test_tui_has_fleet_menu
    run_test "TUI has monitor"         test_tui_has_monitor_menu
    run_test "Update script"           test_update_script_exists
    run_test "Update help"             test_update_help
    run_test "CLI update dispatch"     test_cli_update_dispatch
    run_test "CLI help update"         test_cli_help_mentions_update
    run_test "App store script"        test_app_store_script_exists
    run_test "App store help"          test_app_store_help
    run_test "App store list"          test_app_store_list
    run_test "CLI apps dispatch"       test_cli_apps_dispatch
    run_test "CLI help apps"           test_cli_help_mentions_apps
    run_test "Cloud sync script"       test_cloud_sync_script_exists
    run_test "Cloud sync help"         test_cloud_sync_help
    run_test "CLI cloud dispatch"      test_cli_cloud_dispatch
    run_test "CLI help cloud"          test_cli_help_mentions_cloud
    run_test "Dashboard script"        test_dashboard_script_exists
    run_test "Dashboard help"          test_dashboard_help
    run_test "Dashboard HTML"          test_dashboard_html_output
    run_test "CLI dashboard dispatch"  test_cli_dashboard_dispatch
    run_test "CLI help dashboard"      test_cli_help_mentions_dashboard
    run_test "Harden script"           test_harden_script_exists
    run_test "Harden help"             test_harden_help
    run_test "AppArmor profile"        test_apparmor_profile_exists
    run_test "CLI vm harden"           test_cli_vm_harden_dispatch
    run_test "CLI vm help harden"      test_cli_vm_help_mentions_harden
    run_test "CONTRIBUTING.md"         test_contributing_exists
    run_test "Issue templates"         test_issue_templates_exist
    run_test "README badges"           test_readme_has_badges
    run_test "CHANGELOG exists"        test_changelog_exists
    run_test "LICENSE exists"          test_license_exists

    # --- WinBtrfs ---
    run_test "WinBtrfs setup script"           test_winbtrfs_setup_script_exists
    run_test "WinBtrfs setup help"             test_winbtrfs_setup_help
    run_test "WinBtrfs check function"         test_winbtrfs_setup_has_check_function
    run_test "WinBtrfs install function"       test_winbtrfs_setup_has_install_function
    run_test "WinBtrfs URL resolver"           test_winbtrfs_setup_has_url_resolver
    run_test "WinBtrfs uses GitHub API"        test_winbtrfs_setup_uses_github_api
    run_test "WinBtrfs Secure Boot note"       test_winbtrfs_setup_has_secureboot_note
    run_test "Guest setup --install-winbtrfs"  test_guest_setup_has_winbtrfs_flag
    run_test "Guest setup --all has winbtrfs"  test_guest_setup_all_includes_winbtrfs
    run_test "Guest setup checks winbtrfs"     test_guest_setup_status_checks_winbtrfs
    run_test "Guest setup calls winbtrfs"      test_guest_setup_calls_winbtrfs_script
    run_test "Build --inject-winbtrfs flag"    test_build_image_has_inject_winbtrfs_flag
    run_test "Build inject_winbtrfs_driver()"  test_build_image_has_inject_winbtrfs_function
    run_test "Build calls inject_winbtrfs"     test_build_image_calls_inject_winbtrfs
    run_test "Build respects IWT_INJECT_WINBTRFS" test_build_image_winbtrfs_respects_env_var
    run_test "Drivers winbtrfs subcommand"     test_manage_drivers_has_winbtrfs_subcommand
    run_test "Drivers winbtrfs help"           test_manage_drivers_winbtrfs_download_help
    run_test "Drivers winbtrfs GitHub API"     test_manage_drivers_winbtrfs_uses_github_api
    run_test "CLI image help --inject-winbtrfs" test_cli_image_help_mentions_winbtrfs

    # --- Btrfs storage pool ---
    run_test "Btrfs pool script exists"        test_btrfs_pool_script_exists
    run_test "Btrfs pool script shebang"       test_btrfs_pool_script_has_shebang
    run_test "Btrfs pool usage"                test_btrfs_pool_usage
    run_test "Btrfs pool create function"      test_btrfs_pool_has_create_function
    run_test "Btrfs pool attach function"      test_btrfs_pool_has_attach_function
    run_test "Btrfs pool detach function"      test_btrfs_pool_has_detach_function
    run_test "Btrfs pool check function"       test_btrfs_pool_has_check_function
    run_test "Btrfs pool uses incus storage"   test_btrfs_pool_uses_incus_storage
    run_test "Btrfs attach uses incus device"  test_btrfs_pool_attach_uses_incus_device
    run_test "CLI vm storage dispatch"         test_cli_vm_storage_dispatch
    run_test "CLI vm storage help"             test_cli_vm_storage_help
    run_test "CLI vm help has storage"         test_cli_vm_help_mentions_storage

    # --- DwarFS ---
    run_test "DwarFS script exists"            test_dwarfs_script_exists
    run_test "DwarFS script shebang"           test_dwarfs_script_has_shebang
    run_test "DwarFS usage"                    test_dwarfs_usage
    run_test "DwarFS pack function"            test_dwarfs_has_pack_function
    run_test "DwarFS unpack function"          test_dwarfs_has_unpack_function
    run_test "DwarFS mount function"           test_dwarfs_has_mount_function
    run_test "DwarFS umount function"          test_dwarfs_has_umount_function
    run_test "DwarFS check function"           test_dwarfs_has_check_function
    run_test "DwarFS pack requires --source"   test_dwarfs_pack_requires_source
    run_test "DwarFS unpack requires --source" test_dwarfs_unpack_requires_source
    run_test "DwarFS pack uses mkdwarfs"       test_dwarfs_pack_uses_mkdwarfs
    run_test "DwarFS unpack uses dwarfsextract" test_dwarfs_unpack_uses_dwarfsextract
    run_test "DwarFS mount uses FUSE"          test_dwarfs_mount_uses_fuse
    run_test "DwarFS mount attaches virtiofs"  test_dwarfs_mount_attaches_virtiofs
    run_test "DwarFS check lists tools"        test_dwarfs_check_lists_tools
    run_test "CLI image pack dispatch"         test_cli_image_pack_dispatch
    run_test "CLI image unpack dispatch"       test_cli_image_unpack_dispatch
    run_test "CLI image help pack/unpack"      test_cli_image_help_mentions_pack
    run_test "CLI vm storage mount-share"      test_cli_vm_storage_mount_share_dispatch

    # --- lib.sh helpers ---
    run_test "lib check_btrfs_host"            test_lib_has_check_btrfs_host
    run_test "lib check_btrfs_progs"           test_lib_has_check_btrfs_progs
    run_test "lib check_dwarfs_host"           test_lib_has_check_dwarfs_host
    run_test "lib check_fuse_host"             test_lib_has_check_fuse_host
    run_test "lib suggest btrfs-progs"         test_lib_suggest_install_btrfs
    run_test "lib suggest dwarfs-tools"        test_lib_suggest_install_dwarfs
    run_test "lib suggest fusermount"          test_lib_suggest_install_fusermount

    # --- Default config ---
    run_test "Config default storage backend"  test_config_default_has_storage_backend
    run_test "Config default image format"     test_config_default_has_image_format
    run_test "Config default inject winbtrfs"  test_config_default_has_inject_winbtrfs
    run_test "Config default storage pool"     test_config_default_has_storage_pool
    run_test "Config default dwarfs level"     test_config_default_has_dwarfs_compress_level

    # --- Doctor ---
    run_test "Doctor checks btrfs"             test_doctor_checks_btrfs
    run_test "Doctor checks dwarfs"            test_doctor_checks_dwarfs
    run_test "Doctor mentions Btrfs"           test_doctor_output_mentions_btrfs
    run_test "Doctor mentions DwarFS"          test_doctor_output_mentions_dwarfs

    # --- Security audit ---
    run_test "Security audit script exists"          test_security_audit_script_exists
    run_test "Security audit is executable"          test_security_audit_is_executable
    run_test "Security audit help"                   test_security_audit_help
    run_test "Security audit has audit script var"   test_security_audit_has_ps_payload
    run_test "Security audit checks Defender"        test_security_audit_checks_defender
    run_test "Security audit checks Firewall"        test_security_audit_checks_firewall
    run_test "Security audit checks UAC"             test_security_audit_checks_uac
    run_test "Security audit checks BitLocker"       test_security_audit_checks_bitlocker
    run_test "Security audit checks SMBv1"           test_security_audit_checks_smbv1
    run_test "Security audit checks Secure Boot"     test_security_audit_checks_secureboot
    run_test "Security audit checks RDP"             test_security_audit_checks_rdp
    run_test "Security audit checks LAPS"            test_security_audit_checks_laps
    run_test "Security audit checks audit policy"    test_security_audit_checks_auditpolicy
    run_test "Security audit has display function"   test_security_audit_has_display_fn
    run_test "Security audit has --json flag"        test_security_audit_has_json_flag
    run_test "Security audit has --report flag"      test_security_audit_has_report_flag
    run_test "Security audit has --fail-on-warn"     test_security_audit_has_fail_on_warn
    run_test "CLI vm security-audit dispatch"        test_cli_vm_security_audit_dispatch
    run_test "CLI vm help security-audit"            test_cli_vm_help_mentions_security_audit

    # --- Secure Boot check ---
    run_test "Secure Boot check script exists"       test_sb_check_script_exists
    run_test "Secure Boot check is executable"       test_sb_check_is_executable
    run_test "Secure Boot check help"                test_sb_check_help
    run_test "Secure Boot check has PS payload"      test_sb_check_has_ps_payload
    run_test "Secure Boot check checks PK"           test_sb_check_checks_pk
    run_test "Secure Boot check checks KEK"          test_sb_check_checks_kek
    run_test "Secure Boot check checks DB"           test_sb_check_checks_db
    run_test "Secure Boot check checks DBX"          test_sb_check_checks_dbx
    run_test "Secure Boot check checks AvailableUpdates" test_sb_check_checks_available_updates
    run_test "Secure Boot check checks boot manager" test_sb_check_checks_bootmgr
    run_test "Secure Boot check has apply-dbx flag"  test_sb_check_has_apply_dbx
    run_test "Secure Boot check has apply-2023 flag" test_sb_check_has_apply_2023
    run_test "Secure Boot check has apply-revoke"    test_sb_check_has_apply_revocations
    run_test "Secure Boot check has display function" test_sb_check_has_display_fn
    run_test "Secure Boot check has --json flag"     test_sb_check_has_json_flag
    run_test "CLI vm secure-boot dispatch"           test_cli_vm_secure_boot_dispatch
    run_test "CLI vm help secure-boot"               test_cli_vm_help_mentions_secure_boot

    # --- setup-guest.sh integration ---
    run_test "Guest setup --security-audit flag"     test_guest_setup_has_security_audit_flag
    run_test "Guest setup --secure-boot-check flag"  test_guest_setup_has_sb_check_flag
    run_test "Guest setup --all runs audits"         test_guest_setup_all_runs_audits
    run_test "Guest setup calls security-audit"      test_guest_setup_calls_security_audit
    run_test "Guest setup calls secure-boot-check"   test_guest_setup_calls_sb_check
    run_test "Guest setup has WinBtrfs status check" test_guest_setup_has_winbtrfs_status
}

run_lint() {
    bold "Lint"
    echo ""
    run_test "shellcheck" test_shellcheck
}

run_integration_tests() {
    bold "Integration Tests"
    echo ""

    if ! command -v incus &>/dev/null; then
        skip_test "Incus profiles install" "incus not found"
        skip_test "Incus VM create/delete" "incus not found"
        return
    fi

    if ! incus info &>/dev/null 2>&1; then
        skip_test "Incus profiles install" "incusd not reachable"
        skip_test "Incus VM create/delete" "incusd not reachable"
        return
    fi

    run_test "Incus profiles install"  test_incus_profiles_install
    run_test "Incus VM create/delete"  test_incus_vm_create_delete
    run_test "Incus snapshot lifecycle" test_incus_snapshot_lifecycle
    run_test "Incus template create"   test_incus_template_create
    run_test "Incus backup/restore"    test_incus_backup_restore
    run_test "Incus export/import"     test_incus_export_import
    run_test "Incus monitor health"    test_incus_monitor_health
    run_test "Incus fleet list"        test_incus_fleet_list
}

# --- Main ---

main() {
    local mode="${1:-unit}"

    echo ""
    bold "IWT Test Suite"
    echo ""

    case "$mode" in
        --lint)
            run_lint
            ;;
        --all)
            run_unit_tests
            echo ""
            run_lint
            echo ""
            run_integration_tests
            ;;
        *)
            run_unit_tests
            echo ""
            run_lint
            ;;
    esac

    echo ""
    bold "Results: $PASSED passed, $FAILED failed, $SKIPPED skipped"

    [[ $FAILED -eq 0 ]]
}

main "$@"

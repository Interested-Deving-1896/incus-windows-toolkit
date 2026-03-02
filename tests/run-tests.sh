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
    "$IWT_ROOT/cli/iwt.sh" image list | grep -q "Consumer"
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

# --- Runner ---

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

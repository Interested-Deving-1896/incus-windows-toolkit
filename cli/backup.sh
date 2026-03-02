#!/usr/bin/env bash
# Backup, export, and import Windows VMs.
#
# Supports:
#   - Full VM backup (config + disk) as compressed tarball
#   - Export as Incus image for reuse
#   - Import from backup or image
#
# Usage:
#   backup.sh <subcommand> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
source "$IWT_ROOT/remoteapp/backend/incus-backend.sh"
load_config

BACKUP_DIR="${IWT_BACKUP_DIR:-$HOME/.local/share/iwt/backups}"

# --- Backup ---

cmd_backup_create() {
    local vm_name=""
    local output=""
    local include_snapshots=true
    local compress=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vm)              vm_name="$2"; shift 2 ;;
            --output|-o)       output="$2"; shift 2 ;;
            --no-snapshots)    include_snapshots=false; shift ;;
            --no-compress)     compress=false; shift ;;
            --help|-h)         backup_usage; exit 0 ;;
            -*)                die "Unknown option: $1" ;;
            *)                 vm_name="$1"; shift ;;
        esac
    done

    vm_name="${vm_name:-$IWT_VM_NAME}"
    [[ -n "$vm_name" ]] || die "VM name required. Usage: iwt vm backup create <name>"

    # Verify VM exists
    incus info "$vm_name" &>/dev/null || die "VM '$vm_name' not found"

    # Generate output path
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    if [[ -z "$output" ]]; then
        mkdir -p "$BACKUP_DIR"
        output="$BACKUP_DIR/${vm_name}-${timestamp}.tar"
        if [[ "$compress" == true ]]; then
            output="${output}.gz"
        fi
    fi

    # Stop VM if running (Incus requires stopped VM for backup)
    local was_running=false
    if vm_is_running; then
        was_running=true
        info "Stopping VM for backup..."
        vm_stop
        # Wait for clean shutdown
        local wait=0
        while vm_is_running && [[ $wait -lt 30 ]]; do
            sleep 1
            wait=$((wait + 1))
        done
    fi

    info "Creating backup: $vm_name -> $(basename "$output")"

    # Export VM using Incus
    local export_args=("$vm_name" "$output")
    if [[ "$include_snapshots" == false ]]; then
        export_args+=("--instance-only")
    fi
    if [[ "$compress" == false ]]; then
        export_args+=("--compression=none")
    fi

    incus export "${export_args[@]}" || die "Backup failed"

    # Save IWT metadata alongside the backup
    local meta_file="${output%.tar*}.meta"
    cat > "$meta_file" <<EOF
# IWT Backup Metadata
vm_name=$vm_name
timestamp=$timestamp
include_snapshots=$include_snapshots
iwt_version=$(grep '^VERSION=' "$IWT_ROOT/cli/iwt.sh" | cut -d'"' -f2)
template=$(incus config get "$vm_name" user.iwt.template 2>/dev/null || echo "")
EOF

    local size
    size=$(stat -c%s "$output" 2>/dev/null || stat -f%z "$output" 2>/dev/null || echo "0")
    ok "Backup created: $output ($(human_size "$size"))"

    # Restart VM if it was running
    if [[ "$was_running" == true ]]; then
        info "Restarting VM..."
        vm_start
    fi
}

cmd_backup_restore() {
    local backup_path=""
    local vm_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)      vm_name="$2"; shift 2 ;;
            --help|-h)   backup_usage; exit 0 ;;
            -*)          die "Unknown option: $1" ;;
            *)           backup_path="$1"; shift ;;
        esac
    done

    [[ -n "$backup_path" ]] || die "Backup path required. Usage: iwt vm backup restore <path> [--name NAME]"
    [[ -f "$backup_path" ]] || die "Backup file not found: $backup_path"

    # Read metadata if available
    local meta_file="${backup_path%.tar*}.meta"
    if [[ -f "$meta_file" && -z "$vm_name" ]]; then
        vm_name=$(grep '^vm_name=' "$meta_file" | cut -d= -f2)
    fi

    [[ -n "$vm_name" ]] || die "VM name required. Use --name or ensure .meta file exists."

    # Check if VM already exists
    if incus info "$vm_name" &>/dev/null; then
        die "VM '$vm_name' already exists. Delete it first: incus delete $vm_name --force"
    fi

    info "Restoring backup: $(basename "$backup_path") -> $vm_name"
    incus import "$backup_path" "$vm_name" || die "Restore failed"

    ok "VM '$vm_name' restored from backup"
    info "Start with: iwt vm start $vm_name"
}

# --- Export as Incus image ---

cmd_export() {
    local vm_name=""
    local alias=""
    local output=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vm)         vm_name="$2"; shift 2 ;;
            --alias|-a)   alias="$2"; shift 2 ;;
            --output|-o)  output="$2"; shift 2 ;;
            --help|-h)    backup_usage; exit 0 ;;
            -*)           die "Unknown option: $1" ;;
            *)            vm_name="$1"; shift ;;
        esac
    done

    vm_name="${vm_name:-$IWT_VM_NAME}"
    [[ -n "$vm_name" ]] || die "VM name required. Usage: iwt vm export <name> [--alias ALIAS]"

    incus info "$vm_name" &>/dev/null || die "VM '$vm_name' not found"

    if [[ -z "$alias" ]]; then
        alias="iwt-${vm_name}"
    fi

    # Stop VM if running
    local was_running=false
    if vm_is_running; then
        was_running=true
        info "Stopping VM for export..."
        vm_stop
        local wait=0
        while vm_is_running && [[ $wait -lt 30 ]]; do
            sleep 1
            wait=$((wait + 1))
        done
    fi

    info "Publishing VM as image: $alias"
    incus publish "$vm_name" --alias "$alias" || die "Export failed"
    ok "VM published as image: $alias"

    # Optionally export to file
    if [[ -n "$output" ]]; then
        info "Exporting image to file: $output"
        incus image export "$alias" "$output" || die "Image file export failed"
        local size
        size=$(stat -c%s "${output}"* 2>/dev/null | head -1 || echo "0")
        ok "Image exported: $output ($(human_size "$size"))"
    fi

    # Restart VM if it was running
    if [[ "$was_running" == true ]]; then
        info "Restarting VM..."
        vm_start
    fi

    info "Create new VMs from this image: incus init $alias <new-name> --vm"
}

# --- Import ---

cmd_import() {
    local source_path=""
    local vm_name=""
    local alias=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)      vm_name="$2"; shift 2 ;;
            --alias|-a)  alias="$2"; shift 2 ;;
            --help|-h)   backup_usage; exit 0 ;;
            -*)          die "Unknown option: $1" ;;
            *)           source_path="$1"; shift ;;
        esac
    done

    [[ -n "$source_path" ]] || die "Source path required. Usage: iwt vm import <path> [--name NAME]"
    [[ -f "$source_path" ]] || die "File not found: $source_path"

    # Detect if this is a backup tarball or an image
    local file_type
    file_type=$(file -b "$source_path" 2>/dev/null || echo "unknown")

    if echo "$file_type" | grep -qi "gzip\|tar"; then
        # Try as backup first
        if [[ -n "$vm_name" ]]; then
            info "Importing backup as VM: $vm_name"
            incus import "$source_path" "$vm_name" && {
                ok "VM '$vm_name' imported"
                return 0
            }
        fi

        # Try as image
        local img_alias="${alias:-iwt-imported-$(date +%s)}"
        info "Importing as image: $img_alias"
        incus image import "$source_path" --alias "$img_alias" || die "Import failed"
        ok "Image imported: $img_alias"

        if [[ -n "$vm_name" ]]; then
            info "Creating VM from image..."
            incus init "$img_alias" "$vm_name" --vm || die "VM creation failed"
            ok "VM '$vm_name' created from imported image"
        else
            info "Create a VM with: incus init $img_alias <name> --vm"
        fi
    else
        die "Unrecognized file format. Expected a backup tarball or Incus image."
    fi
}

# --- List backups ---

cmd_backup_list() {
    mkdir -p "$BACKUP_DIR"

    bold "VM Backups:"
    echo ""
    printf "  %-35s %-12s %s\n" "FILENAME" "SIZE" "DATE"
    printf "  %-35s %-12s %s\n" "--------" "----" "----"

    local found=false
    for f in "$BACKUP_DIR"/*.tar.gz "$BACKUP_DIR"/*.tar; do
        [[ -f "$f" ]] || continue
        found=true
        local size date_str
        size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo "0")
        date_str=$(stat -c%y "$f" 2>/dev/null | cut -d. -f1 || stat -f%Sm "$f" 2>/dev/null || echo "unknown")
        printf "  %-35s %-12s %s\n" "$(basename "$f")" "$(human_size "$size")" "$date_str"
    done

    if [[ "$found" == false ]]; then
        info "  No backups found in $BACKUP_DIR"
    fi

    echo ""
    info "Backup directory: $BACKUP_DIR"
}

# --- Delete backup ---

cmd_backup_delete() {
    local backup_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) backup_usage; exit 0 ;;
            -*)        die "Unknown option: $1" ;;
            *)         backup_name="$1"; shift ;;
        esac
    done

    [[ -n "$backup_name" ]] || die "Backup name required. Usage: iwt vm backup delete <name>"

    local backup_path="$BACKUP_DIR/$backup_name"
    # Try with common extensions
    if [[ ! -f "$backup_path" ]]; then
        for ext in .tar.gz .tar; do
            if [[ -f "$BACKUP_DIR/${backup_name}${ext}" ]]; then
                backup_path="$BACKUP_DIR/${backup_name}${ext}"
                break
            fi
        done
    fi

    [[ -f "$backup_path" ]] || die "Backup not found: $backup_name"

    local meta_file="${backup_path%.tar*}.meta"

    info "Deleting: $(basename "$backup_path")"
    rm -f "$backup_path"
    rm -f "$meta_file"
    ok "Backup deleted"
}

# --- Help ---

backup_usage() {
    cat <<EOF
iwt vm backup - Backup and restore Windows VMs
iwt vm export  - Export VM as reusable Incus image
iwt vm import  - Import VM from backup or image

Backup subcommands:
  create [name]       Create a backup of a VM
  restore <path>      Restore a VM from backup
  list                List available backups
  delete <name>       Delete a backup

Export/Import:
  export [name]       Publish VM as Incus image
  import <path>       Import from backup tarball or image file

Backup options:
  --vm NAME           Target VM (default: \$IWT_VM_NAME)
  --output PATH       Output file path
  --no-snapshots      Exclude snapshots from backup
  --no-compress       Don't compress the backup

Export options:
  --alias NAME        Image alias (default: iwt-<vm-name>)
  --output PATH       Also export image to file

Import options:
  --name NAME         VM name for the imported instance
  --alias NAME        Image alias for imported image

Examples:
  iwt vm backup create win11
  iwt vm backup list
  iwt vm backup restore ~/.local/share/iwt/backups/win11-20240101-120000.tar.gz
  iwt vm backup delete win11-20240101-120000

  iwt vm export win11 --alias my-windows-base
  iwt vm import ./windows-base.tar.gz --name win11-clone

Backup directory: \$HOME/.local/share/iwt/backups
Override with: IWT_BACKUP_DIR=/path/to/backups
EOF
}

# --- Main ---

main() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        create)       cmd_backup_create "$@" ;;
        restore)      cmd_backup_restore "$@" ;;
        list|ls)      cmd_backup_list ;;
        delete|rm)    cmd_backup_delete "$@" ;;
        help|--help|-h) backup_usage ;;
        *)
            err "Unknown backup subcommand: $subcmd"
            backup_usage
            exit 1
            ;;
    esac
}

main "$@"

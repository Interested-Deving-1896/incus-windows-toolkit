#!/usr/bin/env bash
# bdfs (btrfs-dwarfs-framework) integration for IWT.
#
# Wraps the bdfs CLI and bdfs_daemon to expose the BTRFS+DwarFS hybrid
# namespace to IWT workflows:
#
#   - partition   Register/remove/list bdfs partitions
#   - blend       Mount/unmount the unified BTRFS+DwarFS namespace
#   - export      Export a BTRFS subvolume to a compressed DwarFS image
#   - import      Import a DwarFS image back into a BTRFS subvolume
#   - snapshot    CoW snapshot of a DwarFS image's BTRFS container
#   - promote     Make a DwarFS-backed path writable (extract to BTRFS)
#   - demote      Compress a BTRFS subvolume into a DwarFS image
#   - status      Show bdfs partition and blend status
#   - daemon      Start/stop/status the bdfs_daemon
#   - check       Verify host prerequisites
#   - help        Show this help
#
# Requires btrfs-dwarfs-framework to be built and installed:
#   https://github.com/Interested-Deving-1896/btrfs-dwarfs-framework
#
# Usage:
#   setup-bdfs.sh <subcommand> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$IWT_ROOT/cli/lib.sh"
load_config

# --- Subcommands ---

cmd_partition() {
    local subcmd="${1:-help}"
    shift || true

    _require_bdfs

    case "$subcmd" in
        add)
            local type="" device="" label="" mount=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --type)    type="$2";   shift 2 ;;
                    --device)  device="$2"; shift 2 ;;
                    --label)   label="$2";  shift 2 ;;
                    --mount)   mount="$2";  shift 2 ;;
                    --help|-h) _usage_partition_add; exit 0 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [[ -n "$type"   ]] || die "--type is required (dwarfs-backed | btrfs-backed)"
            [[ -n "$device" ]] || die "--device is required"
            [[ -n "$label"  ]] || die "--label is required"
            [[ -n "$mount"  ]] || die "--mount is required"

            echo ""
            bold "bdfs partition add"
            info "Type:   $type"
            info "Device: $device"
            info "Label:  $label"
            info "Mount:  $mount"
            echo ""

            bdfs partition add \
                --type   "$type"   \
                --device "$device" \
                --label  "$label"  \
                --mount  "$mount"

            ok "Partition '$label' registered"
            ;;

        remove)
            local uuid="${1:?Usage: iwt vm storage bdfs-partition remove <uuid>}"
            bdfs partition remove --uuid "$uuid"
            ok "Partition $uuid removed"
            ;;

        list)
            bdfs partition list
            ;;

        show)
            local uuid="${1:?Usage: iwt vm storage bdfs-partition show <uuid>}"
            bdfs partition show --uuid "$uuid"
            ;;

        help|--help|-h)
            _usage_partition_add
            ;;

        *)
            die "Unknown partition subcommand: $subcmd"
            ;;
    esac
}

_usage_partition_add() {
    cat <<EOF
iwt vm storage bdfs-partition add - Register a bdfs partition

Options:
  --type    TYPE    dwarfs-backed | btrfs-backed  (required)
  --device  PATH    Block device, e.g. /dev/sdb1  (required)
  --label   NAME    Human-readable label           (required)
  --mount   PATH    Mount point                    (required)

Examples:
  iwt vm storage bdfs-partition add \\
      --type dwarfs-backed --device /dev/sdb1 --label archive --mount /mnt/archive

  iwt vm storage bdfs-partition add \\
      --type btrfs-backed --device /dev/sdc1 --label images --mount /mnt/images
EOF
}

cmd_blend() {
    local subcmd="${1:-help}"
    shift || true

    _require_bdfs

    case "$subcmd" in
        mount)
            local btrfs_uuid="" dwarfs_uuid="" mountpoint="" writeback=false
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --btrfs-uuid)   btrfs_uuid="$2";  shift 2 ;;
                    --dwarfs-uuid)  dwarfs_uuid="$2"; shift 2 ;;
                    --mountpoint)   mountpoint="$2";  shift 2 ;;
                    --writeback)    writeback=true;   shift   ;;
                    --help|-h)      _usage_blend; exit 0 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [[ -n "$btrfs_uuid"  ]] || die "--btrfs-uuid is required"
            [[ -n "$dwarfs_uuid" ]] || die "--dwarfs-uuid is required"
            [[ -n "$mountpoint"  ]] || die "--mountpoint is required"

            echo ""
            bold "bdfs blend mount"
            info "BTRFS partition:  $btrfs_uuid"
            info "DwarFS partition: $dwarfs_uuid"
            info "Mountpoint:       $mountpoint"
            info "Writeback:        $writeback"
            echo ""

            local args=(--btrfs-uuid "$btrfs_uuid" --dwarfs-uuid "$dwarfs_uuid" --mountpoint "$mountpoint")
            [[ "$writeback" == true ]] && args+=(--writeback)

            bdfs blend mount "${args[@]}"
            ok "Blend namespace mounted at $mountpoint"
            ;;

        umount)
            local mountpoint="${1:?Usage: iwt vm storage bdfs-blend umount <mountpoint>}"
            bdfs blend umount --mountpoint "$mountpoint"
            ok "Blend namespace unmounted: $mountpoint"
            ;;

        help|--help|-h)
            _usage_blend
            ;;

        *)
            die "Unknown blend subcommand: $subcmd"
            ;;
    esac
}

_usage_blend() {
    cat <<EOF
iwt vm storage bdfs-blend - Mount/unmount the BTRFS+DwarFS unified namespace

Subcommands:
  mount   --btrfs-uuid UUID --dwarfs-uuid UUID --mountpoint PATH [--writeback]
  umount  MOUNTPOINT

The blend layer merges a writable BTRFS upper layer with one or more read-only
DwarFS lower layers. Reads fall through BTRFS → DwarFS; writes always land on
BTRFS with automatic copy-up.

Examples:
  iwt vm storage bdfs-blend mount \\
      --btrfs-uuid <uuid> --dwarfs-uuid <uuid> --mountpoint /mnt/blend --writeback

  iwt vm storage bdfs-blend umount /mnt/blend
EOF
}

cmd_export() {
    local partition="" subvol_id="" btrfs_mount="" name="" compression="zstd" verify=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --partition)    partition="$2";    shift 2 ;;
            --subvol-id)    subvol_id="$2";    shift 2 ;;
            --btrfs-mount)  btrfs_mount="$2";  shift 2 ;;
            --name)         name="$2";         shift 2 ;;
            --compression)  compression="$2";  shift 2 ;;
            --verify)       verify=true;       shift   ;;
            --help|-h)      _usage_export; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$partition"   ]] || die "--partition is required"
    [[ -n "$subvol_id"   ]] || die "--subvol-id is required"
    [[ -n "$btrfs_mount" ]] || die "--btrfs-mount is required"
    [[ -n "$name"        ]] || die "--name is required"

    _require_bdfs

    echo ""
    bold "bdfs export"
    info "Partition:   $partition"
    info "Subvol ID:   $subvol_id"
    info "BTRFS mount: $btrfs_mount"
    info "Name:        $name"
    info "Compression: $compression"
    echo ""

    local args=(
        --partition   "$partition"
        --subvol-id   "$subvol_id"
        --btrfs-mount "$btrfs_mount"
        --name        "$name"
        --compression "$compression"
    )
    [[ "$verify" == true ]] && args+=(--verify)

    bdfs export "${args[@]}"
    ok "Exported '$name' to partition $partition"
}

_usage_export() {
    cat <<EOF
iwt vm storage bdfs-export - Export a BTRFS subvolume to a compressed DwarFS image

Options:
  --partition UUID    Target bdfs partition UUID  (required)
  --subvol-id  ID     BTRFS subvolume ID          (required)
  --btrfs-mount PATH  BTRFS filesystem mount      (required)
  --name       NAME   Image name                  (required)
  --compression ALG   zstd | lz4 | zlib           (default: zstd)
  --verify            Verify image after creation

Example:
  # List subvolume IDs first:
  btrfs subvolume list /mnt/data

  iwt vm storage bdfs-export \\
      --partition <uuid> --subvol-id 256 \\
      --btrfs-mount /mnt/data --name win11_v1 --verify
EOF
}

cmd_import() {
    local partition="" image_id="" btrfs_mount="" subvol_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --partition)    partition="$2";    shift 2 ;;
            --image-id)     image_id="$2";     shift 2 ;;
            --btrfs-mount)  btrfs_mount="$2";  shift 2 ;;
            --subvol-name)  subvol_name="$2";  shift 2 ;;
            --help|-h)      _usage_import; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$partition"   ]] || die "--partition is required"
    [[ -n "$image_id"    ]] || die "--image-id is required"
    [[ -n "$btrfs_mount" ]] || die "--btrfs-mount is required"
    [[ -n "$subvol_name" ]] || die "--subvol-name is required"

    _require_bdfs

    echo ""
    bold "bdfs import"
    info "Partition:   $partition"
    info "Image ID:    $image_id"
    info "BTRFS mount: $btrfs_mount"
    info "Subvol name: $subvol_name"
    echo ""

    bdfs import \
        --partition   "$partition"   \
        --image-id    "$image_id"    \
        --btrfs-mount "$btrfs_mount" \
        --subvol-name "$subvol_name"

    ok "Imported image $image_id as subvolume '$subvol_name'"
}

_usage_import() {
    cat <<EOF
iwt vm storage bdfs-import - Import a DwarFS image into a BTRFS subvolume

Options:
  --partition  UUID   Source bdfs partition UUID  (required)
  --image-id   ID     Image ID to import          (required)
  --btrfs-mount PATH  Destination BTRFS mount     (required)
  --subvol-name NAME  New subvolume name          (required)

Example:
  iwt vm storage bdfs-import \\
      --partition <uuid> --image-id 1 \\
      --btrfs-mount /mnt/data --subvol-name win11_restored
EOF
}

cmd_snapshot() {
    local partition="" image_id="" name="" readonly=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --partition)  partition="$2"; shift 2 ;;
            --image-id)   image_id="$2";  shift 2 ;;
            --name)       name="$2";      shift 2 ;;
            --readonly)   readonly=true;  shift   ;;
            --help|-h)    _usage_snapshot; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$partition" ]] || die "--partition is required"
    [[ -n "$image_id"  ]] || die "--image-id is required"
    [[ -n "$name"      ]] || die "--name is required"

    _require_bdfs

    echo ""
    bold "bdfs snapshot"
    info "Partition: $partition"
    info "Image ID:  $image_id"
    info "Name:      $name"
    info "Read-only: $readonly"
    echo ""

    local args=(--partition "$partition" --image-id "$image_id" --name "$name")
    [[ "$readonly" == true ]] && args+=(--readonly)

    bdfs snapshot "${args[@]}"
    ok "Snapshot '$name' created"
}

_usage_snapshot() {
    cat <<EOF
iwt vm storage bdfs-snapshot - CoW snapshot of a DwarFS image's BTRFS container

Options:
  --partition UUID   bdfs partition UUID  (required)
  --image-id  ID     Image ID to snapshot (required)
  --name      NAME   Snapshot name        (required)
  --readonly         Create read-only snapshot

Example:
  iwt vm storage bdfs-snapshot \\
      --partition <uuid> --image-id 1 --name win11_snap_$(date +%Y%m%d) --readonly
EOF
}

cmd_promote() {
    local blend_path="" subvol_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --blend-path)   blend_path="$2";  shift 2 ;;
            --subvol-name)  subvol_name="$2"; shift 2 ;;
            --help|-h)      _usage_promote_demote; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$blend_path"  ]] || die "--blend-path is required"
    [[ -n "$subvol_name" ]] || die "--subvol-name is required"

    _require_bdfs

    echo ""
    bold "bdfs promote"
    info "Blend path:  $blend_path"
    info "Subvol name: $subvol_name"
    echo ""

    bdfs promote --blend-path "$blend_path" --subvol-name "$subvol_name"
    ok "Promoted '$blend_path' to writable subvolume '$subvol_name'"
}

cmd_demote() {
    local blend_path="" image_name="" compression="zstd" delete_subvol=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --blend-path)    blend_path="$2";   shift 2 ;;
            --image-name)    image_name="$2";   shift 2 ;;
            --compression)   compression="$2";  shift 2 ;;
            --delete-subvol) delete_subvol=true; shift  ;;
            --help|-h)       _usage_promote_demote; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$blend_path"  ]] || die "--blend-path is required"
    [[ -n "$image_name"  ]] || die "--image-name is required"

    _require_bdfs

    echo ""
    bold "bdfs demote"
    info "Blend path:     $blend_path"
    info "Image name:     $image_name"
    info "Compression:    $compression"
    info "Delete subvol:  $delete_subvol"
    echo ""

    local args=(--blend-path "$blend_path" --image-name "$image_name" --compression "$compression")
    [[ "$delete_subvol" == true ]] && args+=(--delete-subvol)

    bdfs demote "${args[@]}"
    ok "Demoted '$blend_path' to DwarFS image '$image_name'"
}

_usage_promote_demote() {
    cat <<EOF
iwt vm storage bdfs-promote - Extract a DwarFS-backed path to a writable BTRFS subvolume

  --blend-path  PATH   Path inside the blend namespace  (required)
  --subvol-name NAME   New BTRFS subvolume name         (required)

iwt vm storage bdfs-demote - Compress a BTRFS subvolume to a DwarFS image

  --blend-path    PATH   Path inside the blend namespace  (required)
  --image-name    NAME   Output DwarFS image name         (required)
  --compression   ALG    zstd | lz4 | zlib                (default: zstd)
  --delete-subvol        Remove the BTRFS subvolume after demoting

Examples:
  iwt vm storage bdfs-promote --blend-path /mnt/blend/win11 --subvol-name win11_live
  iwt vm storage bdfs-demote  --blend-path /mnt/blend/win11_live --image-name win11_archived --delete-subvol
EOF
}

cmd_status() {
    local partition="" json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --partition) partition="$2"; shift 2 ;;
            --json)      json=true;      shift   ;;
            --help|-h)   echo "Usage: iwt vm storage bdfs-status [--partition UUID] [--json]"; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    _require_bdfs

    local args=()
    [[ -n "$partition" ]] && args+=(--partition "$partition")
    [[ "$json" == true ]] && args+=(--json)

    bdfs status "${args[@]}"
}

cmd_daemon() {
    local subcmd="${1:-status}"
    shift || true

    case "$subcmd" in
        start)
            if command -v systemctl &>/dev/null && systemctl list-unit-files bdfs_daemon.service &>/dev/null; then
                sudo systemctl start bdfs_daemon
                ok "bdfs_daemon started via systemd"
            else
                info "Starting bdfs_daemon in background..."
                sudo bdfs_daemon -v &
                ok "bdfs_daemon started (PID $!)"
            fi
            ;;
        stop)
            if command -v systemctl &>/dev/null && systemctl is-active bdfs_daemon &>/dev/null; then
                sudo systemctl stop bdfs_daemon
                ok "bdfs_daemon stopped"
            else
                sudo pkill -f bdfs_daemon && ok "bdfs_daemon stopped" || warn "bdfs_daemon not running"
            fi
            ;;
        status)
            if command -v systemctl &>/dev/null; then
                systemctl status bdfs_daemon 2>/dev/null || true
            fi
            if pgrep -x bdfs_daemon &>/dev/null; then
                ok "bdfs_daemon is running (PID $(pgrep -x bdfs_daemon))"
            else
                warn "bdfs_daemon is not running"
            fi
            ;;
        enable)
            sudo systemctl enable bdfs_daemon
            ok "bdfs_daemon enabled at boot"
            ;;
        disable)
            sudo systemctl disable bdfs_daemon
            ok "bdfs_daemon disabled"
            ;;
        help|--help|-h)
            cat <<EOF
iwt vm storage bdfs-daemon - Manage the bdfs_daemon process

Subcommands:
  start    Start bdfs_daemon (systemd or background)
  stop     Stop bdfs_daemon
  status   Show daemon status
  enable   Enable bdfs_daemon at boot (systemd)
  disable  Disable bdfs_daemon at boot (systemd)
EOF
            ;;
        *)
            die "Unknown daemon subcommand: $subcmd"
            ;;
    esac
}

cmd_check() {
    echo ""
    bold "bdfs (btrfs-dwarfs-framework) Host Check"
    echo ""

    local ok_count=0 fail_count=0

    _chk() {
        local label="$1" result="$2"
        if [[ "$result" == "ok" ]]; then
            ok "  $label"
            ok_count=$((ok_count + 1))
        else
            err "  $label: $result"
            fail_count=$((fail_count + 1))
        fi
    }
    _warn_chk() {
        local label="$1" msg="$2"
        warn "  $label: $msg"
    }

    # bdfs CLI
    if command -v bdfs &>/dev/null; then
        local ver
        ver=$(bdfs --version 2>/dev/null | head -1 || echo "unknown")
        _chk "bdfs CLI ($ver)" "ok"
    else
        _chk "bdfs CLI" "not found — build from https://github.com/Interested-Deving-1896/btrfs-dwarfs-framework"
    fi

    # bdfs_daemon
    if command -v bdfs_daemon &>/dev/null; then
        _chk "bdfs_daemon" "ok"
    else
        _chk "bdfs_daemon" "not found (build btrfs-dwarfs-framework userspace)"
    fi

    # kernel module
    if modinfo btrfs_dwarfs &>/dev/null 2>&1 || lsmod | grep -q '^btrfs_dwarfs'; then
        _chk "btrfs_dwarfs kernel module (loaded)" "ok"
    elif [[ -f /dev/bdfs_ctl ]]; then
        _chk "btrfs_dwarfs kernel module (/dev/bdfs_ctl present)" "ok"
    else
        _chk "btrfs_dwarfs kernel module" "not loaded — run: sudo insmod btrfs_dwarfs.ko"
    fi

    # /dev/bdfs_ctl
    if [[ -e /dev/bdfs_ctl ]]; then
        _chk "/dev/bdfs_ctl" "ok"
    else
        _warn_chk "/dev/bdfs_ctl" "not present (module not loaded or not installed)"
    fi

    # daemon running
    if pgrep -x bdfs_daemon &>/dev/null; then
        _chk "bdfs_daemon running" "ok"
    else
        _warn_chk "bdfs_daemon" "not running (start with: iwt vm storage bdfs-daemon start)"
    fi

    # btrfs-progs (required by bdfs export/import)
    if command -v btrfs &>/dev/null; then
        _chk "btrfs-progs" "ok"
    else
        _chk "btrfs-progs" "not found (required for export/import)"
    fi

    # DwarFS tools (required by bdfs export)
    if command -v mkdwarfs &>/dev/null && command -v dwarfs &>/dev/null; then
        _chk "DwarFS tools (mkdwarfs, dwarfs)" "ok"
    else
        _chk "DwarFS tools" "not found (required for export — see https://github.com/mhx/dwarfs/releases)"
    fi

    echo ""
    info "Results: $ok_count ok, $fail_count issues"

    if [[ $fail_count -gt 0 ]]; then
        echo ""
        info "Build btrfs-dwarfs-framework:"
        info "  git clone https://github.com/Interested-Deving-1896/btrfs-dwarfs-framework"
        info "  cd btrfs-dwarfs-framework && make all && sudo make install"
        info "  sudo insmod kernel/btrfs_dwarfs/btrfs_dwarfs.ko"
    fi

    [[ $fail_count -eq 0 ]]
}

# --- Scheduled demote ---

cmd_demote_schedule() {
    local blend_mount="" compression="${IWT_BDFS_COMPRESSION:-zstd}" \
          interval="24h" delete_subvol=false action="enable" timer_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --blend-mount)   blend_mount="$2";   shift 2 ;;
            --interval)      interval="$2";      shift 2 ;;
            --compression)   compression="$2";   shift 2 ;;
            --delete-subvol) delete_subvol=true; shift   ;;
            --disable)       action="disable";   shift   ;;
            --status)        action="status";    shift   ;;
            --help|-h)       _usage_demote_schedule; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    # Derive a stable timer name from the blend mount path
    timer_name="iwt-bdfs-demote$(echo "${blend_mount:-default}" | tr '/' '-' | tr -s '-')"

    case "$action" in
        enable)
            [[ -n "$blend_mount" ]] || die "--blend-mount is required"

            echo ""
            bold "bdfs demote-schedule: enable"
            info "Blend mount:  $blend_mount"
            info "Interval:     $interval"
            info "Compression:  $compression"
            info "Delete subvol: $delete_subvol"
            echo ""

            # Convert interval to systemd OnUnitActiveSec format
            # Accept: 1h, 6h, 24h, 7d, @daily, @weekly
            local systemd_interval="$interval"
            case "$interval" in
                @hourly)  systemd_interval="1h" ;;
                @daily)   systemd_interval="24h" ;;
                @weekly)  systemd_interval="168h" ;;
            esac

            local delete_flag=""
            [[ "$delete_subvol" == true ]] && delete_flag="--delete-subvol"

            # Write the systemd service unit
            local service_file="/etc/systemd/system/${timer_name}.service"
            sudo tee "$service_file" > /dev/null <<EOF
[Unit]
Description=IWT bdfs scheduled demote: ${blend_mount}
After=network.target

[Service]
Type=oneshot
ExecStart=$IWT_ROOT/storage/setup-bdfs.sh demote-run --blend-mount ${blend_mount} --compression ${compression} ${delete_flag}
StandardOutput=journal
StandardError=journal
EOF

            # Write the systemd timer unit
            local timer_file="/etc/systemd/system/${timer_name}.timer"
            sudo tee "$timer_file" > /dev/null <<EOF
[Unit]
Description=IWT bdfs scheduled demote timer: ${blend_mount}

[Timer]
OnBootSec=10min
OnUnitActiveSec=${systemd_interval}
Persistent=true

[Install]
WantedBy=timers.target
EOF

            sudo systemctl daemon-reload
            sudo systemctl enable --now "${timer_name}.timer"

            ok "Scheduled demote enabled: ${timer_name}.timer (every ${interval})"
            info "View logs: journalctl -u ${timer_name}.service"
            info "Run now:   sudo systemctl start ${timer_name}.service"
            ;;

        disable)
            [[ -n "$blend_mount" ]] || die "--blend-mount is required"
            sudo systemctl disable --now "${timer_name}.timer" 2>/dev/null || true
            sudo rm -f "/etc/systemd/system/${timer_name}.service" \
                       "/etc/systemd/system/${timer_name}.timer"
            sudo systemctl daemon-reload
            ok "Scheduled demote disabled and removed: $timer_name"
            ;;

        status)
            echo ""
            bold "bdfs demote timers:"
            echo ""
            systemctl list-timers "iwt-bdfs-demote*" --no-pager 2>/dev/null || \
                info "No bdfs demote timers found"
            ;;
    esac
}

# Run a single demote pass over all subvolumes in a blend mount that have
# accumulated writes on the BTRFS upper layer since the last demote.
cmd_demote_run() {
    local blend_mount="" compression="${IWT_BDFS_COMPRESSION:-zstd}" delete_subvol=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --blend-mount)   blend_mount="$2";   shift 2 ;;
            --compression)   compression="$2";   shift 2 ;;
            --delete-subvol) delete_subvol=true; shift   ;;
            --help|-h) echo "Usage: setup-bdfs.sh demote-run --blend-mount PATH [--compression ALG] [--delete-subvol]"; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$blend_mount" ]] || die "--blend-mount is required"
    mountpoint -q "$blend_mount" 2>/dev/null || die "Blend namespace not mounted at: $blend_mount"

    _require_bdfs

    info "Running scheduled demote on $blend_mount ..."

    local demoted=0 skipped=0

    local state_dir="${IWT_BDFS_RUNTIME:-/run/iwt/bdfs}"
    local stamp_file
    stamp_file="${state_dir}/demote-last-run-$(echo "$blend_mount" | tr '/' '_')"
    mkdir -p "$state_dir"

    # Resolve the BTRFS filesystem root that contains the blend mount.
    # `btrfs subvolume list -o` requires the filesystem root, not a nested
    # subvolume path — using the blend mount directly fails silently when it
    # is itself a subvolume. We find the root by walking up to the mount that
    # has a btrfs filesystem type.
    local btrfs_root=""
    while IFS= read -r mnt_point mnt_type _rest; do
        if [[ "$mnt_type" == "btrfs" && "$blend_mount" == "$mnt_point"* ]]; then
            # Pick the longest (most specific) matching btrfs mount
            if [[ ${#mnt_point} -gt ${#btrfs_root} ]]; then
                btrfs_root="$mnt_point"
            fi
        fi
    done < <(findmnt -rn -o TARGET,FSTYPE 2>/dev/null)

    if [[ -z "$btrfs_root" ]]; then
        die "Could not find a BTRFS filesystem containing '$blend_mount'. Is the blend namespace on a BTRFS volume?"
    fi

    info "  BTRFS root: $btrfs_root"

    # Enumerate subvolumes that live under the blend mount path.
    # `btrfs subvolume list` outputs paths relative to the filesystem root.
    local blend_rel="${blend_mount#"$btrfs_root"}"
    blend_rel="${blend_rel#/}"

    while IFS= read -r subvol_rel; do
        [[ -n "$subvol_rel" ]] || continue

        # Only process subvolumes that are direct children of the blend mount
        local subvol_parent="${subvol_rel%/*}"
        [[ "$subvol_parent" == "$blend_rel" ]] || continue

        local subvol_path="${btrfs_root}/${subvol_rel}"

        # Skip if nothing changed since last run
        if [[ -f "$stamp_file" ]] && \
           ! find "$subvol_path" -newer "$stamp_file" -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
            skipped=$((skipped + 1))
            continue
        fi

        local image_name
        image_name="$(basename "$subvol_path")-auto-$(date +%Y%m%d-%H%M%S)"

        info "  Demoting: $subvol_path → $image_name"

        local args=(--blend-path "$subvol_path" --image-name "$image_name" --compression "$compression")
        [[ "$delete_subvol" == true ]] && args+=(--delete-subvol)

        if bdfs demote "${args[@]}" 2>&1 | while IFS= read -r l; do info "    $l"; done; then
            demoted=$((demoted + 1))
        else
            warn "  Demote failed for $subvol_path — skipping"
        fi
    done < <(btrfs subvolume list "$btrfs_root" 2>/dev/null | awk '{print $NF}')

    touch "$stamp_file"
    ok "Scheduled demote complete: $demoted demoted, $skipped unchanged"
}

cmd_remount_all() {
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --help|-h) _usage_remount_all; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    local state_file="${IWT_BDFS_RUNTIME:-/run/iwt/bdfs}/shares.state"

    if [[ ! -f "$state_file" || ! -s "$state_file" ]]; then
        info "No registered bdfs shares found (${state_file} is empty or missing)"
        return 0
    fi

    _require_bdfs

    echo ""
    bold "bdfs remount-all"
    [[ "$dry_run" == true ]] && info "(dry-run — no changes will be made)"
    echo ""

    local remounted=0 skipped=0 failed=0

    while IFS='|' read -r blend_mount vm_name share_name cache_mode; do
        [[ -n "$share_name" ]] || continue

        info "Share: $share_name  VM: $vm_name  Blend: $blend_mount"

        # Re-mount the blend namespace if it dropped
        if ! mountpoint -q "$blend_mount" 2>/dev/null; then
            warn "  Blend not mounted at $blend_mount"
            warn "  Cannot remount blend automatically — bdfs-blend mount requires UUIDs."
            warn "  Run: iwt vm storage bdfs-blend mount --mountpoint $blend_mount ..."
            failed=$((failed + 1))
            continue
        fi

        # Re-attach the virtiofs device to the VM if it disappeared
        if ! incus info "$vm_name" &>/dev/null 2>&1; then
            warn "  VM '$vm_name' not found — skipping"
            skipped=$((skipped + 1))
            continue
        fi

        if incus config device show "$vm_name" 2>/dev/null | grep -q "^${share_name}:"; then
            ok "  Already attached to '$vm_name' — skipping"
            skipped=$((skipped + 1))
            continue
        fi

        if [[ "$dry_run" == true ]]; then
            info "  [dry-run] Would re-attach '$share_name' to '$vm_name'"
            remounted=$((remounted + 1))
            continue
        fi

        if incus config device add "$vm_name" "$share_name" disk \
               source="$blend_mount" path="/mnt/${share_name}" 2>/dev/null; then
            ok "  Re-attached '$share_name' to '$vm_name'"
            remounted=$((remounted + 1))
        else
            warn "  Failed to re-attach '$share_name' to '$vm_name'"
            failed=$((failed + 1))
        fi
    done < "$state_file"

    echo ""
    ok "remount-all complete: $remounted re-attached, $skipped already ok, $failed failed"
    [[ $failed -eq 0 ]]
}

_usage_remount_all() {
    cat <<EOF
iwt vm storage bdfs-remount-all - Re-attach all registered bdfs shares after a reboot or crash

Reads /run/iwt/bdfs/shares.state and re-attaches any virtiofs share that is
no longer attached to its VM. Blend namespaces that are not mounted are
reported but cannot be remounted automatically (UUIDs are required).

Options:
  --dry-run   Show what would be done without making changes

Example:
  # Add to a systemd unit or /etc/rc.local for post-reboot recovery:
  iwt vm storage bdfs-remount-all

  # Preview what would be remounted:
  iwt vm storage bdfs-remount-all --dry-run
EOF
}

_usage_demote_schedule() {
    cat <<EOF
iwt vm storage bdfs-demote-schedule - Schedule automatic recompression of BTRFS upper layer writes

As Windows writes through the virtiofs share, changes accumulate on the BTRFS
upper layer. This command installs a systemd timer that periodically runs
bdfs-demote on modified subvolumes to recompress them back to DwarFS.

Options:
  --blend-mount PATH   Blend namespace mountpoint to demote  (required)
  --interval INTERVAL  How often to run: 1h, 6h, 24h, 7d, @daily, @weekly (default: 24h)
  --compression ALG    zstd | lz4 | zlib  (default: IWT_BDFS_COMPRESSION or zstd)
  --delete-subvol      Remove BTRFS subvolume after demoting (reclaims space immediately)
  --disable            Remove the timer for this blend mount
  --status             List all active bdfs demote timers

Examples:
  iwt vm storage bdfs-demote-schedule --blend-mount /mnt/blend --interval 24h --delete-subvol
  iwt vm storage bdfs-demote-schedule --blend-mount /mnt/blend --status
  iwt vm storage bdfs-demote-schedule --blend-mount /mnt/blend --disable
EOF
}

# --- Share / unshare blend namespace with a Windows VM ---

cmd_share() {
    local blend_mount="" vm_name="" share_name="" writeback=false auto_mount=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --blend-mount)  blend_mount="$2"; shift 2 ;;
            --vm)           vm_name="$2";     shift 2 ;;
            --name)         share_name="$2";  shift 2 ;;
            --writeback)    writeback=true;   shift   ;;
            --auto-mount)   auto_mount=true;  shift   ;;
            --help|-h)      _usage_share; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$blend_mount" ]] || die "--blend-mount is required (path to an active bdfs blend mountpoint)"
    [[ -n "$vm_name"     ]] || die "--vm is required"
    [[ -n "$share_name"  ]] || share_name="$(basename "$blend_mount")"

    _require_bdfs
    _require_fuse

    echo ""
    bold "bdfs share"
    info "Blend mount: $blend_mount"
    info "VM:          $vm_name"
    info "Share name:  $share_name"
    info "Writeback:   $writeback"
    echo ""

    # Verify the blend namespace is actually mounted
    if ! mountpoint -q "$blend_mount" 2>/dev/null; then
        if [[ "$auto_mount" == true ]]; then
            die "Blend namespace is not mounted at '$blend_mount'.\n  Mount it first with: iwt vm storage bdfs-blend mount --mountpoint $blend_mount ..."
        else
            die "Blend namespace is not mounted at '$blend_mount'.\n  Mount it first with: iwt vm storage bdfs-blend mount --mountpoint $blend_mount ...\n  Or pass --auto-mount to fail with a clearer message."
        fi
    fi

    # Verify the VM exists
    incus info "$vm_name" &>/dev/null || die "VM '$vm_name' not found"

    # Reject duplicate share names on the same VM
    if incus config device show "$vm_name" 2>/dev/null | grep -q "^${share_name}:"; then
        die "Device '$share_name' is already attached to '$vm_name'. Use --name to choose a different name."
    fi

    # Attach the blend mountpoint to the VM as a virtiofs disk share.
    # writeback=false (the default) means the virtiofs mount inside Windows is
    # read-write but cache coherency is strict — safer for a CoW upper layer.
    # writeback=true enables virtiofs writeback caching for better throughput at
    # the cost of stricter ordering guarantees.
    local cache_mode="none"
    [[ "$writeback" == true ]] && cache_mode="writeback"

    incus config device add "$vm_name" "$share_name" disk \
        source="$blend_mount" \
        path="/mnt/${share_name}" \
        || die "Failed to attach virtiofs share to VM '$vm_name'"

    ok "Share '$share_name' attached to '$vm_name'"

    # Persist state so bdfs-unshare and list-shares can clean up
    local state_dir="${IWT_BDFS_RUNTIME:-/run/iwt/bdfs}"
    mkdir -p "$state_dir"
    echo "${blend_mount}|${vm_name}|${share_name}|${cache_mode}" \
        >> "${state_dir}/shares.state"

    # Push the share list into the VM immediately if it is running, so
    # bdfs-mount-shares.ps1 can discover shares without a separate
    # setup-guest --mount-bdfs-shares step.
    if incus info "$vm_name" 2>/dev/null | grep -q 'Status: Running'; then
        local ps1_src="${IWT_ROOT}/guest/bdfs-mount-shares.ps1"
        local share_list_tmp
        share_list_tmp=$(mktemp)

        echo "# bdfs shares for ${vm_name} — updated by bdfs-share $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            > "$share_list_tmp"
        while IFS='|' read -r _blend _vm sname _rest; do
            [[ "$_vm" == "$vm_name" && -n "$sname" ]] && echo "$sname"
        done < "${state_dir}/shares.state" >> "$share_list_tmp"

        if incus file push "$share_list_tmp" \
               "${vm_name}/C:/ProgramData/IWT/bdfs-shares.txt" 2>/dev/null; then
            ok "Share list pushed to '$vm_name' (C:\\ProgramData\\IWT\\bdfs-shares.txt)"
        else
            warn "Could not push share list to '$vm_name' — VM may not have guest agent running"
            info "  Run manually: iwt vm setup-guest --vm $vm_name --mount-bdfs-shares"
        fi

        if [[ -f "$ps1_src" ]]; then
            incus file push "$ps1_src" \
                "${vm_name}/C:/ProgramData/IWT/bdfs-mount-shares.ps1" 2>/dev/null || true
        fi

        rm -f "$share_list_tmp"
    else
        info "VM '$vm_name' is not running — share list will be pushed on next setup-guest run"
        info "  iwt vm setup-guest --vm $vm_name --mount-bdfs-shares"
    fi

    echo ""
    ok "bdfs blend namespace ready for Windows"
    info "Inside the Windows guest:"
    info "  - The share appears as a new disk via WinFsp / virtio-fs"
    info "  - Mount it with a drive letter: iwt-mount-shares.ps1 ${share_name} Z"
    info "  - Writes land on the BTRFS upper layer on the host"
    info ""
    info "To reclaim space after heavy writes, demote accumulated changes:"
    info "  iwt vm storage bdfs-demote --blend-path ${blend_mount}/<subvol> --image-name <name>"
}

cmd_unshare() {
    local vm_name="" share_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vm)     vm_name="$2";    shift 2 ;;
            --name)   share_name="$2"; shift 2 ;;
            --help|-h) echo "Usage: iwt vm storage bdfs-unshare --vm NAME --name SHARE"; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$vm_name"    ]] || die "--vm is required"
    [[ -n "$share_name" ]] || die "--name is required"

    echo ""
    bold "bdfs unshare"
    info "VM:         $vm_name"
    info "Share name: $share_name"
    echo ""

    # Detach from VM
    if incus config device show "$vm_name" 2>/dev/null | grep -q "^${share_name}:"; then
        incus config device remove "$vm_name" "$share_name"
        ok "Detached '$share_name' from '$vm_name'"
    else
        warn "Share '$share_name' not found on '$vm_name' — may already be detached"
    fi

    # Remove from state file
    local state_file="${IWT_BDFS_RUNTIME:-/run/iwt/bdfs}/shares.state"
    if [[ -f "$state_file" ]]; then
        grep -v "|${vm_name}|${share_name}|" "$state_file" > "${state_file}.tmp" || true
        mv "${state_file}.tmp" "$state_file"
    fi

    ok "Share '$share_name' removed"
    info "The blend namespace itself is still mounted on the host."
    info "To unmount it: iwt vm storage bdfs-blend umount <mountpoint>"
}

cmd_list_shares() {
    echo ""
    bold "Active bdfs Shares:"
    echo ""

    local state_file="${IWT_BDFS_RUNTIME:-/run/iwt/bdfs}/shares.state"
    if [[ ! -f "$state_file" ]] || [[ ! -s "$state_file" ]]; then
        info "No active bdfs shares"
        return 0
    fi

    printf "  %-20s %-15s %-10s %s\n" "SHARE" "VM" "CACHE" "BLEND MOUNT"
    printf "  %-20s %-15s %-10s %s\n" "-----" "--" "-----" "-----------"

    while IFS='|' read -r blend_mount vm_name share_name cache_mode; do
        [[ -n "$share_name" ]] || continue
        local mounted="no"
        mountpoint -q "$blend_mount" 2>/dev/null && mounted="yes"
        local attached="no"
        incus config device show "$vm_name" 2>/dev/null | grep -q "^${share_name}:" && attached="yes"
        printf "  %-20s %-15s %-10s %s (blend mounted: %s, vm attached: %s)\n" \
            "$share_name" "$vm_name" "${cache_mode:-none}" "$blend_mount" "$mounted" "$attached"
    done < "$state_file"
}

_usage_share() {
    cat <<EOF
iwt vm storage bdfs-share - Expose a bdfs blend namespace to a Windows VM via virtiofs

The blend namespace must already be mounted on the host before calling this.
Windows accesses it through WinFsp as a drive letter — the BTRFS+DwarFS
layer underneath is transparent. Writes from Windows land on the BTRFS upper
layer; use bdfs-demote to recompress them back to DwarFS.

Options:
  --blend-mount PATH   Path to an active bdfs blend mountpoint  (required)
  --vm          NAME   Target VM name                           (required)
  --name        NAME   Share name visible in Incus              (default: basename of blend-mount)
  --writeback          Enable virtiofs writeback cache (higher throughput, less strict ordering)

Examples:
  # Mount the blend namespace first, then share it
  iwt vm storage bdfs-blend mount \\
      --btrfs-uuid <uuid> --dwarfs-uuid <uuid> --mountpoint /mnt/blend --writeback

  iwt vm storage bdfs-share --blend-mount /mnt/blend --vm win11 --name win-data

  # Remove the share (blend namespace stays mounted on host)
  iwt vm storage bdfs-unshare --vm win11 --name win-data

  # List all active bdfs shares
  iwt vm storage bdfs-list-shares
EOF
}

# --- Helpers ---

_require_bdfs() {
    if ! command -v bdfs &>/dev/null; then
        die "bdfs not found. Build btrfs-dwarfs-framework and install it first.
  git clone https://github.com/Interested-Deving-1896/btrfs-dwarfs-framework
  cd btrfs-dwarfs-framework && make all && sudo make install"
    fi
    if ! command -v bdfs_daemon &>/dev/null; then
        die "bdfs_daemon not found. Build btrfs-dwarfs-framework userspace first."
    fi
    if ! pgrep -x bdfs_daemon &>/dev/null; then
        die "bdfs_daemon is not running. Start it with: iwt vm storage bdfs-daemon start"
    fi
}

usage() {
    cat <<EOF
setup-bdfs.sh - bdfs (btrfs-dwarfs-framework) integration for IWT

Usage: setup-bdfs.sh <subcommand> [options]

Subcommands:
  partition    add|remove|list|show   Manage bdfs partitions
  blend        mount|umount           Manage the BTRFS+DwarFS blend namespace
  export                              Export a BTRFS subvolume to a DwarFS image
  import                              Import a DwarFS image into a BTRFS subvolume
  snapshot                            CoW snapshot of a DwarFS image container
  promote                             Make a DwarFS-backed path writable
  demote                              Compress a BTRFS subvolume to DwarFS
  share                               Expose a blend namespace to a Windows VM via virtiofs
  unshare                             Remove a blend virtiofs share from a VM
  list-shares                         List active bdfs virtiofs shares
  demote-schedule                     Install/remove a systemd timer for automatic demote
  demote-run                          Run a single demote pass (used by the timer)
  remount-all                         Re-attach all registered shares after reboot/crash
  status                              Show bdfs partition/blend status
  daemon       start|stop|status      Manage bdfs_daemon
  check                               Verify host prerequisites
  help                                Show this help

Run 'setup-bdfs.sh <subcommand> --help' for per-subcommand options.
EOF
}

# --- Dispatch ---

subcmd="${1:-help}"
shift || true

case "$subcmd" in
    partition)    cmd_partition   "$@" ;;
    blend)        cmd_blend       "$@" ;;
    export)       cmd_export      "$@" ;;
    import)       cmd_import      "$@" ;;
    snapshot)     cmd_snapshot    "$@" ;;
    promote)      cmd_promote     "$@" ;;
    demote)       cmd_demote      "$@" ;;
    share)            cmd_share            "$@" ;;
    unshare)          cmd_unshare          "$@" ;;
    list-shares)      cmd_list_shares      "$@" ;;
    demote-schedule)  cmd_demote_schedule  "$@" ;;
    demote-run)       cmd_demote_run       "$@" ;;
    remount-all)      cmd_remount_all      "$@" ;;
    status)           cmd_status           "$@" ;;
    daemon)       cmd_daemon      "$@" ;;
    check)        cmd_check       "$@" ;;
    help|--help|-h) usage ;;
    *) die "Unknown subcommand: $subcmd. Run 'setup-bdfs.sh help' for usage." ;;
esac

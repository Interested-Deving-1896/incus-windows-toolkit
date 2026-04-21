# bdfs — BTRFS+DwarFS Hybrid Storage

bdfs integrates [btrfs-dwarfs-framework](https://gitlab.com/openos-project/linux-kernel_filesystem_deving/btrfs-dwarfs-framework)
as an optional storage backend. It merges a writable BTRFS upper layer with
one or more read-only DwarFS lower layers into a single unified namespace.
Reads fall through BTRFS → DwarFS; writes always land on BTRFS with automatic
copy-up. The result is a filesystem that looks fully writable but stores
unchanged data in compressed DwarFS images.

Windows VMs access blend namespaces via virtiofs, appearing as drive letters
through WinFsp.

---

## Prerequisites

**Host**

- Linux kernel with FUSE support
- [btrfs-dwarfs-framework](https://gitlab.com/openos-project/linux-kernel_filesystem_deving/btrfs-dwarfs-framework) built and installed:
  ```
  git clone https://gitlab.com/openos-project/linux-kernel_filesystem_deving/btrfs-dwarfs-framework
  cd btrfs-dwarfs-framework && make all && sudo make install
  sudo insmod kernel/btrfs_dwarfs/btrfs_dwarfs.ko
  ```
- `bdfs_daemon` running (`iwt vm storage bdfs-daemon start`)
- btrfs-progs (`apt install btrfs-progs`)
- DwarFS tools — `mkdwarfs` and `dwarfs` from the [DwarFS releases page](https://github.com/mhx/dwarfs/releases)
- Incus with virtiofs support

**Guest (Windows VM)**

- [WinFsp](https://winfsp.dev/) installed in the VM
- VirtioFsSvc running (provided by the VirtIO guest tools package)

Verify the host setup at any time:

```
iwt vm storage bdfs-check
```

---

## Core concepts

| Term | Meaning |
|------|---------|
| **partition** | A registered block device or filesystem that bdfs manages (BTRFS-backed or DwarFS-backed) |
| **blend namespace** | A mounted BTRFS+DwarFS overlay at a host path (e.g. `/mnt/iwt-blend`) |
| **share** | A blend namespace exposed to a Windows VM as a virtiofs device |
| **demote** | Compress a BTRFS subvolume into a DwarFS image (reclaim space) |
| **promote** | Extract a DwarFS-backed path back to a writable BTRFS subvolume |

---

## Workflow

### 1. Register a partition

```
iwt vm storage bdfs-partition add \
    --type btrfs-backed \
    --device /dev/sdb1 \
    --label archive \
    --mount /mnt/archive
```

Types:
- `btrfs-backed` — stores DwarFS images on a BTRFS filesystem
- `dwarfs-backed` — stores BTRFS snapshots as DwarFS images

### 2. Mount a blend namespace

```
iwt vm storage bdfs-blend mount \
    --btrfs-uuid <uuid> \
    --dwarfs-uuid <uuid> \
    --mountpoint /mnt/iwt-blend
```

Add `--writeback` to enable writeback cache on the blend layer (higher
throughput, relaxed cache coherency — only use if you understand the
trade-off).

The UUIDs are persisted to `/run/iwt/bdfs/blend-<key>.state` so subsequent
commands can auto-populate them.

### 3. Share the blend namespace with a Windows VM

```
iwt vm storage bdfs-share \
    --blend-mount /mnt/iwt-blend \
    --vm my-windows-vm \
    --name my-share
```

Options:
- `--name NAME` — virtiofs device name (defaults to the mountpoint basename)
- `--writeback` — enable writeback cache on both the blend mount and the virtiofs device

This command:
1. Attaches the blend mountpoint to the VM as a virtiofs disk device via Incus
2. Writes an entry to `/var/lib/iwt/bdfs/shares.state`
3. If the VM is running, pushes `bdfs-mount-shares.ps1` and the share list into the VM immediately

### 4. Mount shares inside Windows

If the VM is already running, shares can be mounted immediately:

```
iwt vm setup-guest --vm my-windows-vm --mount-bdfs-shares
```

This pushes `bdfs-mount-shares.ps1` to `C:\ProgramData\IWT\` and registers a
Windows logon scheduled task so shares auto-mount as drive letters on every
login.

To mount manually inside the VM:

```powershell
C:\ProgramData\IWT\bdfs-mount-shares.ps1 -All
```

---

## Maintenance

### Demote (compress BTRFS writes to DwarFS)

After accumulating writes on the BTRFS upper layer, demote them back to
compressed DwarFS images to reclaim space:

```
iwt vm storage bdfs-demote \
    --blend-path /mnt/iwt-blend/subvol \
    --image-name my-image-v2 \
    --compression zstd
```

Add `--delete-subvol` to remove the BTRFS subvolume immediately after demoting.

### Schedule automatic demote

```
iwt vm storage bdfs-demote-schedule \
    --blend-mount /mnt/iwt-blend \
    --interval 24h \
    --delete-subvol
```

This installs a systemd timer that runs `bdfs-demote-run` on the given
interval. Subvolumes unchanged since the last run are skipped.

### Promote (make a DwarFS path writable)

```
iwt vm storage bdfs-promote \
    --blend-path /mnt/iwt-blend/some-image \
    --subvol-name editable-copy
```

### Remove a share

```
iwt vm storage bdfs-unshare --vm my-windows-vm --name my-share
```

### List active shares

```
iwt vm storage bdfs-list-shares
```

### Unified status

```
iwt vm storage bdfs-status
```

Shows daemon state, mounted blend namespaces, active shares cross-referenced
with VM status, and demote timer state.

---

## Boot recovery

After a host reboot, blend namespaces and virtiofs device attachments are lost.
IWT provides automatic recovery via a systemd service.

### Install the recovery service

```
iwt vm storage bdfs-install-units
```

This installs two units:

| Unit | Purpose |
|------|---------|
| `iwt-bdfs-remount-all.service` | Runs at boot after Incus starts; remounts all blend namespaces and re-attaches virtiofs devices using UUIDs stored in `shares.state` |
| `iwt-bdfs-blend-mount@.service` | Template unit instantiated by `blend-persist` for blend namespaces that should mount at boot |

### Declare persistent blend namespaces

For blend namespaces that should mount automatically at boot (independent of
the share recovery service):

```
iwt vm storage bdfs-blend-persist add \
    --btrfs-uuid <uuid> \
    --dwarfs-uuid <uuid> \
    --mountpoint /mnt/iwt-blend
```

This writes an entry to `/etc/iwt/bdfs-blends.conf` and enables a
`iwt-bdfs-blend-mount@<escaped-path>.service` instance.

### Manual recovery

If the recovery service is not installed, re-attach all registered shares
manually:

```
iwt vm storage bdfs-remount-all
```

Use `--dry-run` to preview what would be remounted without making changes.

---

## State files

| Path | Contents | Lifetime |
|------|----------|----------|
| `/var/lib/iwt/bdfs/shares.state` | One line per registered share: `blend_mount\|vm_name\|share_name\|cache_mode\|btrfs_uuid\|dwarfs_uuid\|blend_writeback` | Persistent (survives reboots) |
| `/run/iwt/bdfs/blend-<key>.state` | Per-blend UUID and writeback flag | Ephemeral (lost on reboot; recreated by `remount-all`) |
| `/etc/iwt/bdfs-blends.conf` | Persistent blend namespace declarations | Persistent |

The `shares.state` format is backward-compatible: entries written before the
`blend_writeback` field (7th field) was added are treated as `blend_writeback=false`.

---

## Configuration

Add to `~/.config/iwt/config` (or run `iwt config init`):

```bash
IWT_BDFS_ENABLED=true          # opt-in flag (default: false)
IWT_BDFS_COMPRESSION=zstd      # default compression for export/demote
IWT_BDFS_BLEND_MOUNT=/mnt/iwt-blend  # default blend mountpoint
IWT_BDFS_STATE_DIR=/var/lib/iwt/bdfs # persistent state directory
```

---

## TUI

All bdfs operations are available through the interactive TUI:

```
iwt tui
```

Navigate to **bdfs Hybrid Storage** from the main menu or the VM submenu.

---

## Troubleshooting

**`bdfs-check` reports module not loaded**

```
sudo insmod /path/to/btrfs_dwarfs.ko
```

Or add to `/etc/modules` for automatic loading at boot.

**`bdfs-check` reports daemon not running**

```
iwt vm storage bdfs-daemon start
```

**Share not visible in Windows**

1. Confirm the virtiofs device is attached: `incus config device show <vm>`
2. Confirm WinFsp and VirtioFsSvc are running in the guest
3. Run `bdfs-mount-shares.ps1 -List` inside the VM to see discovered shares
4. Check `iwt doctor` for stale share entries

**`remount-all` fails with "no UUIDs stored"**

The share was registered before UUID auto-population was implemented. Re-register it:

```
iwt vm storage bdfs-unshare --vm <vm> --name <share>
iwt vm storage bdfs-share --blend-mount <path> --vm <vm> --name <share>
```

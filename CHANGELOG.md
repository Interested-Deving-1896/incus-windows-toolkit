# Changelog

## v1.3.0

### bdfs hardening

- **`bdfs-blend-persist`**: replaced broken `.mount` unit with a proper `Type=oneshot` service using the new `iwt-bdfs-blend-mount@.service` template; per-instance UUIDs supplied via drop-in `Environment=` files
- **`iwt-bdfs-blend-mount@.service`**: parameterized template unit (instantiated via `systemd-escape --path`) with `After=bdfs_daemon.service`; installed by `bdfs-install-units` and `bdfs-blend-persist add`
- **`shares.state` persistence**: moved from `/run/iwt/bdfs/` (tmpfs, lost on reboot) to `/var/lib/iwt/bdfs/`; blend state files remain ephemeral in `/run/iwt/bdfs/`; new `IWT_BDFS_STATE_DIR` config var
- **`bdfs-share` deduplication**: rejects duplicate `vm+share` registrations with a clear remediation message
- **`bdfs-remount-all` full auto-recovery**: uses stored UUIDs to remount dropped blend namespaces before re-attaching virtiofs devices; post-reboot recovery is now zero-touch for shares registered with UUID data
- **`bdfs-install-units`**: also installs the `iwt-bdfs-blend-mount@.service` template alongside `iwt-bdfs-remount-all.service`
- **Integration tests**: stub-based scaffold covering `bdfs-share` deduplication, `remount-all` with/without UUIDs, `list-shares` state parsing, and `bdfs-check` output

## v1.2.0

### bdfs — BTRFS+DwarFS Hybrid Storage

Integrates [btrfs-dwarfs-framework](https://github.com/Interested-Deving-1896/btrfs-dwarfs-framework)
as an optional storage backend that blends a writable BTRFS upper layer with
read-only DwarFS lower layers into a unified namespace.

**Core operations** (`iwt vm storage bdfs-*`):
- `bdfs-partition add/remove/list/show` — register and manage bdfs partitions
- `bdfs-blend mount/umount` — mount/unmount the BTRFS+DwarFS blend namespace
- `bdfs-export` — export a BTRFS subvolume to a compressed DwarFS image
- `bdfs-import` — import a DwarFS image back into a BTRFS subvolume
- `bdfs-snapshot` — CoW snapshot of a DwarFS image container
- `bdfs-promote` — make a DwarFS-backed path writable (extract to BTRFS)
- `bdfs-demote` — compress a BTRFS subvolume into a DwarFS image
- `bdfs-status` — show partition and blend status
- `bdfs-daemon start/stop/status` — manage `bdfs_daemon` lifecycle
- `bdfs-check` — verify host prerequisites

**Windows VM sharing**:
- `bdfs-share` — expose a blend namespace to a Windows VM via virtiofs; automatically pushes `bdfs-mount-shares.ps1` and the share list into the VM if it is running
- `bdfs-unshare` — detach the share from the VM
- `bdfs-list-shares` — list active bdfs virtiofs shares with mount/attach status
- `guest/bdfs-mount-shares.ps1` — PowerShell helper that auto-mounts bdfs shares as drive letters via WinFsp; supports `-All`, `-ShareName`/`-DriveLetter`, `-List`, `-Unmount`
- `iwt vm setup-guest --mount-bdfs-shares` — push the helper and register a Windows logon scheduled task (included in `--all`)

**Maintenance**:
- `bdfs-demote-schedule` — install/remove a systemd timer for automatic recompression of BTRFS upper layer writes; uses `findmnt` to resolve the BTRFS filesystem root correctly even when the blend mount is a nested subvolume
- `bdfs-demote-run` — single demote pass invoked by the timer; skips unchanged subvolumes via timestamp tracking
- `bdfs-remount-all` — re-attach all registered shares after a reboot or daemon crash; supports `--dry-run`

**Observability**:
- `iwt doctor` now checks for bdfs CLI, kernel module, and daemon; warns on stale `shares.state` entries (unmounted blend paths, missing VMs, detached devices) and on active shares with no demote timer

**Configuration** (added to default config):
- `IWT_BDFS_ENABLED=false` — opt-in flag
- `IWT_BDFS_COMPRESSION=zstd` — default compression for export/demote
- `IWT_BDFS_BLEND_MOUNT=/mnt/iwt-blend` — default blend mountpoint

**TUI**: new `bdfs` menu accessible from both the main menu and the VM submenu, covering the full workflow including demote scheduling

**Tests**: 52 new unit tests covering script structure, argument validation, state file handling, CLI dispatch, lib helpers, config defaults, doctor checks, guest setup, and TUI integration

## v1.1.0

### Auto-Update
- `iwt update check` — check GitHub for new releases with semver comparison
- `iwt update install` — self-update via git pull or tarball download

### App Store
- `iwt apps list/show/install` — curated winget app bundles
- 6 bundles: dev, gaming, office, creative, sysadmin, security
- `iwt apps search` — search winget inside the VM
- `iwt apps install-app` — install individual apps by winget ID

### Cloud Sync
- `iwt cloud push/pull` — sync backups to S3, B2, or any rclone remote
- `iwt cloud config` — configure remote storage (S3, B2, interactive)
- `iwt cloud status` — show sync status with unsynced file detection
- `iwt cloud list` — list remote backups

### Web Dashboard
- `iwt dashboard` — lightweight HTTP monitoring UI on port 8420
- Dark-themed single-page app with auto-refresh every 5 seconds
- VM table with status, template, CPU, memory, disk, IP
- System cards: running VMs, host memory, host disk, IWT version
- JSON API at `/api/vms` for integration
- Works with socat, ncat, or python3

### Security Hardening
- `iwt vm harden` — apply security measures to VMs
- Secure Boot, TPM 2.0, network isolation, read-only snapshots
- `iwt vm harden --check` — audit current security posture
- Guest-side checks: Windows Defender, Firewall, BitLocker, UAC
- AppArmor profile for the iwt CLI (`security/apparmor-iwt`)

### Integration Tests
- 8 new integration tests: template create, backup/restore, export/import,
  monitor health, fleet list (require Incus)

### Community
- Issue templates (bug report, feature request)
- CONTRIBUTING.md with development setup and code style guide
- CI badges in README (build status, release version, license)

## v1.0.0

Initial release of the Incus Windows Toolkit.

### Image Pipeline
- Download Windows ISOs from Microsoft (10, 11, Server 2019-2025)
- ARM64 ISO acquisition via UUP dump API with local conversion
- Build Incus-ready images with VirtIO driver injection
- Bloatware removal (tiny11-style) using wimlib
- Unattended answer file generation
- VirtIO driver management (`iwt image drivers`)

### VM Management
- Create VMs from templates: gaming, dev, server, minimal
- Start, stop, status, list operations
- Full RDP desktop sessions via FreeRDP
- Guest tool installation (WinFsp, VirtIO guest tools) via agent
- First-boot PowerShell hooks from templates or user scripts

### Device Passthrough
- GPU: VFIO passthrough, Looking Glass (IVSHMEM), SR-IOV, mdev
- USB: hotplug attach/detach by vendor:product ID
- Shared folders: virtiofs/9p with WinFsp drive letter mounting

### Networking
- Port forwarding (add, remove, list)
- NIC management (add, remove)

### Snapshots
- Create, restore, delete snapshots
- Auto-snapshot scheduling with expiry

### Backup & Export
- Full VM backup as compressed tarball
- Export as reusable Incus image
- Import from backup or image file

### RemoteApp
- Launch Windows apps as seamless Linux windows
- Generate .desktop entries for Linux app menus
- App discovery and icon extraction

### Fleet Management
- Multi-VM orchestration (start-all, stop-all, backup-all)
- Fleet status overview
- Execute commands across all running VMs

### Monitoring
- VM resource statistics (CPU, memory, disk, network)
- Disk usage breakdown
- Uptime and boot history
- System health check

### Profiles
- x86_64: windows-desktop, windows-server
- ARM64: windows-desktop, windows-server
- GPU overlays: vfio-passthrough, looking-glass, sriov-gpu, mdev-virtual-gpu

### User Interface
- CLI with bash/zsh completion
- Interactive TUI (dialog/whiptail)
- `iwt doctor` prerequisite checker

### Packaging
- `make install/uninstall` with DESTDIR support
- Man page source (pandoc)
- AUR PKGBUILD, Debian control, RPM spec

# IWT - Incus Windows Toolkit

[![CI](https://gitlab.com/OSPF1896/incus-windows-toolkit/actions/workflows/ci.yaml/badge.svg)](https://gitlab.com/OSPF1896/incus-windows-toolkit/actions/workflows/ci.yaml)
[![Release](https://img.shields.io/github/v/release/Interested-Deving-1896/incus-windows-toolkit)](https://gitlab.com/OSPF1896/incus-windows-toolkit/releases)
[![License](https://img.shields.io/github/license/Interested-Deving-1896/incus-windows-toolkit)](LICENSE)

Run Windows VMs and seamless Windows applications on Linux, managed entirely
through [Incus](https://linuxcontainers.org/incus).

IWT replaces the need to separately manage QEMU, libvirt, Docker containers,
and ad-hoc scripts.

## Feature Matrix

| Feature | x86_64 | ARM64 |
|---------|--------|-------|
| ISO download from Microsoft | Yes | Via UUP dump |
| Image build with VirtIO drivers | Yes | Yes + WOA drivers |
| Bloatware removal (tiny11-style) | Yes | Yes |
| VM templates (gaming, dev, server) | Yes | Yes |
| RDP desktop session | Yes | Yes |
| RemoteApp (seamless Linux windows) | Yes | Yes |
| GPU passthrough (VFIO) | Yes | - |
| Looking Glass (IVSHMEM) | Yes | - |
| SR-IOV / mdev virtual GPU | Yes | - |
| USB passthrough (hotplug) | Yes | Yes |
| Shared folders (virtiofs/9p) | Yes | Yes |
| WinFsp guest setup | Yes | Yes |
| Snapshots + auto-schedule | Yes | Yes |
| Port forwarding | Yes | Yes |
| Backup/export/import | Yes | Yes |
| First-boot hooks (PowerShell) | Yes | Yes |
| Interactive TUI | Yes | Yes |
| Bash/Zsh completion | Yes | Yes |

## Quick Start

```bash
# Install
git clone https://gitlab.com/OSPF1896/incus-windows-toolkit
cd incus-windows-toolkit
sudo make install

# Check prerequisites
iwt doctor

# Download and build a slim Windows 11 image
iwt image download --version 11
iwt image drivers download
iwt image build --iso Win11_*.iso --slim --inject-drivers

# Create a VM from a template
iwt vm create --template dev --name win11

# Start and connect
iwt vm start win11
iwt vm setup-guest --vm win11
iwt vm rdp win11
```

### ARM64

```bash
iwt image download --version 11 --arch arm64
iwt image build --iso Win11_arm64_*.iso --arch arm64 --slim --inject-drivers
iwt vm create --template minimal --name win11-arm
```

### Templates

```bash
iwt vm template list
iwt vm create --template gaming --name my-gaming-vm   # 8 CPU, 16GB, GPU passthrough
iwt vm create --template dev --name dev-vm            # Shared folders, dev tools
iwt vm create --template server --name srv            # Headless, auto-start
iwt vm create --template minimal --name test          # Bare-bones
```

### Interactive TUI

```bash
iwt tui
```

Requires `dialog` or `whiptail`. Provides menus for all operations.

## Commands

```
iwt image download    Download Windows ISO from Microsoft
iwt image build       Build Incus-ready image (slim, drivers, answer file)
iwt image drivers     Download/manage VirtIO drivers

iwt vm create         Create VM (with optional --template)
iwt vm start/stop     VM lifecycle
iwt vm rdp            Full RDP desktop session
iwt vm setup-guest    Install WinFsp + VirtIO guest tools in running VM
iwt vm first-boot     Run PowerShell scripts via agent
iwt vm template       List/show VM templates
iwt vm snapshot       Create, restore, delete, auto-schedule
iwt vm share          Add, remove, mount shared folders
iwt vm gpu            Attach, detach, status, IOMMU check
iwt vm usb            Attach, detach, hotplug USB devices
iwt vm net            Port forwarding, NIC management
iwt vm backup         Backup/restore VMs as tarballs
iwt vm export/import  Publish as Incus image or import

iwt remoteapp launch  Run Windows app as seamless Linux window
iwt remoteapp install Generate .desktop entries for Linux app menu

iwt profiles install  Install Incus VM profiles
iwt doctor            Check prerequisites
iwt config            Manage configuration
iwt tui               Interactive terminal UI
```

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  iwt CLI / TUI                                       │
│  image · vm · remoteapp · profiles · doctor · config │
└──────────────────────────┬───────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────┐
│  Incus (VM lifecycle, networking, storage, agent)     │
│  Profiles: desktop, server, GPU overlays              │
└──────────────────────────┬───────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────┐
│  Image Pipeline                                       │
│  ISO → extract → slim → VirtIO drivers → answer file  │
│  → guest tools → repack ISO → QCOW2 disk             │
└──────────────────────────┬───────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────┐
│  Windows Guest                                        │
│  incus-agent · VirtIO · WinFsp · RDP/RemoteApp        │
│  First-boot hooks · Shared folders · GPU passthrough  │
└──────────────────────────────────────────────────────┘
```

## Project Structure

```
incus-windows-toolkit/
├── cli/
│   ├── iwt.sh              Main CLI entrypoint
│   ├── lib.sh              Shared library (colors, retry, config, caching)
│   └── backup.sh           Backup/export/import operations
├── image-pipeline/
│   ├── scripts/
│   │   ├── build-image.sh  Image build pipeline
│   │   ├── download-iso.sh ISO download (Microsoft + UUP dump)
│   │   └── manage-drivers.sh VirtIO driver management
│   ├── answer-files/       Unattend XML templates
│   └── drivers/            Custom driver staging
├── profiles/
│   ├── x86_64/             Desktop + server profiles
│   ├── arm64/              ARM64 profiles
│   └── gpu/                GPU overlay profiles (VFIO, Looking Glass, etc.)
├── remoteapp/
│   ├── backend/
│   │   ├── incus-backend.sh VM operations
│   │   └── launch-app.sh   RemoteApp launcher
│   └── freedesktop/        .desktop generation, app/share configs
├── guest/
│   ├── setup-guest.sh      Guest tool orchestrator
│   ├── setup-winfsp.sh     WinFsp download + install
│   └── first-boot.sh       First-boot hook executor
├── gpu/
│   ├── setup-vfio.sh       Host VFIO GPU binding
│   └── setup-looking-glass.sh IVSHMEM setup
├── templates/              VM presets (gaming, dev, server, minimal)
├── tui/                    Interactive terminal UI
├── tests/                  Test suite (80+ unit tests)
├── doc/                    Man page source
├── packaging/              AUR, deb, rpm configs
├── Makefile                Install/uninstall/test targets
└── README.md
```

## Install

### From source

```bash
git clone https://gitlab.com/OSPF1896/incus-windows-toolkit
cd incus-windows-toolkit
sudo make install          # installs to /usr/local
sudo make PREFIX=/usr install  # or /usr for distro packaging
```

### Run without installing

```bash
./cli/iwt.sh doctor
./cli/iwt.sh vm create --name test
```

### Uninstall

```bash
sudo make uninstall
```

## Prerequisites

```bash
iwt doctor    # checks everything and suggests install commands
```

**Required:** Incus, qemu-img, curl, KVM (/dev/kvm)

**Recommended:** xfreerdp3, wimlib-imagex, xorriso, jq

**Optional:** dialog/whiptail (TUI), hivex (registry editing), cabextract (ARM64), shellcheck (dev)

## Configuration

```bash
iwt config init    # create ~/.config/iwt/config
iwt config edit    # open in $EDITOR
iwt config show    # display current config
```

Environment variables: `IWT_VM_NAME`, `IWT_CONFIG_FILE`, `IWT_CACHE_DIR`, `IWT_BACKUP_DIR`

## Lineage

| Concern | Prior Art |
|---------|-----------|
| VM orchestration | [quickemu](https://github.com/quickemu-project/quickemu), [bvm](https://github.com/Botspot/bvm) |
| Incus Windows images | [incus-windows](https://github.com/antifob/incus-windows) |
| Seamless Windows apps | [winapps](https://github.com/Fmstrat/winapps), [winboat](https://github.com/TibixDev/winboat) |
| Image slimming | [tiny11builder](https://github.com/ntdevlabs/tiny11builder) |
| Guest filesystem | [winfsp](https://github.com/winfsp/winfsp) |
| ARM drivers | [WOA-Drivers](https://github.com/edk2-porting/WOA-Drivers) |
| ISO acquisition | [UUP dump](https://uupdump.net/), [Mido](https://github.com/ElliotKillick/Mido) |
| GPU passthrough | [Looking Glass](https://looking-glass.io/), [VFIO](https://www.kernel.org/doc/html/latest/driver-api/vfio.html) |

## License

Apache-2.0

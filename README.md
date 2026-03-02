# IWT - Incus Windows Toolkit

Run Windows VMs and seamless Windows applications on Linux, managed entirely
through [Incus](https://linuxcontainers.org/incus).

IWT replaces the need to separately manage QEMU, libvirt, Docker containers,
and ad-hoc scripts. It provides:

- **Image pipeline** -- Build slim, unattended Windows images with VirtIO
  drivers, guest tools, and optional bloatware removal (tiny11-style).
  Supports both x86_64 and ARM64 (with WOA driver injection).

- **Incus profiles** -- Pre-tuned VM configurations for Windows desktop and
  server workloads, with Hyper-V enlightenments (x86_64) and ARM-specific
  KVM tuning.

- **RemoteApp integration** -- Launch individual Windows applications as
  seamless Linux windows via FreeRDP RemoteApp. Generates `.desktop` files
  so Windows apps appear in your Linux application menu.

- **Unified CLI** (`iwt`) -- Single command to build images, create VMs,
  manage profiles, and launch apps.

## Architecture

```
┌──────────────────────────────────────────────────┐
│  iwt CLI                                         │
│  iwt image build | vm create | remoteapp launch  │
└────────────────────────┬─────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────┐
│  Incus (VM lifecycle, networking, storage)        │
│  Profiles: windows-desktop, windows-server        │
└────────────────────────┬─────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────┐
│  Image Pipeline                                   │
│  ISO extraction → slim → driver injection →       │
│  answer file → guest tools → repack               │
└────────────────────────┬─────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────┐
│  Windows Guest                                    │
│  incus-agent · WinFsp · RDP/RemoteApp enabled     │
└──────────────────────────────────────────────────┘
```

## Prerequisites

```
iwt doctor
```

Required:
- Incus (with incusd running)
- QEMU (qemu-img)
- KVM (/dev/kvm)
- curl
- xfreerdp3 (for RemoteApp)

Optional:
- wimlib-imagex (for `--slim` image builds)
- mkisofs or xorriso (for ISO repacking)
- shellcheck (for development)

## Quick Start

```bash
# 1. Install profiles
iwt profiles install

# 2. Build a slim Windows image
iwt image build --iso /path/to/Win11_24H2.iso --slim

# 3. Create and start a VM
iwt vm create --name win11 --image windows-modified.iso
iwt vm start win11

# 4. Open a full desktop session
iwt vm rdp win11

# 5. Or launch a single app as a seamless Linux window
iwt remoteapp launch notepad

# 6. Generate .desktop entries for your Linux app menu
iwt remoteapp install
```

### ARM64 (Raspberry Pi, etc.)

```bash
iwt image build --iso /path/to/Win11_ARM.iso --arch arm64 \
    --woa-drivers /path/to/WOA-Drivers --slim

iwt vm create --name win11-arm
iwt vm start win11-arm
```

## Project Structure

```
incus-windows-toolkit/
├── cli/
│   └── iwt.sh                  # Main CLI entrypoint
├── image-pipeline/
│   ├── scripts/
│   │   └── build-image.sh      # Image build script
│   ├── answer-files/            # Unattend XML templates
│   └── drivers/                 # Custom driver staging
├── profiles/
│   ├── x86_64/
│   │   ├── windows-desktop.yaml
│   │   └── windows-server.yaml
│   └── arm64/
│       └── windows-desktop.yaml
├── remoteapp/
│   ├── backend/
│   │   ├── incus-backend.sh    # Incus VM operations
│   │   └── launch-app.sh       # App launcher
│   └── freedesktop/
│       ├── generate-desktop-entries.sh
│       └── apps.conf           # App definitions
├── Makefile
└── README.md
```

## Install

```bash
git clone https://github.com/youruser/incus-windows-toolkit
cd incus-windows-toolkit
sudo make install
```

Or run directly without installing:

```bash
./cli/iwt.sh doctor
```

## Lineage

This project unifies ideas from:

| Concern | Prior Art |
|---|---|
| VM orchestration | [quickemu](https://github.com/quickemu-project/quickemu), [bvm](https://github.com/Botspot/bvm) |
| Incus Windows images | [incus-windows](https://github.com/antifob/incus-windows) |
| Seamless Windows apps | [winapps](https://github.com/Fmstrat/winapps), [winboat](https://github.com/TibixDev/winboat) |
| Image slimming | [tiny11builder](https://github.com/ntdevlabs/tiny11builder) |
| Guest filesystem | [winfsp](https://github.com/winfsp/winfsp) |
| ARM drivers | [WOA-Drivers](https://github.com/edk2-porting/WOA-Drivers) |

## License

Apache-2.0

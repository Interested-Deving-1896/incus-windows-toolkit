% IWT(1) IWT User Manual
% Incus Windows Toolkit Contributors
% 2024

# NAME

iwt - Incus Windows Toolkit

# SYNOPSIS

**iwt** *command* [*subcommand*] [*options*]

# DESCRIPTION

IWT is a unified CLI for creating, managing, and running Windows virtual machines on Incus (Linux container and VM manager). It handles the full lifecycle from ISO download through image building, VM creation, guest tool installation, GPU/USB passthrough, shared folders, RemoteApp, snapshots, and backup/export.

Supports both x86_64 and ARM64 architectures.

# COMMANDS

**image** *subcommand*
:   Build and download Windows images. Subcommands: download, build, drivers, list.

**vm** *subcommand*
:   Manage Windows VMs. Subcommands: create, start, stop, status, list, rdp, setup-guest, template, backup, export, import, first-boot, snapshot, share, gpu, usb, net.

**profiles** *subcommand*
:   Install and manage Incus VM profiles. Subcommands: install, list, show, validate.

**remoteapp** *subcommand*
:   Launch Windows apps as seamless Linux windows. Subcommands: launch, install, discover, config.

**tui**
:   Launch interactive terminal UI (requires dialog or whiptail).

**doctor**
:   Check system prerequisites and suggest fixes.

**config** *subcommand*
:   Manage IWT configuration. Subcommands: init, show, edit, path.

**version**
:   Show version.

# VM TEMPLATES

Create VMs from presets with tuned resources and first-boot scripts:

    iwt vm create --template gaming --name my-vm
    iwt vm create --template dev --name dev-vm
    iwt vm create --template server --name srv
    iwt vm create --template minimal --name test

# EXAMPLES

Download and build a Windows 11 image:

    iwt image download --version 11
    iwt image build --iso Win11.iso --slim --inject-drivers

Create and start a VM:

    iwt vm create --template gaming --name win11
    iwt vm start win11
    iwt vm setup-guest --vm win11
    iwt vm rdp win11

Manage snapshots:

    iwt vm snapshot create --name pre-update
    iwt vm snapshot restore pre-update

GPU passthrough:

    iwt vm gpu attach --pci 01:00.0
    iwt vm gpu status

Backup and export:

    iwt vm backup create win11
    iwt vm export win11 --alias my-base-image

# FILES

**~/.config/iwt/config**
:   User configuration file.

**~/.cache/iwt/**
:   Cached downloads (VirtIO drivers, ISOs).

**~/.local/share/iwt/backups/**
:   VM backup storage.

# ENVIRONMENT

**IWT_VM_NAME**
:   Default VM name (default: "windows").

**IWT_CONFIG_FILE**
:   Override config file path.

**IWT_CACHE_DIR**
:   Override cache directory.

**IWT_BACKUP_DIR**
:   Override backup directory.

# SEE ALSO

incus(1), qemu-img(1), xfreerdp3(1)

# BUGS

Report bugs at: https://gitlab.com/OSPF1896/incus-windows-toolkit/issues

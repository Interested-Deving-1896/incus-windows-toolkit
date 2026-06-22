[update-readmes]   Mode: rewrite — migrating to template structure...
# incus-windows-toolkit

[![Built with Ona](https://ona.com/build-with-ona.svg)](https://app.ona.com/#https://github.com/Interested-Deving-1896/incus-windows-toolkit)

<!-- AI:start:what-it-does -->
This project provides a toolkit for managing Windows virtual machines on Incus, a container and virtual machine manager based on QEMU/KVM. It addresses the need for efficient VM storage and performance by integrating Btrfs for host storage, WinBtrfs for guest filesystem support, and DwarFS for image compression. It is used by developers and system administrators working with Windows VMs in Linux-based environments.
<!-- AI:end:what-it-does -->

## Architecture

<!-- AI:start:architecture -->
The toolkit consists of several components for managing Windows VMs on Incus. The `cli` directory contains shell scripts for command-line operations, including the main `iwt.sh` script and supporting libraries. The `image-pipeline` directory provides scripts for building VM images, downloading ISOs, and managing drivers. The `profiles` directory contains YAML configuration files for VM profiles, with validation scripts. The `tests` directory includes unit and integration tests. Documentation is stored in `doc` and `docs`. The Makefile defines tasks for building, testing, installing, and cleaning the project. The toolkit interacts with Incus for VM management, Btrfs for storage, WinBtrfs for guest filesystem support, and DwarFS for image compression.

```plaintext
.
├── cli
│   ├── iwt.sh
│   ├── lib.sh
│   ├── backup.sh
├── doc
│   └── iwt.1.md
├── image-pipeline
│   ├── scripts
│   │   ├── build-image.sh
│   │   ├── download-iso.sh
│   │   ├── manage-drivers.sh
│   ├── answer-files
│   ├── drivers
├── profiles
│   ├── validate.sh
├── tests
│   ├── run-tests.sh
├── Makefile
├── README.md
├── LICENSE
└── .github
```
<!-- AI:end:architecture -->

## Install


### From source

```bash
git clone https://gitlab.com/openos-project/incus_deving/incus-windows-toolkit
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

## Usage

<!-- Add usage examples here. This section is yours — the AI will not modify it. -->

## Configuration


```bash
iwt config init    # create ~/.config/iwt/config
iwt config edit    # open in $EDITOR
iwt config show    # display current config
```

Environment variables: `IWT_VM_NAME`, `IWT_CONFIG_FILE`, `IWT_CACHE_DIR`, `IWT_BACKUP_DIR`

## CI

<!-- AI:start:ci -->
The repository uses GitHub Actions for continuous integration and automation. Below are the workflows and their purposes:

- **ci.yaml**: Runs linting, unit tests, and integration tests. No secrets required.
- **mirror-osp-to-ooc.yaml**: Mirrors the repository from the upstream open-source project (OSP) to an out-of-cluster (OOC) repository. Requires `MIRROR_OOC_TOKEN` secret.
- **mirror.yaml**: Mirrors the repository to other remotes. Requires `MIRROR_TOKEN` secret.
- **release.yaml**: Automates the release process, including tagging and artifact generation. Requires `RELEASE_TOKEN` secret.
- **trigger-artifact-mirror.yml**: Triggers artifact mirroring workflows in other repositories. Requires `ARTIFACT_MIRROR_TOKEN` secret.

Secrets are configured in the repository settings under "Settings > Secrets and variables > Actions".
<!-- AI:end:ci -->

## Mirror chain

<!-- AI:start:mirror-chain -->
This repo is maintained in [`Interested-Deving-1896/incus-windows-toolkit`](https://github.com/Interested-Deving-1896/incus-windows-toolkit) and mirrored through:

```
Interested-Deving-1896/incus-windows-toolkit  ──►  OpenOS-Project-OSP/incus-windows-toolkit  ──►  OpenOS-Project-Ecosystem-OOC/incus-windows-toolkit
```

Changes flow downstream automatically via the hourly mirror chain in
[`fork-sync-all`](https://github.com/Interested-Deving-1896/fork-sync-all).
Direct commits to OSP or OOC are detected and opened as PRs back to `Interested-Deving-1896`.
<!-- AI:end:mirror-chain -->

## Contributors

<!-- AI:start:contributors -->
[@Interested-Deving-1896](https://github.com/Interested-Deving-1896): 29 commits  
[@ona-agent](https://github.com/ona-agent): 6 commits  
[@actions-user](https://github.com/actions-user): 1 commit  

*Note: This repository is a mirror. Please refer to the upstream source for additional contributions and updates.*
<!-- AI:end:contributors -->

## Origins

<!-- AI:start:origins -->

Original project — toolkit for running and managing Windows VMs on Incus (QEMU/KVM) with Btrfs storage.

| Origin | Host | Fork in I-D-1896 |
|--------|------|-----------------|
| [lxc/incus](https://github.com/lxc/incus) | GitHub | ✅ |
<!-- AI:end:origins -->

## Resources

<!-- AI:start:resources -->
| File | Description |
|---|---|
| [dep-graph/origins.md](https://github.com/Interested-Deving-1896/incus-windows-toolkit/blob/main/dep-graph/origins.md) | Dependency graph (Markdown table) |
<!-- AI:end:resources -->

## License

<!-- AI:start:license -->
[Apache-2.0](https://github.com/Interested-Deving-1896/incus-windows-toolkit/blob/main/LICENSE) © 2026 [Interested-Deving-1896](https://github.com/Interested-Deving-1896)
<!-- AI:end:license -->

[update-readmes]   Mode: rewrite — migrating to template structure...
# incus-windows-toolkit

[![Built with Ona](https://ona.com/build-with-ona.svg)](https://app.ona.com/#https://github.com/Interested-Deving-1896/incus-windows-toolkit)

<!-- AI:start:what-it-does -->
This project provides a toolkit for managing Windows virtual machines on Incus, a container and virtual machine manager based on QEMU/KVM. It addresses the setup and maintenance of Windows VMs by integrating Btrfs storage, WinBtrfs guest drivers, and DwarFS image compression. It is used by system administrators and developers working with Incus to streamline VM lifecycle management and optimize storage efficiency.
<!-- AI:end:what-it-does -->

## Architecture

<!-- AI:start:architecture -->
The Incus Windows Toolkit consists of several components for managing Windows virtual machines on Incus. The main components include:

1. **CLI Tools**: Located in the `cli` directory, these scripts handle VM lifecycle operations, backups, and configuration management.
2. **Image Pipeline**: Found in `image-pipeline`, this contains scripts for building VM images, downloading ISOs, managing drivers, and handling compressed image formats with DwarFS.
3. **Profiles**: The `profiles` directory contains YAML files for VM configurations and a validation script.
4. **Tests**: The `tests` directory includes unit and integration tests for verifying functionality.
5. **Documentation**: The `doc` directory holds markdown files and man page generation scripts.

The components interact through shared scripts and configuration files. The CLI tools invoke image pipeline scripts and use profiles for VM setup. The Makefile orchestrates common tasks like installation, testing, and documentation generation.

Directory structure:
```plaintext
.
├── cli
│   ├── iwt.sh
│   ├── lib.sh
│   ├── backup.sh
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
├── doc
│   ├── iwt.1.md
├── Makefile
├── README.md
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
- **mirror-osp-to-ooc.yaml**: Mirrors the repository from the upstream open-source project (OSP) to an out-of-core (OOC) repository. Requires `OSP_TOKEN` and `OOC_TOKEN` secrets.
- **mirror.yaml**: Mirrors the repository to a secondary remote. Requires `MIRROR_TOKEN` secret.
- **release.yaml**: Automates the release process, including tagging and artifact generation. Requires `RELEASE_TOKEN` secret.
- **trigger-artifact-mirror.yml**: Triggers artifact mirroring to external storage. Requires `ARTIFACT_STORAGE_KEY` secret.

Ensure all required secrets are configured in the repository settings for workflows to function correctly.
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
[@Interested-Deving-1896](https://github.com/Interested-Deving-1896): 43 commits  
[@ona-agent](https://github.com/ona-agent): 6 commits  
[@actions-user](https://github.com/actions-user): 1 commit  

*Note: This repository is a mirror. Please refer to the upstream source for the original project.*
<!-- AI:end:contributors -->

## Origins

<!-- AI:start:origins -->
_Original project — no upstream fork._
<!-- AI:end:origins -->

## Resources

<!-- AI:start:resources -->
| File | Description |
|---|---|
| [dep-graph/origins.md](https://github.com/Interested-Deving-1896/incus-windows-toolkit/blob/main/dep-graph/origins.md) | Dependency graph (Markdown table) |
<!-- AI:end:resources -->

## License

<!-- AI:start:license -->
<!-- License not detected — add a LICENSE file to this repo. -->
<!-- AI:end:license -->

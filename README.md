[update-readmes]   Mode: rewrite — migrating to template structure...
# incus-windows-toolkit

[![Built with Ona](https://ona.com/build-with-ona.svg)](https://app.ona.com/#https://github.com/Interested-Deving-1896/incus-windows-toolkit)

<!-- AI:start:what-it-does -->
_Description pending._
<!-- AI:end:what-it-does -->

## Architecture

<!-- AI:start:architecture -->
_Architecture documentation pending._
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
_CI documentation pending._
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
_Contributors pending._
<!-- AI:end:contributors -->

## Origins

<!-- AI:start:origins -->
_No dependency graph found. Run `generate-dep-graph.yml` to generate `dep-graph/origins.md`._
<!-- AI:end:origins -->

## Resources

<!-- AI:start:resources -->
_No additional resource files found._
<!-- AI:end:resources -->

## License

<!-- AI:start:license -->
[Apache-2.0](https://github.com/Interested-Deving-1896/incus-windows-toolkit/blob/main/LICENSE) © 2026 [Interested-Deving-1896](https://github.com/Interested-Deving-1896)
<!-- AI:end:license -->

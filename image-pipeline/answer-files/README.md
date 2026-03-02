# Answer Files

Place custom `autounattend.xml` templates here.

- `autounattend-x86_64.xml` -- used for x86_64 builds
- `autounattend-arm64.xml` -- used for ARM64 builds

If no architecture-specific template exists, `build-image.sh` generates a
default one with RDP enabled, local admin account, and OOBE bypass.

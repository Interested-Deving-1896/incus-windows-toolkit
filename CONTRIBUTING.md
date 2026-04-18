# Contributing to IWT

## Development Setup

```bash
git clone https://gitlab.com/OSPF1896/incus-windows-toolkit
cd incus-windows-toolkit
make test    # run unit tests + shellcheck
```

## Code Style

- Bash 4.0+ with `set -euo pipefail`
- shellcheck clean at warning level (`-S warning`)
- Functions prefixed by module (e.g., `vm_start`, `template_get`)
- Use `info`, `ok`, `warn`, `err`, `die` from `cli/lib.sh` for output

## Testing

```bash
make test          # unit tests + lint (no Incus needed)
make test-all      # includes integration tests (requires Incus)
```

Add tests for new features in `tests/run-tests.sh`. Unit tests should not require Incus or network access.

## Pull Requests

1. Fork and create a feature branch
2. Add tests for new functionality
3. Ensure `make test` passes
4. Keep commits focused — one feature per PR
5. Update help text for new commands

## Project Layout

- `cli/` — CLI entrypoint and top-level commands
- `image-pipeline/` — ISO download and image building
- `profiles/` — Incus VM profile YAML files
- `remoteapp/` — RemoteApp backend and desktop integration
- `guest/` — Guest-side setup scripts (run inside VM via agent)
- `gpu/` — Host-side GPU passthrough setup
- `templates/` — VM preset templates
- `tui/` — Interactive terminal UI
- `security/` — AppArmor profiles and hardening
- `tests/` — Test suite

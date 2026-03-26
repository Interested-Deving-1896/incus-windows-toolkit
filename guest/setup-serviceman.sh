#!/usr/bin/env bash
# Cross-platform service management for IWT host-side daemons via serviceman.
#
# serviceman (github.com/nicowillis/serviceman) is a cross-platform CLI tool
# that installs programs as system services using the native service manager:
#   - Linux: systemd (system or user), OpenRC, or SysV init
#   - macOS: launchd
#   - Windows: Windows Service Control Manager
#
# IWT uses serviceman to install host-side daemons:
#   - iwt-monitor: VM health monitoring daemon
#   - iwt-proxy:   RDP/SPICE proxy for remote access
#   - iwt-sync:    Periodic disk sync and snapshot daemon
#
# Usage:
#   setup-serviceman.sh [options]
#
# Options:
#   --check              Check serviceman availability
#   --install            Install serviceman
#   --add NAME CMD       Register CMD as service NAME
#   --remove NAME        Unregister service NAME
#   --start NAME         Start service NAME
#   --stop NAME          Stop service NAME
#   --status NAME        Show service status
#   --list               List IWT-managed services
#   --user               Use user-level service (default: system)
#   --help               Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

CHECK_ONLY=false
DO_INSTALL=false
DO_ADD=false
DO_REMOVE=false
DO_START=false
DO_STOP=false
DO_STATUS=false
DO_LIST=false

NAME=""
CMD=""
USER_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)    CHECK_ONLY=true; shift ;;
        --install)  DO_INSTALL=true; shift ;;
        --add)      DO_ADD=true; NAME="$2"; CMD="$3"; shift 3 ;;
        --remove)   DO_REMOVE=true; NAME="$2"; shift 2 ;;
        --start)    DO_START=true; NAME="$2"; shift 2 ;;
        --stop)     DO_STOP=true; NAME="$2"; shift 2 ;;
        --status)   DO_STATUS=true; NAME="$2"; shift 2 ;;
        --list)     DO_LIST=true; shift ;;
        --user)     USER_MODE=true; shift ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ "$CHECK_ONLY" == false && "$DO_INSTALL" == false && "$DO_ADD" == false && \
   "$DO_REMOVE" == false && "$DO_START" == false && "$DO_STOP" == false && \
   "$DO_STATUS" == false && "$DO_LIST" == false ]] && CHECK_ONLY=true

check_serviceman() {
    if command -v serviceman &>/dev/null; then
        ok "serviceman found: $(serviceman --version 2>/dev/null || echo 'version unknown')"
        return 0
    fi
    warn "serviceman not found (run --install)"
    return 1
}

install_serviceman() {
    info "Installing serviceman..."
    local bin_dir="${HOME}/.local/bin"
    mkdir -p "$bin_dir"

    # serviceman is distributed as a shell script or Go binary
    if command -v go &>/dev/null; then
        go install github.com/nicowillis/serviceman@latest
        ok "serviceman installed via go install"
        return
    fi

    # Download pre-built binary
    local os arch
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
    esac

    local api_url="https://api.github.com/repos/nicowillis/serviceman/releases/latest"
    local download_url
    download_url=$(curl -fsSL "$api_url" \
        | grep "browser_download_url" \
        | grep "${os}.*${arch}" \
        | head -1 \
        | cut -d'"' -f4)

    if [[ -n "$download_url" ]]; then
        curl -fsSL -o "$bin_dir/serviceman" "$download_url"
        chmod +x "$bin_dir/serviceman"
        ok "serviceman installed: $bin_dir/serviceman"
    else
        # Build from source
        info "Building serviceman from source..."
        require_cmd git "git"
        local src_dir="${IWT_BUILD_DIR:-/tmp/iwt-build}/serviceman"
        git clone --depth=1 https://github.com/nicowillis/serviceman.git "$src_dir"
        cd "$src_dir"
        go build -o "$bin_dir/serviceman" .
        ok "serviceman built: $bin_dir/serviceman"
    fi
}

_serviceman_flags() {
    local flags=()
    [[ "$USER_MODE" == true ]] && flags+=("--user")
    echo "${flags[@]}"
}

add_service() {
    require_cmd serviceman "serviceman (run --install)"
    [[ -n "$NAME" && -n "$CMD" ]] || die "Usage: --add NAME CMD"
    info "Registering service: $NAME → $CMD"
    # shellcheck disable=SC2046
    # shellcheck disable=SC2086
    serviceman add $(_serviceman_flags) --name "$NAME" -- $CMD
    ok "Service registered: $NAME"
}

remove_service() {
    require_cmd serviceman "serviceman"
    info "Removing service: $NAME"
    # shellcheck disable=SC2046
    serviceman remove $(_serviceman_flags) "$NAME"
    ok "Service removed: $NAME"
}

start_service() {
    info "Starting service: $NAME"
    if command -v systemctl &>/dev/null; then
        if [[ "$USER_MODE" == true ]]; then
            systemctl --user start "$NAME"
        else
            sudo systemctl start "$NAME"
        fi
    else
        serviceman start "$NAME" 2>/dev/null || warn "Direct start not supported — use system service manager"
    fi
    ok "Started: $NAME"
}

stop_service() {
    info "Stopping service: $NAME"
    if command -v systemctl &>/dev/null; then
        if [[ "$USER_MODE" == true ]]; then
            systemctl --user stop "$NAME"
        else
            sudo systemctl stop "$NAME"
        fi
    else
        serviceman stop "$NAME" 2>/dev/null || warn "Direct stop not supported — use system service manager"
    fi
    ok "Stopped: $NAME"
}

status_service() {
    if command -v systemctl &>/dev/null; then
        if [[ "$USER_MODE" == true ]]; then
            systemctl --user status "$NAME" --no-pager 2>/dev/null || true
        else
            systemctl status "$NAME" --no-pager 2>/dev/null || true
        fi
    else
        warn "Status check requires systemctl"
    fi
}

list_services() {
    bold "IWT-managed services:"
    local iwt_services=("iwt-monitor" "iwt-proxy" "iwt-sync")
    for svc in "${iwt_services[@]}"; do
        local state="unknown"
        if command -v systemctl &>/dev/null; then
            state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
        fi
        printf "  %-20s %s\n" "$svc" "$state"
    done
}

# --- Main ---

if [[ "$DO_INSTALL" == true ]]; then install_serviceman; fi
if [[ "$CHECK_ONLY" == true ]]; then check_serviceman; exit 0; fi
if [[ "$DO_ADD" == true ]];     then add_service; fi
if [[ "$DO_REMOVE" == true ]];  then remove_service; fi
if [[ "$DO_START" == true ]];   then start_service; fi
if [[ "$DO_STOP" == true ]];    then stop_service; fi
if [[ "$DO_STATUS" == true ]];  then status_service; fi
if [[ "$DO_LIST" == true ]];    then list_services; fi

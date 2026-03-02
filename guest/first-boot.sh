#!/usr/bin/env bash
# Execute first-boot PowerShell scripts inside a Windows VM.
#
# Scripts can come from:
#   - VM template (stored in user.iwt.first_boot config key)
#   - User-provided script files (--script flag)
#   - Inline commands (--run flag)
#
# Usage:
#   first-boot.sh [options]
#
# Options:
#   --vm NAME       Target VM (default: $IWT_VM_NAME)
#   --script PATH   Run a PowerShell script file (can be repeated)
#   --run CMD       Run an inline PowerShell command (can be repeated)
#   --from-template Execute scripts stored by the VM template
#   --list          List pending first-boot scripts
#   --clear         Clear stored first-boot scripts
#   --help          Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
source "$IWT_ROOT/remoteapp/backend/incus-backend.sh"
load_config

SCRIPTS=()
INLINE_CMDS=()
FROM_TEMPLATE=false
LIST_ONLY=false
CLEAR_ONLY=false

# --- Argument parsing ---

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vm)            IWT_VM_NAME="$2"; shift 2 ;;
            --script)        SCRIPTS+=("$2"); shift 2 ;;
            --run)           INLINE_CMDS+=("$2"); shift 2 ;;
            --from-template) FROM_TEMPLATE=true; shift ;;
            --list)          LIST_ONLY=true; shift ;;
            --clear)         CLEAR_ONLY=true; shift ;;
            --help|-h)
                sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
                exit 0
                ;;
            *)               die "Unknown option: $1" ;;
        esac
    done

    # Default to --from-template if no scripts or commands given
    if [[ ${#SCRIPTS[@]} -eq 0 && ${#INLINE_CMDS[@]} -eq 0 && "$LIST_ONLY" == false && "$CLEAR_ONLY" == false ]]; then
        FROM_TEMPLATE=true
    fi
}

# --- Template script extraction ---

get_template_scripts() {
    local encoded
    encoded=$(incus config get "$IWT_VM_NAME" user.iwt.first_boot 2>/dev/null || echo "")

    if [[ -z "$encoded" ]]; then
        return 1
    fi

    # Decode base64 and split on separator
    local decoded
    decoded=$(echo "$encoded" | base64 -d 2>/dev/null || echo "")

    if [[ -z "$decoded" ]]; then
        return 1
    fi

    echo "$decoded"
}

list_template_scripts() {
    local scripts
    scripts=$(get_template_scripts) || {
        info "No first-boot scripts stored for $IWT_VM_NAME"
        return 0
    }

    local template
    template=$(incus config get "$IWT_VM_NAME" user.iwt.template 2>/dev/null || echo "unknown")

    bold "First-boot scripts for $IWT_VM_NAME (template: $template)"
    echo ""

    local idx=0
    local current=""
    while IFS= read -r line; do
        if [[ "$line" == "---IWT_SCRIPT_SEPARATOR---" ]]; then
            if [[ -n "$current" ]]; then
                idx=$((idx + 1))
                echo "  Script #$idx:"
                echo "$current" | sed 's/^/    /'
                echo ""
            fi
            current=""
        else
            if [[ -n "$current" ]]; then
                current="${current}
${line}"
            else
                current="$line"
            fi
        fi
    done <<< "$scripts"

    # Handle last script without trailing separator
    if [[ -n "$current" ]]; then
        idx=$((idx + 1))
        echo "  Script #$idx:"
        echo "$current" | sed 's/^/    /'
        echo ""
    fi

    info "Total: $idx script(s)"
}

# --- Script execution ---

run_ps_script() {
    local script_content="$1"
    local label="${2:-script}"

    info "Running: $label"

    # Create a wrapper that logs output
    local wrapped
    wrapped=$(cat <<PSEOF
\$ErrorActionPreference = "Continue"
\$logFile = "C:\iwt\first-boot.log"
\$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
"\$ts  IWT: Running $label" | Tee-Object -FilePath \$logFile -Append

try {
$script_content
    "\$ts  IWT: $label completed" | Tee-Object -FilePath \$logFile -Append
} catch {
    "\$ts  IWT: $label FAILED: \$_" | Tee-Object -FilePath \$logFile -Append
    Write-Host "IWT: ERROR - \$_"
}
PSEOF
)

    incus exec "$IWT_VM_NAME" -- powershell -ExecutionPolicy Bypass -Command "$wrapped" || {
        warn "Script '$label' returned non-zero exit code"
        return 0  # Don't abort on individual script failure
    }
}

run_template_scripts() {
    local scripts
    scripts=$(get_template_scripts) || {
        info "No first-boot scripts stored for $IWT_VM_NAME"
        return 0
    }

    local template
    template=$(incus config get "$IWT_VM_NAME" user.iwt.template 2>/dev/null || echo "unknown")
    info "Running first-boot scripts from template: $template"

    local idx=0
    local current=""
    while IFS= read -r line; do
        if [[ "$line" == "---IWT_SCRIPT_SEPARATOR---" ]]; then
            if [[ -n "$current" ]]; then
                idx=$((idx + 1))
                run_ps_script "$current" "template script #$idx"
            fi
            current=""
        else
            if [[ -n "$current" ]]; then
                current="${current}
${line}"
            else
                current="$line"
            fi
        fi
    done <<< "$scripts"

    # Handle last script without trailing separator
    if [[ -n "$current" ]]; then
        idx=$((idx + 1))
        run_ps_script "$current" "template script #$idx"
    fi

    ok "Executed $idx first-boot script(s)"
}

run_script_files() {
    local idx=0
    for script_path in "${SCRIPTS[@]}"; do
        [[ -f "$script_path" ]] || die "Script not found: $script_path"
        idx=$((idx + 1))
        local content
        content=$(cat "$script_path")
        run_ps_script "$content" "$(basename "$script_path")"
    done
    ok "Executed $idx script file(s)"
}

run_inline_commands() {
    local idx=0
    for cmd in "${INLINE_CMDS[@]}"; do
        idx=$((idx + 1))
        run_ps_script "$cmd" "inline command #$idx"
    done
    ok "Executed $idx inline command(s)"
}

clear_template_scripts() {
    incus config unset "$IWT_VM_NAME" user.iwt.first_boot 2>/dev/null || true
    ok "Cleared first-boot scripts for $IWT_VM_NAME"
}

# --- Store scripts for later execution ---

store_script() {
    local vm_name="$1"
    local script_content="$2"

    local existing
    existing=$(incus config get "$vm_name" user.iwt.first_boot 2>/dev/null || echo "")

    local new_content
    if [[ -n "$existing" ]]; then
        local decoded
        decoded=$(echo "$existing" | base64 -d 2>/dev/null || echo "")
        new_content="${decoded}${script_content}
---IWT_SCRIPT_SEPARATOR---
"
    else
        new_content="${script_content}
---IWT_SCRIPT_SEPARATOR---
"
    fi

    local encoded
    encoded=$(echo "$new_content" | base64 -w0)
    incus config set "$vm_name" user.iwt.first_boot="$encoded"
}

# --- Main ---

main() {
    parse_args "$@"

    echo ""
    bold "IWT First-Boot Hooks"
    info "VM: $IWT_VM_NAME"
    echo ""

    if [[ "$LIST_ONLY" == true ]]; then
        list_template_scripts
        return 0
    fi

    if [[ "$CLEAR_ONLY" == true ]]; then
        clear_template_scripts
        return 0
    fi

    # Ensure VM is running and agent is reachable
    if ! vm_is_running; then
        die "VM '$IWT_VM_NAME' is not running. Start it with: iwt vm start $IWT_VM_NAME"
    fi
    vm_wait_for_agent

    # Ensure log directory exists in guest
    incus exec "$IWT_VM_NAME" -- powershell -Command "
        if (-not (Test-Path 'C:\iwt')) { New-Item -Path 'C:\iwt' -ItemType Directory -Force | Out-Null }
    " 2>/dev/null || true

    # Execute scripts in order: template -> files -> inline
    if [[ "$FROM_TEMPLATE" == true ]]; then
        run_template_scripts
    fi

    if [[ ${#SCRIPTS[@]} -gt 0 ]]; then
        run_script_files
    fi

    if [[ ${#INLINE_CMDS[@]} -gt 0 ]]; then
        run_inline_commands
    fi

    echo ""
    ok "First-boot hooks complete"
}

main "$@"

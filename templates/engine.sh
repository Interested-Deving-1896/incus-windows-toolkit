#!/usr/bin/env bash
# Template engine for IWT VM presets.
#
# Reads YAML template files and returns parsed values for VM creation.
# Uses simple line-based parsing (no external YAML library needed).

# shellcheck source=../cli/lib.sh
source "${IWT_ROOT:?}/cli/lib.sh"

TEMPLATES_DIR="$IWT_ROOT/templates"

# --- Template discovery ---

template_list() {
    local found=false
    for tpl in "$TEMPLATES_DIR"/*.yaml; do
        [[ -f "$tpl" ]] || continue
        found=true
        local name desc
        name=$(basename "$tpl" .yaml)
        desc=$(grep '^description:' "$tpl" | head -1 | sed 's/^description:[[:space:]]*//' | tr -d '"')
        printf "  %-12s %s\n" "$name" "$desc"
    done

    if [[ "$found" == false ]]; then
        info "No templates found in $TEMPLATES_DIR"
        return 1
    fi
}

template_exists() {
    local name="$1"
    [[ -f "$TEMPLATES_DIR/${name}.yaml" ]]
}

template_path() {
    local name="$1"
    echo "$TEMPLATES_DIR/${name}.yaml"
}

# --- Template parsing ---
# Simple line-based YAML parser for our flat template format.

template_get() {
    local tpl_file="$1"
    local key="$2"
    local default="${3:-}"

    local value
    value=$(grep "^${key}:" "$tpl_file" | head -1 | sed "s/^${key}:[[:space:]]*//" | tr -d '"')

    if [[ -z "$value" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

template_get_nested() {
    local tpl_file="$1"
    local section="$2"
    local key="$3"
    local default="${4:-}"

    local in_section=false
    local value=""

    while IFS= read -r line; do
        # Detect section start
        if [[ "$line" =~ ^${section}: ]]; then
            in_section=true
            continue
        fi

        # Detect end of section (non-indented line that isn't blank/comment)
        if [[ "$in_section" == true ]] && [[ "$line" =~ ^[a-z] ]]; then
            break
        fi

        # Parse key within section
        if [[ "$in_section" == true ]]; then
            local trimmed
            trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')
            if [[ "$trimmed" =~ ^${key}: ]]; then
                value=$(echo "$trimmed" | sed "s/^${key}:[[:space:]]*//" | tr -d '"')
                break
            fi
        fi
    done < "$tpl_file"

    if [[ -z "$value" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Get list items from a section (lines starting with "  - ")
template_get_list() {
    local tpl_file="$1"
    local section="$2"

    local in_section=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^${section}: ]]; then
            in_section=true
            continue
        fi

        if [[ "$in_section" == true ]] && [[ "$line" =~ ^[a-z] ]]; then
            break
        fi

        if [[ "$in_section" == true ]]; then
            local trimmed
            trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')
            if [[ "$trimmed" =~ ^-[[:space:]] ]]; then
                echo "${trimmed#- }"
            fi
        fi
    done < "$tpl_file"
}

# Get multi-line script blocks from first_boot section
template_get_first_boot_scripts() {
    local tpl_file="$1"

    local in_section=false
    local in_block=false
    local current_script=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^first_boot: ]]; then
            in_section=true
            continue
        fi

        # End of first_boot section
        if [[ "$in_section" == true ]] && [[ ! "$line" =~ ^[[:space:]] ]] && [[ -n "$line" ]] && [[ ! "$line" =~ ^# ]]; then
            # Emit last script
            if [[ -n "$current_script" ]]; then
                echo "$current_script"
                echo "---IWT_SCRIPT_SEPARATOR---"
            fi
            break
        fi

        if [[ "$in_section" == true ]]; then
            local trimmed
            trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')

            # New block starts with "- |"
            if [[ "$trimmed" == "- |" ]]; then
                # Emit previous script if any
                if [[ -n "$current_script" ]]; then
                    echo "$current_script"
                    echo "---IWT_SCRIPT_SEPARATOR---"
                fi
                current_script=""
                in_block=true
                continue
            fi

            # Simple list item "- value"
            if [[ "$trimmed" =~ ^-[[:space:]] ]] && [[ "$in_block" == false ]]; then
                if [[ -n "$current_script" ]]; then
                    echo "$current_script"
                    echo "---IWT_SCRIPT_SEPARATOR---"
                fi
                current_script="${trimmed#- }"
                continue
            fi

            # Content within a block
            if [[ "$in_block" == true ]]; then
                # Strip 4 spaces of indentation
                local content
                content=$(echo "$line" | sed 's/^    //')
                if [[ -n "$current_script" ]]; then
                    current_script="${current_script}
${content}"
                else
                    current_script="$content"
                fi
            fi
        fi
    done < "$tpl_file"

    # Emit final script
    if [[ -n "$current_script" ]]; then
        echo "$current_script"
        echo "---IWT_SCRIPT_SEPARATOR---"
    fi
}

# Get device overrides from template
template_get_devices() {
    local tpl_file="$1"

    local in_devices=false
    local current_device=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^devices: ]]; then
            in_devices=true
            continue
        fi

        if [[ "$in_devices" == true ]] && [[ "$line" =~ ^[a-z] ]]; then
            break
        fi

        if [[ "$in_devices" == true ]]; then
            local trimmed
            trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')

            # Device name (2-space indent, ends with colon)
            if [[ "$line" =~ ^[[:space:]][[:space:]][a-z] ]] && [[ "$trimmed" =~ :$ ]]; then
                current_device="${trimmed%:}"
                continue
            fi

            # Device property (4-space indent)
            if [[ -n "$current_device" ]] && [[ "$line" =~ ^[[:space:]][[:space:]][[:space:]][[:space:]] ]]; then
                local key val
                key=$(echo "$trimmed" | cut -d: -f1)
                val=$(echo "$trimmed" | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"')
                # Expand environment variables
                val=$(eval echo "$val" 2>/dev/null || echo "$val")
                echo "${current_device}|${key}|${val}"
            fi
        fi
    done < "$tpl_file"
}

# --- Template summary ---

template_show() {
    local name="$1"
    local tpl_file
    tpl_file=$(template_path "$name")

    [[ -f "$tpl_file" ]] || die "Template not found: $name"

    local desc profile cpu mem disk gpu_overlay
    desc=$(template_get "$tpl_file" "description")
    profile=$(template_get "$tpl_file" "profile" "windows-desktop")
    cpu=$(template_get_nested "$tpl_file" "resources" "cpu" "4")
    mem=$(template_get_nested "$tpl_file" "resources" "memory" "8GiB")
    disk=$(template_get_nested "$tpl_file" "resources" "disk" "64GiB")
    gpu_overlay=$(template_get "$tpl_file" "gpu_overlay" "none")

    bold "Template: $name"
    echo ""
    echo "  Description:  $desc"
    echo "  Profile:      $profile"
    echo "  GPU overlay:  $gpu_overlay"
    echo "  CPU:          $cpu"
    echo "  Memory:       $mem"
    echo "  Disk:         $disk"

    local setup_items
    setup_items=$(template_get_list "$tpl_file" "setup_guest")
    if [[ -n "$setup_items" ]]; then
        echo "  Guest setup:  $setup_items"
    fi

    local boot_count=0
    while IFS= read -r line; do
        [[ "$line" == "---IWT_SCRIPT_SEPARATOR---" ]] && boot_count=$((boot_count + 1))
    done < <(template_get_first_boot_scripts "$tpl_file")
    if [[ "$boot_count" -gt 0 ]]; then
        echo "  First-boot:   $boot_count script(s)"
    fi
}

#!/usr/bin/env bash
# Generate .desktop files for Windows applications so they appear in
# Linux application menus (GNOME, KDE, etc.).
#
# Usage:
#   generate-desktop-entries.sh [--output-dir DIR]
#
# Reads the list of known apps from apps.conf and creates a .desktop
# file for each one in ~/.local/share/applications/iwt/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(dirname "$SCRIPT_DIR")/backend"
APPS_CONF="$SCRIPT_DIR/apps.conf"
OUTPUT_DIR="${1:-$HOME/.local/share/applications/iwt}"
ICON_DIR="$HOME/.local/share/icons/iwt"

source "$BACKEND_DIR/incus-backend.sh"

mkdir -p "$OUTPUT_DIR" "$ICON_DIR"

# --- App configuration format ---
# apps.conf: one app per line
# Format: name|exe_path|icon_name|categories
# Example: Microsoft Word|C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE|ms-word|Office;WordProcessor

if [[ ! -f "$APPS_CONF" ]]; then
    echo "No apps.conf found. Generating from VM..."

    # Auto-discover and create a starter config
    cat > "$APPS_CONF" <<'EOF'
# IWT RemoteApp Application Definitions
# Format: Display Name|Windows EXE Path|Icon Name|FreeDesktop Categories
#
# Add your applications below. Use 'iwt remoteapp discover' to auto-detect.

Notepad|C:\Windows\System32\notepad.exe|accessories-text-editor|Utility;TextEditor
Calculator|C:\Windows\System32\calc.exe|accessories-calculator|Utility;Calculator
Command Prompt|C:\Windows\System32\cmd.exe|utilities-terminal|System;TerminalEmulator
PowerShell|C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe|utilities-terminal|System;TerminalEmulator
File Explorer|C:\Windows\explorer.exe|system-file-manager|System;FileManager
EOF
    echo "Created starter apps.conf at $APPS_CONF"
    echo "Edit it to add your applications, then re-run this script."
fi

count=0
while IFS='|' read -r name exe_path icon_name categories; do
    # Skip comments and empty lines
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$name" ]] && continue

    # Sanitize name for filename
    local_name=$(echo "$name" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
    desktop_file="$OUTPUT_DIR/iwt-${local_name}.desktop"

    cat > "$desktop_file" <<EOF
[Desktop Entry]
Type=Application
Name=$name (Windows)
Comment=Windows application via IWT RemoteApp
Exec=$BACKEND_DIR/launch-app.sh "$exe_path"
Icon=${icon_name:-application-x-executable}
Categories=${categories:-Windows;}
StartupNotify=true
StartupWMClass=iwt-${local_name}
EOF

    chmod +x "$desktop_file"
    count=$((count + 1))
done < "$APPS_CONF"

# Update desktop database
if command -v update-desktop-database &>/dev/null; then
    update-desktop-database "$OUTPUT_DIR" 2>/dev/null || true
fi

echo "Generated $count .desktop entries in $OUTPUT_DIR"

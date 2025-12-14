#!/usr/bin/env bash
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$REAL_USER" | cut -d: -f6)"
DESKTOP_DIR="$HOME_DIR/.local/share/applications"
NAUTILUS_SCRIPTS_DIR="$HOME_DIR/.local/share/nautilus/scripts"
EXTENSION_DIR="$HOME_DIR/.local/share/gnome-shell/extensions"
EXTENSION_UUID="rgb-gpus-teaming@astromangaming"
PROJECT_DIR="$HOME/RGB-GPUs-Teaming.OP"

SILENT=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [--silent] [-h|--help]

Options:
  --silent    Suppress final informational messages.
  -h, --help  Show this help message and exit.

This script removes installed desktop files, Nautilus script, and the GNOME extension.
It does NOT delete the project folder by default.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --silent) SILENT=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Warning: unknown argument '$arg' (ignored)" ;;
    esac
done

echo "Uninstalling RGB-GPUs-Teaming components for user: $REAL_USER"

# Remove known .desktop files (expand if you installed more)
desktop_files=(advisor.desktop gnome-setup.desktop manual-setup.desktop all-ways-egpu-auto-setup.desktop)
for file in "${desktop_files[@]}"; do
    if [[ -f "$DESKTOP_DIR/$file" ]]; then
        echo "Removing $file from applications..."
        rm -f "$DESKTOP_DIR/$file"
    fi
done

# Remove Nautilus script(s) matching project pattern
if compgen -G "$NAUTILUS_SCRIPTS_DIR/*" > /dev/null; then
    for s in "$NAUTILUS_SCRIPTS_DIR/"*; do
        case "$(basename "$s")" in
            "Launch with RGB GPUs Teaming"|"rgb-gpus-teaming"*) 
                echo "Removing Nautilus script: $(basename "$s")"
                rm -f "$s"
                ;;
        esac
    done
fi

# Disable and remove GNOME extension
if [[ -d "$EXTENSION_DIR/$EXTENSION_UUID" ]]; then
    echo "Removing GNOME extension: $EXTENSION_UUID"
    if command -v gnome-extensions &> /dev/null; then
        sudo -u "$REAL_USER" gnome-extensions disable "$EXTENSION_UUID" || true
    fi
    rm -rf "$EXTENSION_DIR/$EXTENSION_UUID"
fi

echo "RGB-GPUs-Teaming components removed."

if [[ "$SILENT" != true ]]; then
    echo "Note: The project folder '$PROJECT_DIR' has been preserved."
    echo "To completely remove RGB-GPUs-Teaming, delete the folder manually:"
    echo "→ rm -rf \"$PROJECT_DIR\""
fi

#!/usr/bin/env bash
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$REAL_USER" | cut -d: -f6)"
INSTALL_DIR="$HOME_DIR/RGB-GPUs-Teaming.OP"
DESKTOP_DIR="$HOME_DIR/.local/share/applications"
NAUTILUS_SCRIPTS_DIR="$HOME_DIR/.local/share/nautilus/scripts"
EXTENSION_DIR="$HOME_DIR/.local/share/gnome-shell/extensions"
EXTENSION_UUID="rgb-gpus-teaming@astromangaming"
EXTENSION_SRC="$INSTALL_DIR/gnome-extension/$EXTENSION_UUID"
EXTENSION_DEST="$EXTENSION_DIR/$EXTENSION_UUID"

ALL_WAYS_EGPU=false
VERBOSE=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --all-ways-egpu    Install the all-ways-egpu desktop launcher as well.
  --verbose          Print detailed progress messages.
  -h, --help         Show this help message and exit.

Notes:
  - This script copies files into the current user's local directories.
  - If run as root, files are copied for the original invoking user.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --all-ways-egpu) ALL_WAYS_EGPU=true ;;
        --verbose) VERBOSE=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Warning: unknown argument '$arg' (ignored)" ;;
    esac
done

log() { [[ "$VERBOSE" == true ]] && printf '%s\n' "$*"; }

echo "Setting up RGB-GPUs-Teaming in $INSTALL_DIR (user: $REAL_USER)"
log "Options: all-ways-egpu=$ALL_WAYS_EGPU, verbose=$VERBOSE"

mkdir -p "$DESKTOP_DIR" "$NAUTILUS_SCRIPTS_DIR" "$EXTENSION_DIR"

# Desktop files
if compgen -G "$INSTALL_DIR"/*.desktop > /dev/null; then
    echo "Installing .desktop launchers..."
    if [[ "$ALL_WAYS_EGPU" == true ]]; then
        sudo -u "$REAL_USER" cp -f "$INSTALL_DIR"/*.desktop "$DESKTOP_DIR/" || echo "Warning: failed to copy desktop files"
    else
        for file in "$INSTALL_DIR"/*.desktop; do
            [[ "$(basename "$file")" == "all-ways-egpu-auto-setup.desktop" ]] && continue
            sudo -u "$REAL_USER" cp -f "$file" "$DESKTOP_DIR/" || echo "Warning: failed to copy $file"
        done
    fi
else
    echo "No .desktop files found in $INSTALL_DIR"
fi

# Nautilus scripts
if compgen -G "$INSTALL_DIR/nautilus-scripts/*" > /dev/null; then
    echo "Installing Nautilus scripts..."
    sudo -u "$REAL_USER" cp -f "$INSTALL_DIR/nautilus-scripts/"* "$NAUTILUS_SCRIPTS_DIR/" || echo "Warning: failed to copy nautilus scripts"
    sudo -u "$REAL_USER" chmod +x "$NAUTILUS_SCRIPTS_DIR/"* || true
else
    echo "No Nautilus scripts found in $INSTALL_DIR/nautilus-scripts"
fi

# GNOME extension
if [[ -d "$EXTENSION_SRC" ]]; then
    echo "Installing GNOME extension: $EXTENSION_UUID"
    sudo -u "$REAL_USER" mkdir -p "$EXTENSION_DEST"
    sudo -u "$REAL_USER" cp -r "$EXTENSION_SRC/"* "$EXTENSION_DEST/" || echo "Warning: failed to copy extension files"
    if command -v gnome-extensions &> /dev/null; then
        sudo -u "$REAL_USER" gnome-extensions enable "$EXTENSION_UUID" || echo "Warning: failed to enable extension"
        echo "GNOME extension '$EXTENSION_UUID' enabled."
    else
        echo "Warning: 'gnome-extensions' CLI not found. Extension copied but not enabled."
    fi
else
    echo "GNOME extension folder not found: $EXTENSION_SRC"
fi

echo "Setup complete."

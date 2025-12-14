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

# Basic checks
if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Error: installation directory not found: $INSTALL_DIR" >&2
    echo "Clone the repository into $INSTALL_DIR or run this script from the correct account." >&2
    exit 2
fi

# Ensure target dirs exist
mkdir -p "$DESKTOP_DIR" "$NAUTILUS_SCRIPTS_DIR" "$EXTENSION_DIR"

# Helper: run a command as the real user if running as root, otherwise run normally
run_as_user() {
    if [[ "$(id -u)" -eq 0 && "$REAL_USER" != "root" ]]; then
        sudo -u "$REAL_USER" -- "$@"
    else
        "$@"
    fi
}

# Use nullglob so patterns with no matches expand to nothing
shopt -s nullglob

# Desktop files
desktop_files=("$INSTALL_DIR"/*.desktop)
if (( ${#desktop_files[@]} )); then
    echo "Installing .desktop launchers..."
    for file in "${desktop_files[@]}"; do
        base="$(basename "$file")"
        if [[ "$ALL_WAYS_EGPU" != true && "$base" == "all-ways-egpu-auto-setup.desktop" ]]; then
            log "Skipping $base (all-ways-egpu not requested)"
            continue
        fi
        dest="$DESKTOP_DIR/$base"
        # Copy and set permissions, ensure ownership for the real user
        cp -f "$file" "$dest"
        chmod 644 "$dest"
        if [[ "$(id -u)" -eq 0 && "$REAL_USER" != "root" ]]; then
            chown "$REAL_USER":"$REAL_USER" "$dest" || true
        fi
        log "Installed $dest"
    done
else
    echo "No .desktop files found in $INSTALL_DIR"
fi

# Nautilus scripts
nautilus_files=("$INSTALL_DIR/nautilus-scripts"/*)
if (( ${#nautilus_files[@]} )); then
    echo "Installing Nautilus scripts..."
    for s in "${nautilus_files[@]}"; do
        dest="$NAUTILUS_SCRIPTS_DIR/$(basename "$s")"
        cp -f "$s" "$dest"
        chmod 755 "$dest"
        if [[ "$(id -u)" -eq 0 && "$REAL_USER" != "root" ]]; then
            chown "$REAL_USER":"$REAL_USER" "$dest" || true
        fi
        log "Installed Nautilus script $dest"
    done
else
    echo "No Nautilus scripts found in $INSTALL_DIR/nautilus-scripts"
fi

# GNOME extension
if [[ -d "$EXTENSION_SRC" ]]; then
    echo "Installing GNOME extension: $EXTENSION_UUID"
    # Copy files as the real user
    if [[ -d "$EXTENSION_DEST" ]]; then
        rm -rf "$EXTENSION_DEST"
    fi
    cp -r "$EXTENSION_SRC" "$EXTENSION_DEST"
    # Ensure ownership and permissions
    if [[ "$(id -u)" -eq 0 && "$REAL_USER" != "root" ]]; then
        chown -R "$REAL_USER":"$REAL_USER" "$EXTENSION_DEST" || true
    fi
    log "Copied extension to $EXTENSION_DEST"

    # Try to enable the extension as the real user
    if command -v gnome-extensions &> /dev/null; then
        echo "Attempting to enable GNOME extension (may require a running user session)..."
        if [[ "$(id -u)" -eq 0 && "$REAL_USER" != "root" ]]; then
            # Try enabling via sudo -u; this often fails if no session DBUS is available
            if sudo -u "$REAL_USER" -- gnome-extensions enable "$EXTENSION_UUID"; then
                echo "GNOME extension '$EXTENSION_UUID' enabled."
            else
                echo "Warning: enabling extension via CLI likely failed (no session DBUS)."
                echo "To enable it in the user's session, run as the user inside their session:"
                echo "  gnome-extensions enable $EXTENSION_UUID"
            fi
        else
            if gnome-extensions enable "$EXTENSION_UUID"; then
                echo "GNOME extension '$EXTENSION_UUID' enabled."
            else
                echo "Warning: failed to enable extension via CLI. You may need to enable it in GNOME Extensions app."
            fi
        fi
    else
        echo "Warning: 'gnome-extensions' CLI not found. Extension copied but not enabled."
        echo "Enable it in the GNOME Extensions app or install the CLI (gnome-shell-extension-prefs / gnome-extensions)."
    fi
else
    echo "GNOME extension folder not found: $EXTENSION_SRC"
fi

# Restore shell options
shopt -u nullglob

echo "Setup complete."
echo "If something didn't work, re-run with --verbose and check the printed messages."

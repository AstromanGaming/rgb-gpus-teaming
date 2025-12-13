#!/bin/bash

INSTALL_DIR="$HOME/RGB-GPUs-Teaming.OP"
DESKTOP_DIR="$HOME/.local/share/applications"
NAUTILUS_SCRIPTS_DIR="$HOME/.local/share/nautilus/scripts"
EXTENSION_DIR="$HOME/.local/share/gnome-shell/extensions"
EXTENSION_UUID="rgb-gpus-teaming@astromangaming"
EXTENSION_SRC="$INSTALL_DIR/gnome-extension/$EXTENSION_UUID"
EXTENSION_DEST="$EXTENSION_DIR/$EXTENSION_UUID"

ALL_WAYS_EGPU=false

for arg in "$@"; do
    if [[ "$arg" == "--all-ways-egpu" ]]; then
        ALL_WAYS_EGPU=true
        break
    fi
done

if [[ "$ALL_WAYS_EGPU" == true ]]; then
    echo "Setting up RGB-GPUs-Teaming (with all-ways-egpu addon) from $INSTALL_DIR..."
else
    echo "Setting up RGB-GPUs-Teaming from $INSTALL_DIR..."
fi

# Install .desktop launchers
if compgen -G "$INSTALL_DIR/*.desktop" > /dev/null; then
    echo "Installing .desktop launchers..."
    mkdir -p "$DESKTOP_DIR"

    if [[ "$ALL_WAYS_EGPU" == true ]]; then
        cp "$INSTALL_DIR"/*.desktop "$DESKTOP_DIR/"
    else
        for file in "$INSTALL_DIR"/*.desktop; do
            if [[ "$(basename "$file")" != "all-ways-egpu-auto-setup.desktop" ]]; then
                cp "$file" "$DESKTOP_DIR/"
            fi
        done
    fi
fi

# Install Nautilus scripts
if compgen -G "$INSTALL_DIR/nautilus-scripts/*" > /dev/null; then
    echo "Installing Nautilus scripts..."
    mkdir -p "$NAUTILUS_SCRIPTS_DIR"
    cp "$INSTALL_DIR/nautilus-scripts/"* "$NAUTILUS_SCRIPTS_DIR/"
    chmod +x "$NAUTILUS_SCRIPTS_DIR/"*
fi

# Install GNOME extension
if [[ -d "$EXTENSION_SRC" ]]; then
    echo "Installing GNOME extension: $EXTENSION_UUID"
    mkdir -p "$EXTENSION_DEST"
    cp -r "$EXTENSION_SRC/"* "$EXTENSION_DEST/"

    if command -v gnome-extensions &> /dev/null; then
        gnome-extensions enable "$EXTENSION_UUID"
        echo "GNOME extension '$EXTENSION_UUID' enabled."
    else
        echo "Warning: 'gnome-extensions' CLI not found. Extension copied but not enabled."
    fi
else
    echo "GNOME extension folder not found: $EXTENSION_SRC"
fi

echo "Setup complete."

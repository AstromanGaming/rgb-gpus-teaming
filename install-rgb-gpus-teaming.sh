#!/bin/bash

INSTALL_DIR="$HOME/rgb-gpus-teaming"
DESKTOP_DIR="$HOME/.local/share/applications"
NAUTILUS_SCRIPTS_DIR="$HOME/.local/share/nautilus/scripts"
EXTENSION_DIR="$HOME/.local/share/gnome-shell/extensions"
EXTENSION_UUID="rgb-gpus-teaming@astromangaming"
EXTENSION_SRC="$INSTALL_DIR/gnome-extension/$EXTENSION_UUID"
EXTENSION_DEST="$EXTENSION_DIR/$EXTENSION_UUID"

echo "Setting up rgb-gpus-teaming from $INSTALL_DIR..."

# Install .desktop launchers
if compgen -G "$INSTALL_DIR/*.desktop" > /dev/null; then
    echo "Installing .desktop launchers..."
    mkdir -p "$DESKTOP_DIR"
    cp "$INSTALL_DIR"/*.desktop "$DESKTOP_DIR/"
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

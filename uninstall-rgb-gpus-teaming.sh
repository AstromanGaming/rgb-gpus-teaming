#!/bin/bash

DESKTOP_DIR="$HOME/.local/share/applications"
NAUTILUS_SCRIPTS_DIR="$HOME/.local/share/nautilus/scripts"
EXTENSION_DIR="$HOME/.local/share/gnome-shell/extensions"
EXTENSION_UUID="rgb-gpus-teaming@astromangaming"
PROJECT_DIR="$HOME/rgb-gpus-teaming"
NAUTILUS_SCRIPT_NAME="Launch with RGB GPUs Teaming"

echo "Uninstalling rgb-gpus-teaming components..."

# Remove known .desktop files
for file in advisor.desktop gnome-setup.desktop manual-setup.desktop; do
    if [[ -f "$DESKTOP_DIR/$file" ]]; then
        echo "Removing $file from applications..."
        rm -f "$DESKTOP_DIR/$file"
    fi
done

# Remove specific Nautilus script
if [[ -f "$NAUTILUS_SCRIPTS_DIR/$NAUTILUS_SCRIPT_NAME" ]]; then
    echo "Removing Nautilus script: $NAUTILUS_SCRIPT_NAME"
    rm -f "$NAUTILUS_SCRIPTS_DIR/$NAUTILUS_SCRIPT_NAME"
fi

# Disable and remove GNOME extension
if [[ -d "$EXTENSION_DIR/$EXTENSION_UUID" ]]; then
    echo "Removing GNOME extension: $EXTENSION_UUID"
    if command -v gnome-extensions &> /dev/null; then
        gnome-extensions disable "$EXTENSION_UUID"
    fi
    rm -rf "$EXTENSION_DIR/$EXTENSION_UUID"
fi

echo "rgb-gpus-teaming has been uninstalled from your system."

echo "Note: The project folder '$PROJECT_DIR' has been preserved."
echo "To completely remove rgb-gpus-teaming, delete the folder manually:"
echo "→ rm -rf \"$PROJECT_DIR\""

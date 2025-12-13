#!/bin/bash

INSTALL_DIR="$HOME/RGB-GPUs-Teaming.OP"
INSTALL_SCRIPT="$INSTALL_DIR/install-rgb-gpus-teaming.sh"
UNINSTALL_SCRIPT="$INSTALL_DIR/uninstall-rgb-gpus-teaming.sh"

echo "Updating RGB-GPUs-Teaming..."

# Check if the installation directory exists
if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Error: $INSTALL_DIR does not exist. Please clone the repository first."
    exit 1
fi

# Pull latest changes if it's a Git repository
if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo "Pulling latest changes from Git..."
    git -C "$INSTALL_DIR" pull --quiet
else
    echo "Warning: $INSTALL_DIR is not a Git repository. Skipping git pull."
fi

# Run uninstall script silently
if [[ -x "$UNINSTALL_SCRIPT" ]]; then
    echo "Uninstalling previous installation..."
    bash "$UNINSTALL_SCRIPT" --silent
else
    echo "Warning: Uninstall script not found or not executable: $UNINSTALL_SCRIPT"
fi

# Run install script
if [[ -x "$INSTALL_SCRIPT" ]]; then
    echo "Reinstalling RGB-GPUs-Teaming..."
    bash "$INSTALL_SCRIPT"
else
    echo "Error: Install script not found or not executable: $INSTALL_SCRIPT"
    exit 1
fi

echo "Update and reinstall complete."

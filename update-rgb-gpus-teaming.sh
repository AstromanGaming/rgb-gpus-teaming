#!/bin/bash

INSTALL_DIR="$HOME/rgb-gpus-teaming"
INSTALL_SCRIPT="$INSTALL_DIR/install-rgb-gpus-teaming.sh"

echo "Upgrading rgb-gpus-teaming..."

# Check if installation exists
if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Error: $INSTALL_DIR does not exist. Clone the repository first."
    exit 1
fi

# Pull latest changes if it's a Git repo
if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo "Pulling latest changes from Git..."
    git -C "$INSTALL_DIR" pull --quiet
else
    echo "Warning: $INSTALL_DIR is not a Git repository. Skipping git pull."
fi

# Reapply installation steps
if [[ -x "$INSTALL_SCRIPT" ]]; then
    echo "Running install script..."
    bash "$INSTALL_SCRIPT"
else
    echo "Error: Install script not found or not executable: $INSTALL_SCRIPT"
    exit 1
fi

echo "Upgrade complete."

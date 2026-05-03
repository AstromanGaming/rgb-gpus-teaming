#!/bin/bash
set -e

# Detect the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== RGB-GPUs-Teaming — Building .deb packages ==="
echo "Script directory: $SCRIPT_DIR"
echo

# Remove old .deb files
echo "[1/4] Removing old .deb packages..."
rm -f "$SCRIPT_DIR"/*.deb

echo "[2/4] Building main package..."
sudo fpm -s dir -t deb \
  -n rgb-gpus-teaming \
  -v 1.0.0-vulkan \
  --after-remove "$SCRIPT_DIR/prerm1.sh" \
  --after-install "$SCRIPT_DIR/postinst1.sh" \
  --vendor "AstromanGaming" \
  --maintainer "Sam Bélanger <contact@astromangaming.ca>" \
  --license "MIT" \
  --url "https://github.com/AstromanGaming/rgb-gpus-teaming" \
  --description "A software for Multi-GPUs setup" \
  --architecture amd64 \
  --depends mesa-utils \
  --depends vulkan-tools \
  "$SCRIPT_DIR/prerm1.sh=/opt/rgb-gpus-teaming/" \
  "$SCRIPT_DIR/postinst1.sh=/opt/rgb-gpus-teaming/" \
  "$SCRIPT_DIR/advisor.desktop=/usr/share/applications/" \
  "$SCRIPT_DIR/advisor.sh=/opt/rgb-gpus-teaming/" \
  "$SCRIPT_DIR/gnome-launcher.sh=/opt/rgb-gpus-teaming/" \
  "$SCRIPT_DIR/gnome-setup.desktop=/usr/share/applications/" \
  "$SCRIPT_DIR/gnome-setup.sh=/opt/rgb-gpus-teaming/" \
  "$SCRIPT_DIR/LICENSE=/opt/rgb-gpus-teaming/" \
  "$SCRIPT_DIR/manual-setup.desktop=/usr/share/applications/" \
  "$SCRIPT_DIR/manual-setup.sh=/opt/rgb-gpus-teaming/" \
  "$SCRIPT_DIR/gnome-extension/=/usr/share/gnome-shell/extensions/" \
  "$SCRIPT_DIR/nautilus-scripts/=/usr/share/nautilus/scripts/"

echo "[3/4] Building eGPU addon package..."
sudo fpm -s dir -t deb \
  -n rgb-gpus-teaming-egpu \
  -v 1.0.0-vulkan \
  --before-remove "$SCRIPT_DIR/prerm2.sh" \
  --after-install "$SCRIPT_DIR/postinst2.sh" \
  --vendor "AstromanGaming" \
  --maintainer "Sam Bélanger <contact@astromangaming.ca>" \
  --license "MIT" \
  --url "https://github.com/AstromanGaming/rgb-gpus-teaming" \
  --description "A software for Multi-GPUs setup (all-ways-egpu Addon)" \
  --architecture amd64 \
  --depends rgb-gpus-teaming \
  --depends curl \
  --depends unzip \
  "$SCRIPT_DIR/prerm2.sh=/opt/rgb-gpus-teaming/" \
  "$SCRIPT_DIR/postinst2.sh=/opt/rgb-gpus-teaming/" \
  "$SCRIPT_DIR/all-ways-egpu-auto-setup.desktop=/usr/share/applications/" \
  "$SCRIPT_DIR/all-ways-egpu-auto-setup.sh=/opt/rgb-gpus-teaming/"

echo
echo "=== Build completed successfully ==="
echo "Generated packages are located in: $SCRIPT_DIR"

#!/bin/bash
set -e

echo "[rgb-gpus-teaming-egpu] postinst: starting"

# Ensure required tools exist; fail early with clear message if missing
if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required but not installed. Aborting." >&2
  exit 1
fi
if ! command -v unzip >/dev/null 2>&1; then
  echo "unzip is required but not installed. Aborting." >&2
  exit 1
fi

TMPDIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

cd "$TMPDIR"
echo "[rgb-gpus-teaming-egpu] Downloading all-ways-egpu..."
curl -qLs https://github.com/ewagner12/all-ways-egpu/releases/latest/download/all-ways-egpu.zip -o all-ways-egpu.zip

echo "[rgb-gpus-teaming-egpu] Extracting..."
unzip -o all-ways-egpu.zip >/dev/null 2>&1 || true

if [ -d all-ways-egpu-main ]; then
  cd all-ways-egpu-main
  if [ -f install.sh ]; then
    chmod +x install.sh
    echo "[rgb-gpus-teaming-egpu] Running installer (this may require network and user interaction)..."
    # Run installer as root (original behavior). If you prefer to run as the original user, change to runuser -u "$SUDO_USER" -- ./install.sh
    ./install.sh || echo "[rgb-gpus-teaming-egpu] Warning: all-ways-egpu installer returned non-zero exit code; continuing."
  else
    echo "[rgb-gpus-teaming-egpu] install.sh not found in archive; skipping installer."
  fi
else
  echo "[rgb-gpus-teaming-egpu] Extraction failed or archive layout changed; skipping installer."
fi

echo "[rgb-gpus-teaming-egpu] Cleaning up"
# cleanup handled by trap

echo "[rgb-gpus-teaming-egpu] postinst: done"
exit 0

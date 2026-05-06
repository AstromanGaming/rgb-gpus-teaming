#!/bin/bash
# Run before package removal to uninstall all-ways-egpu if present.
# Best-effort: never fail dpkg (always exit 0).
set -e

echo "[rgb-gpus-teaming-egpu] prerm: starting"

# dpkg passes an action as first arg (remove, purge, upgrade, etc.)
ACTION="$1"

# Only run uninstall on actual removal/purge, not on upgrade
if [ "$ACTION" = "upgrade" ] || [ "$ACTION" = "abort-upgrade" ] || [ "$ACTION" = "deconfigure" ]; then
  echo "[rgb-gpus-teaming-egpu] prerm: action is '$ACTION' — skipping uninstall (upgrade path)."
  exit 0
fi

# Determine original interactive user if available
USER_NAME="${SUDO_USER:-$(logname 2>/dev/null || true)}"

# Helper to run a command as the original user (best-effort)
run_as_user() {
  local cmd="$1"
  if [ -n "$USER_NAME" ] && command -v runuser >/dev/null 2>&1; then
    runuser -u "$USER_NAME" -- bash -c "$cmd"
  elif [ -n "$USER_NAME" ] && command -v sudo >/dev/null 2>&1; then
    sudo -u "$USER_NAME" bash -c "$cmd"
  else
    # fallback to root
    bash -c "$cmd"
  fi
}

# Try to run the uninstall command if available in PATH
echo "[rgb-gpus-teaming-egpu] Attempting to run 'all-ways-egpu uninstall' (best-effort)..."

# If the command exists in PATH for root, run it; otherwise try as user
if command -v all-ways-egpu >/dev/null 2>&1; then
  # run as user if possible, else as root
  run_as_user "all-ways-egpu uninstall" || echo "[rgb-gpus-teaming-egpu] Warning: 'all-ways-egpu uninstall' returned non-zero (ignored)."
else
  # maybe installed under /opt or other known location; try common locations
  if [ -x "/usr/share/all-ways-egpu/uninstall.sh" ]; then
    run_as_user "cd /usr/share/all-ways-egpu && ./uninstall.sh" || echo "[rgb-gpus-teaming-egpu] Warning: uninstall.sh returned non-zero (ignored)."
  elif [ -x "/usr/share/all-ways-egpu/install.sh" ]; then
    # no uninstall script but install.sh exists — try a best-effort removal of the folder
    echo "[rgb-gpus-teaming-egpu] No uninstall command found; removing /usr/share/all-ways-egpu (best-effort)."
    rm -rf /usr/share/all-ways-egpu || echo "[rgb-gpus-teaming-egpu] Warning: failed to remove /usr/share/all-ways-egpu (ignored)."
  else
    echo "[rgb-gpus-teaming-egpu] No all-ways-egpu command or known install dir found; nothing to do."
  fi
fi

echo "[rgb-gpus-teaming-egpu] prerm: done"
# Always exit 0 so dpkg removal proceeds even if cleanup had issues
exit 0

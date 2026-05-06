#!/bin/bash
# Remove only configuration files for rgb-gpus-teaming on purge (best-effort).
# dpkg calls this with an action as first arg (remove, purge, upgrade, etc.)
set -e

echo "[rgb-gpus-teaming] postrm: starting"

ACTION="$1"

# Only perform full cleanup on purge
if [ "$ACTION" != "purge" ]; then
  echo "[rgb-gpus-teaming] postrm: action is '$ACTION' — skipping purge cleanup."
  exit 0
fi

# Helper to run a command as a specific user (best-effort)
run_as_user() {
  local user="$1"
  local cmd="$2"
  if [ -z "$user" ]; then
    bash -c "$cmd" || true
    return
  fi
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$user" -- bash -c "$cmd" || true
  elif command -v sudo >/dev/null 2>&1; then
    sudo -u "$user" bash -c "$cmd" || true
  else
    bash -c "$cmd" || true
  fi
}

# --- System config files to remove (only config, nothing else) ---
SYS_CONFIGS=(
  "/opt/rgb-gpus-teaming/config/gpu_launcher_gnome_config"
  "/opt/rgb-gpus-teaming/config/gpu_all-ways-egpu_config"
  "/opt/rgb-gpus-teaming/config/gpu_all-ways-egpu_final"
  "/etc/rgb-gpus-teaming"
)

echo "[rgb-gpus-teaming] Removing system configuration files (best-effort)..."
for p in "${SYS_CONFIGS[@]}"; do
  if [ -e "$p" ]; then
    rm -rf "$p" || echo "[rgb-gpus-teaming] Warning: failed to remove $p (ignored)"
  fi
done

# Update desktop/mime caches if config removal affected them (safe)
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database >/dev/null 2>&1 || true
fi
if command -v update-mime-database >/dev/null 2>&1 && [ -d /usr/share/mime ]; then
  update-mime-database /usr/share/mime >/dev/null 2>&1 || true
fi

# --- Per-user config removal (best-effort) ---
echo "[rgb-gpus-teaming] Removing per-user configuration (best-effort)..."
for homedir in /home/* /root; do
  [ -d "$homedir" ] || continue
  username="$(basename "$homedir")"

  USER_CONFIGS=(
    "$homedir/.config/rgb-gpus-teaming"
    "$homedir/.config/rgb-gpus-teaming/gpu_launcher_gnome_config"
    "$homedir/.gpu_launcher_config"
  )

  for up in "${USER_CONFIGS[@]}"; do
    if [ -e "$up" ]; then
      run_as_user "$username" "rm -rf '$up'" || echo "[rgb-gpus-teaming] Warning: failed to remove $up for $username (ignored)"
    fi
  done
done

echo "[rgb-gpus-teaming] Purge config cleanup complete."

# Always exit 0 so dpkg purge completes even if some removals failed
exit 0

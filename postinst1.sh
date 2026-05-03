#!/bin/bash
set -e

echo "[rgb-gpus-teaming] postinst: starting"

# Create target dir and set permissions
mkdir -p /opt/rgb-gpus-teaming
chown -R root:root /opt/rgb-gpus-teaming
chmod -R 755 /opt/rgb-gpus-teaming

# Update desktop database (safe system-level operation)
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database >/dev/null 2>&1 || true
fi

# Best-effort: try to send a desktop notification to the installing user.
# This must NOT fail the script if it cannot run.
USER_NAME="${SUDO_USER:-$(logname 2>/dev/null || true)}"
if [ -n "$USER_NAME" ]; then
  USER_UID=$(id -u "$USER_NAME" 2>/dev/null || true)
  if [ -n "$USER_UID" ] && [ -d "/run/user/$USER_UID" ]; then
    # Try to run notify-send as the user with XDG_RUNTIME_DIR pointing to their runtime dir.
    # Ignore any error from notify-send so dpkg won't fail.
    runuser -u "$USER_NAME" -- env XDG_RUNTIME_DIR="/run/user/$USER_UID" \
      DISPLAY="${DISPLAY:-:0}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
      notify-send -t 10000 "RGB-GPUs-Teaming" "Installation finished. Please log out and log back in to apply desktop changes." >/dev/null 2>&1 || true
  else
    # No runtime dir found; print instruction to syslog/console
    echo "[rgb-gpus-teaming] No active graphical session detected for user $USER_NAME. Ask them to log out and log back in to apply desktop changes."
  fi
else
  echo "[rgb-gpus-teaming] No interactive user detected. Please log out and log back in to apply desktop changes."
fi

echo "[rgb-gpus-teaming] postinst: done"
exit 0

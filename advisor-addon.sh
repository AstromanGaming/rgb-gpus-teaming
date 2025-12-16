#!/bin/bash
set -euo pipefail

# System-wide config writer for /opt/rgb-gpus-teaming
# Writes /opt/rgb-gpus-teaming/config/gpu_all-ways-egpu_config
# Designed to be run as root (will re-run with sudo if invoked without).

INSTALL_BASE="/opt/rgb-gpus-teaming"
CONFIG_DIR="$INSTALL_BASE/config"
CONFIG_FILE="$CONFIG_DIR/gpu_all-ways-egpu_config"
EXTENDED_PERMS="0644"

# Determine the real (non-root) user and their home directory reliably
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
HOME_DIR="$(getent passwd "$REAL_USER" | cut -d: -f6 || true)"

# Basic sanity checks
if [[ -z "$REAL_USER" || -z "$HOME_DIR" ]]; then
  printf '%s\n' "Error: could not determine real user or home directory." >&2
  exit 1
fi

# Ensure running as root for system-wide write; re-run with sudo if not
if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script requires root. Re-running with sudo..."
  exec sudo -- "$0" "$@"
fi

# Check lspci availability
if ! command -v lspci >/dev/null 2>&1; then
  printf '%s\n' "Error: lspci is not installed. Install the pciutils package for your distribution (package name: pciutils)." >&2
  exit 1
fi

# Prepare config directory
mkdir -p "$CONFIG_DIR"
chmod 0755 "$CONFIG_DIR"

# Create/empty the config file as root, then set ownership to real user
: > "$CONFIG_FILE"
chmod "$EXTENDED_PERMS" "$CONFIG_FILE"

echo "Scanning GPUs and Audio devices using lspci..."
echo

# Helper to safely append a quoted key="value" line to the config file
write_config() {
  local key="$1"
  local val="$2"
  val="${val//\\/\\\\}"
  val="${val//\"/\\\"}"
  printf '%s="%s"\n' "$key" "$val" >> "$CONFIG_FILE"
}

# Capture VGA and 3D controllers
i=1
while IFS= read -r line; do
  [[ -z "${line// /}" ]] && continue
  # Remove leading bus id and class prefix, keep human-readable name
  gpu_name="$(printf '%s' "$line" | sed -E 's/^[^[:space:]]+[[:space:]]+[^:]+:[[:space:]]*//')"
  gpu_name="$(printf '%s' "$gpu_name" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  write_config "GPU_${i}_name" "$gpu_name"
  printf 'Detected GPU_%s: %s\n' "$i" "$gpu_name"
  ((i++))
done < <(lspci --no-legend | grep -E "VGA|3D" || true)

# Capture Audio devices
j=1
while IFS= read -r line; do
  [[ -z "${line// /}" ]] && continue
  audio_name="$(printf '%s' "$line" | sed -E 's/^[^[:space:]]+[[:space:]]+[^:]+:[[:space:]]*//')"
  audio_name="$(printf '%s' "$audio_name" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  write_config "AUDIO_${j}_name" "$audio_name"
  printf 'Detected AUDIO_%s: %s\n' "$j" "$audio_name"
  ((j++))
done < <(lspci --no-legend | grep -E "Audio" || true)

# If no devices found, warn and remove empty config
if [[ $i -eq 1 && $j -eq 1 ]]; then
  printf '%s\n' "Warning: no VGA/3D or Audio devices detected by lspci." >&2
  printf '%s\n' "Check that lspci returns output and that you have permission to run it." >&2
  rm -f "$CONFIG_FILE" || true
  exit 1
fi

# Ensure config file is owned by the real user and has correct perms
chown "$REAL_USER":"$REAL_USER" "$CONFIG_FILE"
chmod "$EXTENDED_PERMS" "$CONFIG_FILE"

echo
printf 'Initial configuration written to %s\n' "$CONFIG_FILE"

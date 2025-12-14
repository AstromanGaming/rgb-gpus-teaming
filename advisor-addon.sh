#!/bin/bash
set -euo pipefail

# Use the real (non-sudo) user's home when available
REAL_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$REAL_USER" | cut -d: -f6)"

CONFIG_FILE="$HOME_DIR/.gpu_all-ways-egpu_config"

# Ensure we can write to the target file as the real user
if [[ -z "${HOME_DIR:-}" ]]; then
    echo "Error: could not determine home directory for user $REAL_USER"
    exit 1
fi

# Check lspci availability
if ! command -v lspci &> /dev/null; then
    echo "Error: lspci is not installed. Install it with: sudo apt install pciutils"
    exit 1
fi

# Create/empty the config file as the real user
if [[ "$(id -u)" -eq 0 && "${REAL_USER}" != "root" ]]; then
    sudo -u "$REAL_USER" bash -c " : > '$CONFIG_FILE' "
else
    : > "$CONFIG_FILE"
fi

echo "Scanning GPUs and Audio devices using lspci..."
echo

# Helper to safely write a quoted variable line as the real user
write_config() {
    local key="$1"
    local val="$2"
    # Escape backslashes and double quotes for safe double-quoted assignment
    val="${val//\\/\\\\}"
    val="${val//\"/\\\"}"
    if [[ "$(id -u)" -eq 0 && "${REAL_USER}" != "root" ]]; then
        sudo -u "$REAL_USER" bash -c "printf '%s=\"%s\"\\n' '$key' \"$val\" >> '$CONFIG_FILE'"
    else
        printf '%s="%s"\n' "$key" "$val" >> "$CONFIG_FILE"
    fi
}

# Capture VGA and 3D controllers
i=1
# Use lspci -nnk or plain lspci; remove the bus id and class prefixes robustly
while IFS= read -r line; do
    # Skip empty lines
    [[ -z "${line// /}" ]] && continue
    # Remove the leading "0000:00:02.0 " and the device class prefix (e.g., "VGA compatible controller:" or "3D controller:")
    # This keeps the human-readable device name portion
    gpu_name="$(printf '%s' "$line" | sed -E 's/^[^[:space:]]+[[:space:]]+[^:]+:[[:space:]]*//')"
    # Trim leading/trailing whitespace
    gpu_name="$(printf '%s' "$gpu_name" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    write_config "GPU_${i}_name" "$gpu_name"
    ((i++))
done < <(lspci | grep -E "VGA|3D" || true)

# Capture Audio devices
j=1
while IFS= read -r line; do
    [[ -z "${line// /}" ]] && continue
    audio_name="$(printf '%s' "$line" | sed -E 's/^[^[:space:]]+[[:space:]]+[^:]+:[[:space:]]*//')"
    audio_name="$(printf '%s' "$audio_name" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    write_config "AUDIO_${j}_name" "$audio_name"
    ((j++))
done < <(lspci | grep -E "Audio" || true)

# If no devices found, warn and exit non-zero
if [[ $i -eq 1 && $j -eq 1 ]]; then
    echo "Warning: no VGA/3D or Audio devices detected by lspci."
    echo "Check that lspci returns output and that you have permission to run it."
    exit 1
fi

echo "Initial configuration written to $CONFIG_FILE"

#!/usr/bin/env bash
set -euo pipefail

# Use the real (non-sudo) user's home when possible
REAL_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$REAL_USER" | cut -d: -f6)"
MEM_FILE="${HOME_DIR}/.gpu_launcher_gnome_config"

# Safe read helpers
read_line() { read -r -p "$1" __tmp; printf '%s' "$__tmp"; }
read_choice() { read -r -p "$1" __tmp; printf '%s' "${__tmp:-}"; }

# Load previous configuration if present
GPU_MODE=""
DRI_PRIME=""
if [[ -f "$MEM_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$MEM_FILE"
    echo "Last mode used: ${GPU_MODE:-<none>}"
    echo "Last DRI_PRIME index: ${DRI_PRIME:-<none>}"
fi

echo
echo "What type of GPU do you want to use?"
echo "Note: DRI_PRIME is experimental for NVIDIA under Wayland. Render Offload is preferred."
echo "1) Intel / AMD / NVIDIA (DRI_PRIME)"
echo "2) NVIDIA (Render Offload)"
mode="$(read_choice "Your choice (1 or 2): ")"

if [[ -z "$mode" ]]; then
    echo "No choice entered. Exiting."
    exit 1
fi

case "$mode" in
    1)
        dri_value="$(read_line "Enter the DRI_PRIME value to use (e.g., 0, 1, 2...): ")"
        if [[ ! "$dri_value" =~ ^[0-9]+$ ]]; then
            echo "Invalid DRI_PRIME value: must be a non-negative integer."
            exit 1
        fi
        export DRI_PRIME="$dri_value"
        unset __NV_PRIME_RENDER_OFFLOAD
        unset __GLX_VENDOR_LIBRARY_NAME
        GPU_MODE="DRI_PRIME"
        echo "DRI_PRIME mode enabled with DRI_PRIME=$DRI_PRIME"

        if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
            echo "Warning: DRI_PRIME may not work reliably with NVIDIA under Wayland."
        fi

        # Save config (write to real user's home)
        {
            printf 'GPU_MODE="%s"\n' "$GPU_MODE"
            printf 'DRI_PRIME="%s"\n' "$DRI_PRIME"
        } > "$MEM_FILE"
        ;;
    2)
        export __NV_PRIME_RENDER_OFFLOAD=1
        export __GLX_VENDOR_LIBRARY_NAME=nvidia
        unset DRI_PRIME
        GPU_MODE="NVIDIA_RENDER_OFFLOAD"
        echo "NVIDIA Render Offload mode enabled"

        {
            printf 'GPU_MODE="%s"\n' "$GPU_MODE"
            printf 'DRI_PRIME=""\n'
        } > "$MEM_FILE"
        ;;
    *)
        echo "Invalid choice. Please enter 1 or 2."
        exit 1
        ;;
esac

# Ensure the saved file is owned by the real user when run under sudo/root
if [[ "$(id -u)" -eq 0 && "${REAL_USER:-}" != "root" ]]; then
    chown "$REAL_USER":"$REAL_USER" "$MEM_FILE" 2>/dev/null || true
fi

echo "Configuration saved to: $MEM_FILE"


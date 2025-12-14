#!/usr/bin/env bash
set -euo pipefail

# system-gpu-launcher-config.sh
# Interactive helper to choose GPU launch mode and persist it for system installs under /opt.
# Writes config to: /opt/RGB-GPUs-Teaming.OP/config/gpu_launcher_gnome_config
# Intended to be run as root (will re-run with sudo if invoked without).

INSTALL_BASE="/opt/RGB-GPUs-Teaming.OP"
CONFIG_DIR="$INSTALL_BASE/config"
MEM_FILE="$CONFIG_DIR/gpu_launcher_gnome_config"

# Determine real (non-sudo) user and home
REAL_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$REAL_USER" | cut -d: -f6 || true)"

# Safe read helpers
read_line() { read -r -p "$1" __tmp; printf '%s' "$__tmp"; }
read_choice() { read -r -p "$1" __tmp; printf '%s' "${__tmp:-}"; }

# Ensure running as root for system-wide writes
if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script requires root. Re-running with sudo..."
    exec sudo "$0" "$@"
fi

# Basic checks
if [[ -z "$REAL_USER" || -z "$HOME_DIR" ]]; then
    printf '%s\n' "Error: could not determine real user or home directory." >&2
    exit 1
fi

# Ensure install/config directories exist
mkdir -p "$CONFIG_DIR"
chmod 0755 "$CONFIG_DIR"

# Load previous configuration if present
GPU_MODE=""
DRI_PRIME=""
if [[ -f "$MEM_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$MEM_FILE"
    printf 'Last mode used: %s\n' "${GPU_MODE:-<none>}"
    printf 'Last DRI_PRIME index: %s\n' "${DRI_PRIME:-<none>}"
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
        DRI_PRIME="$dri_value"
        unset __NV_PRIME_RENDER_OFFLOAD
        unset __GLX_VENDOR_LIBRARY_NAME
        GPU_MODE="DRI_PRIME"
        printf 'DRI_PRIME mode enabled with DRI_PRIME=%s\n' "$DRI_PRIME"

        if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
            echo "Warning: DRI_PRIME may not work reliably with NVIDIA under Wayland."
        fi

        # Save config (system-wide)
        {
            printf 'GPU_MODE="%s"\n' "$GPU_MODE"
            printf 'DRI_PRIME="%s"\n' "$DRI_PRIME"
        } > "$MEM_FILE"
        ;;
    2)
        # For render offload we persist the mode; environment variables are set at launch time by launcher
        GPU_MODE="NVIDIA_RENDER_OFFLOAD"
        printf 'NVIDIA Render Offload mode enabled\n'

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

# Ensure the saved file is owned by the real user so they can read/edit it
if [[ -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
    chown "$REAL_USER":"$REAL_USER" "$MEM_FILE" 2>/dev/null || true
fi
chmod 0644 "$MEM_FILE" 2>/dev/null || true

printf 'Configuration saved to: %s\n' "$MEM_FILE"

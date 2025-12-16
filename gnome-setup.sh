#!/usr/bin/env bash
set -euo pipefail

# gnome-setup.sh
# Interactive helper to choose GPU launch mode and persist it per-user.
# Writes config to: $USER_HOME/.config/rgb-gpus-teaming/gpu_launcher_gnome_config
# If run under sudo, the config is written for the real user (SUDO_USER).

INSTALL_BASE="/opt/rgb-gpus-teaming"
SYSTEM_CONFIG_DIR="$INSTALL_BASE/config"
SYSTEM_MEM_FILE="$SYSTEM_CONFIG_DIR/gpu_launcher_gnome_config"

# Determine target user and home (prefer SUDO_USER when run with sudo)
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"

# Per-user config location
USER_CONFIG_DIR="${XDG_CONFIG_HOME:-$TARGET_HOME/.config}/rgb-gpus-teaming"
USER_MEM_FILE="$USER_CONFIG_DIR/gpu_launcher_gnome_config"

# Safe read helpers
read_line() { read -r -p "$1" __tmp; printf '%s' "$__tmp"; }
read_choice() { read -r -p "$1" __tmp; printf '%s' "${__tmp:-}"; }

# If not run as root, continue as the invoking user (we will write to their config)
if [[ "$(id -u)" -ne 0 ]]; then
    echo "Running as user: $USER (will write per-user config to $USER_MEM_FILE)"
else
    # Running as root: ensure TARGET_USER is valid
    if [[ -z "$TARGET_USER" || -z "$TARGET_HOME" ]]; then
        printf '%s\n' "Error: could not determine target user or home directory." >&2
        exit 1
    fi
    echo "Running as root; will write per-user config for: $TARGET_USER -> $USER_MEM_FILE"
fi

# Ensure per-user config directory exists and has correct ownership
mkdir -p "$USER_CONFIG_DIR"
chmod 0755 "$USER_CONFIG_DIR"
# If running as root, set ownership to target user
if [[ "$(id -u)" -eq 0 ]]; then
    chown "$TARGET_USER":"$TARGET_USER" "$USER_CONFIG_DIR" 2>/dev/null || true
fi

# Load previous configuration if present (from per-user file)
GPU_MODE=""
DRI_PRIME=""
if [[ -f "$USER_MEM_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$USER_MEM_FILE"
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
        GPU_MODE="DRI_PRIME"
        printf 'DRI_PRIME mode enabled with DRI_PRIME=%s\n' "$DRI_PRIME"

        if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
            echo "Warning: DRI_PRIME may not work reliably with NVIDIA under Wayland."
        fi

        # Save per-user config
        {
            printf 'GPU_MODE="%s"\n' "$GPU_MODE"
            printf 'DRI_PRIME="%s"\n' "$DRI_PRIME"
        } > "$USER_MEM_FILE"
        ;;
    2)
        GPU_MODE="NVIDIA_RENDER_OFFLOAD"
        printf 'NVIDIA Render Offload mode enabled\n'

        {
            printf 'GPU_MODE="%s"\n' "$GPU_MODE"
            printf 'DRI_PRIME=""\n'
        } > "$USER_MEM_FILE"
        ;;
    *)
        echo "Invalid choice. Please enter 1 or 2."
        exit 1
        ;;
esac

# Ensure the saved file is owned by the target user so they can read/edit it
if [[ -n "$TARGET_USER" && "$(id -u)" -eq 0 ]]; then
    chown "$TARGET_USER":"$TARGET_USER" "$USER_MEM_FILE" 2>/dev/null || true
fi
chmod 0644 "$USER_MEM_FILE" 2>/dev/null || true

printf 'Configuration saved to: %s\n' "$USER_MEM_FILE"

# Optionally also write a system-wide default if none exists (non-destructive)
if [[ ! -f "$SYSTEM_MEM_FILE" ]]; then
    mkdir -p "$SYSTEM_CONFIG_DIR"
    chmod 0755 "$SYSTEM_CONFIG_DIR"
    cp -n "$USER_MEM_FILE" "$SYSTEM_MEM_FILE" 2>/dev/null || true
    chmod 0644 "$SYSTEM_MEM_FILE" 2>/dev/null || true
    log_msg="(copied to system default)"
else
    log_msg=""
fi

if [[ -n "$log_msg" ]]; then
    printf 'System default created at: %s %s\n' "$SYSTEM_MEM_FILE" "$log_msg"
fi


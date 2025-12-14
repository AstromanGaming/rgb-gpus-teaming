#!/usr/bin/env bash
set -euo pipefail

# Use the real (non-sudo) user's home when available
REAL_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$REAL_USER" | cut -d: -f6)"
MEM_FILE="${HOME_DIR}/.gpu_launcher_config"

# Helper: read a line safely
read_line() {
    local prompt="$1"
    local var
    read -r -p "$prompt" var
    printf '%s' "$var"
}

# Helper: read a yes/no answer (not used here but handy)
read_yesno() {
    local prompt="$1"
    local ans
    while true; do
        read -r -p "$prompt" ans
        case "$ans" in
            [yY]|1) return 0 ;;
            [nN]|'') return 1 ;;
            *) echo "Please answer y (yes) or n (no)." ;;
        esac
    done
}

# Load previous configuration if present (safe sourcing)
GPU_MODE=""
DRI_PRIME=""
if [[ -f "$MEM_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$MEM_FILE"
    echo "Last mode used: ${GPU_MODE:-<none>}"
    echo "Last DRI_PRIME index: ${DRI_PRIME:-<none>}"
else
    echo "No previous configuration found."
fi

echo
echo "What type of GPU do you want to use?"
echo "Note: DRI_PRIME is experimental for NVIDIA under Wayland. Render Offload is preferred."
echo "1) Intel / AMD / NVIDIA (DRI_PRIME)"
echo "2) NVIDIA (Render Offload)"
echo "Press Enter to reuse the last saved configuration."
mode="$(read_line "Your choice (1 or 2): ")"

if [[ -z "$mode" ]]; then
    if [[ -z "${GPU_MODE:-}" ]]; then
        echo "No saved configuration to reuse. Please choose an option."
        mode="$(read_line "Your choice (1 or 2): ")"
    else
        echo "Reusing saved configuration from $MEM_FILE"
    fi
fi

if [[ -n "$mode" ]]; then
    case "$mode" in
        1)
            dri_value="$(read_line "Enter the DRI_PRIME value to use (e.g., 0, 1, 2...): ")"
            # Validate numeric input
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
            ;;
        2)
            export __NV_PRIME_RENDER_OFFLOAD=1
            export __GLX_VENDOR_LIBRARY_NAME=nvidia
            unset DRI_PRIME
            GPU_MODE="NVIDIA_RENDER_OFFLOAD"
            echo "NVIDIA Render Offload mode enabled"
            ;;
        *)
            echo "Invalid choice"
            exit 1
            ;;
    esac

    # Save the choice (write as the real user if running under sudo)
    {
        printf 'GPU_MODE="%s"\n' "$GPU_MODE"
        # Only write DRI_PRIME if set
        if [[ -n "${DRI_PRIME:-}" ]]; then
            printf 'DRI_PRIME="%s"\n' "$DRI_PRIME"
        else
            printf 'DRI_PRIME=""\n'
        fi
    } > "$MEM_FILE"
    echo "Configuration saved to $MEM_FILE"
fi

echo
echo "You can now paste or type a command to execute (e.g., glxinfo | grep \"OpenGL renderer\" or firefox)."
read -r -e -p "Command: " user_cmd

if [[ -z "${user_cmd// /}" ]]; then
    echo "No command entered. Exiting."
    exit 1
fi

echo "Executing command with GPU mode: $GPU_MODE"
echo

# Execute the command in a subshell with the appropriate environment
if [[ "$GPU_MODE" == "NVIDIA_RENDER_OFFLOAD" ]]; then
    # Export variables for the child process only
    env __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia bash -lc "$user_cmd"
else
    # If DRI_PRIME is set, pass it; otherwise run without it
    if [[ -n "${DRI_PRIME:-}" ]]; then
        env DRI_PRIME="$DRI_PRIME" bash -lc "$user_cmd"
    else
        bash -lc "$user_cmd"
    fi
fi

echo
read -r -p "Press Enter to exit..."

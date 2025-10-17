#!/bin/bash

# Memory file
MEM_FILE="$HOME/.gpu_launcher_config"

# Load the last choice if available
if [[ -f "$MEM_FILE" ]]; then
    source "$MEM_FILE"
    echo "Last mode used: $GPU_MODE"
    echo "Last DRI_PRIME index: $DRI_PRIME"
fi

# Main menu
echo "What type of GPU do you want to use? *NVIDIA* on DRI_PRIME is experimental"
echo "1) Intel/AMD/*NVIDIA* (DRI_PRIME)"
echo "2) NVIDIA (Render Offload)"
read -p "Your choice (1 or 2): " mode

case $mode in
    1)
        read -p "Enter the DRI_PRIME value to use (e.g., 0, 1, 2...): " dri_value
        export DRI_PRIME=$dri_value
        unset __NV_PRIME_RENDER_OFFLOAD
        unset __GLX_VENDOR_LIBRARY_NAME
        GPU_MODE="Intel/AMD/*NVIDIA*"
        echo "Intel/AMD mode enabled with DRI_PRIME=$DRI_PRIME"
        ;;
    2)
        export __NV_PRIME_RENDER_OFFLOAD=1
        export __GLX_VENDOR_LIBRARY_NAME=nvidia
        unset DRI_PRIME
        GPU_MODE="NVIDIA"
        echo "NVIDIA mode enabled with Render Offload"
        ;;
    *)
        echo "Invalid choice"
        exit 1
        ;;
esac

# Save the choice
echo "GPU_MODE=\"$GPU_MODE\"" > "$MEM_FILE"
echo "DRI_PRIME=\"$DRI_PRIME\"" >> "$MEM_FILE"

# Run a custom command
echo "You can now copy and paste a command to execute (e.g., glxinfo | grep \"OpenGL renderer\") or just type a command (e.g., firefox)."
read -e -p "Command: " user_cmd

if [[ -z "$user_cmd" ]]; then
    echo "No command entered. Exiting."
    exit 1
fi

echo "Executing command with GPU mode: $GPU_MODE"

if [[ "$GPU_MODE" == "NVIDIA" ]]; then
    __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia bash -c "$user_cmd"
else
    DRI_PRIME=$DRI_PRIME bash -c "$user_cmd"
fi

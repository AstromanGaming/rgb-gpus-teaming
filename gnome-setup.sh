#!/bin/bash

MEM_FILE="$HOME/.gpu_launcher_gnome_config"

echo "What type of GPU do you want to use? *NVIDIA* on DRI_PRIME is experimental"
echo "1) Intel / AMD / *NVIDIA* (via DRI_PRIME)"
echo "2) NVIDIA (Render Offload)"
read -rp "Your choice (1 or 2): " mode

case "$mode" in
    1)
        read -rp "Enter the DRI_PRIME value to use (e.g., 0, 1, 2...): " dri_value
        export DRI_PRIME="$dri_value"
        unset __NV_PRIME_RENDER_OFFLOAD
        unset __GLX_VENDOR_LIBRARY_NAME
        GPU_MODE="Intel/AMD/*NVIDIA*"
        echo "Intel/AMD mode enabled with DRI_PRIME=$DRI_PRIME"

        {
            echo "GPU_MODE=DRI_PRIME"
            echo "DRI_PRIME=$DRI_PRIME"
        } > "$MEM_FILE"
        ;;
    2)
        export __NV_PRIME_RENDER_OFFLOAD=1
        export __GLX_VENDOR_LIBRARY_NAME=nvidia
        unset DRI_PRIME
        GPU_MODE="NVIDIA"
        echo "NVIDIA mode enabled with Render Offload"

        {
            echo "GPU_MODE=NVIDIA"
            echo "DRI_PRIME="
        } > "$MEM_FILE"
        ;;
    *)
        echo "Invalid choice. Please enter 1 or 2."
        exit 1
        ;;
esac

echo "Configuration saved to: $MEM_FILE"

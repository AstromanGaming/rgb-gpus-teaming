#!/bin/bash

MEM_FILE="$HOME/.gpu_launcher_config"

echo "Choose GPU mode:"
echo "1) Intel/AMD/*NVIDIA* (DRI_PRIME)"
echo "2) NVIDIA (Render Offload)"
read -p "Your choice (1 or 2): " mode

case $mode in
    1)
        read -p "Enter DRI_PRIME value: " dri_value
        echo "GPU_MODE=\"DRI_PRIME\"" > "$MEM_FILE"
        echo "DRI_PRIME=\"$dri_value\"" >> "$MEM_FILE"
        ;;
    2)
        echo "GPU_MODE=\"NVIDIA\"" > "$MEM_FILE"
        echo "DRI_PRIME=\"\"" >> "$MEM_FILE"
        ;;
    *)
        echo "Invalid choice"
        exit 1
        ;;
esac

echo "Saved GPU mode to $MEM_FILE"

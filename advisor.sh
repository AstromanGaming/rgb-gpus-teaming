#!/bin/bash

# Check for glxinfo
if ! command -v glxinfo &> /dev/null; then
    echo "Error: glxinfo is not installed. Install it with: sudo apt install mesa-utils"
    exit 1
fi

declare -A seen_gpus

echo "Scanning available GPUs using glxinfo..."
echo

for i in $(seq 0 15); do
    output=$(DRI_PRIME=$i glxinfo 2>/dev/null | grep "Device:")
    if [[ -n "$output" ]]; then
        gpu_name=$(echo "$output" | sed 's/.*Device: //')

        # Skip duplicates
        if [[ -n "${seen_gpus["$gpu_name"]}" ]]; then
            continue
        fi
        seen_gpus["$gpu_name"]=1

        # Vendor detection
        if [[ "$gpu_name" == *"AMD"* || "$gpu_name" == *"radeon"* || "$gpu_name" == *"Radeon"* ]]; then
            vendor="AMD"
        elif [[ "$gpu_name" == *"NVIDIA"* ]]; then
            vendor="NVIDIA"
        elif [[ "$gpu_name" == *"Intel"* ]]; then
            vendor="Intel"
        else
            vendor="Unknown"
        fi

        echo "DRI_PRIME=$i → $vendor GPU: $gpu_name"
        echo "Suggested launch command:"
        if [[ "$vendor" == "NVIDIA" ]]; then
            if [[ "$gpu_name" == *"zink"* ]]; then
                echo "  # Detected via Zink Vulkan layer — fallback mode"
                echo "  Recommended: __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia your_app"
            else
                echo "  __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia your_app"
                echo "  or: DRI_PRIME=$i your_app"
            fi
            echo "  Note: DRI_PRIME is experimental for NVIDIA under Wayland. Prefer Render Offload when possible."
        else
            echo "  DRI_PRIME=$i your_app"
        fi
        echo
    fi
done

# NVIDIA Render Offload check
nvidia_output=$(__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia glxinfo 2>/dev/null | grep "Device:")
if [[ -n "$nvidia_output" ]]; then
    gpu_name=$(echo "$nvidia_output" | sed 's/.*Device: //')
    if [[ -z "${seen_gpus["$gpu_name"]}" ]]; then
        echo "NVIDIA Render Offload detected:"
        echo "→ $gpu_name"
        echo "Suggested launch command:"
        echo "  __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia your_app"
        echo "  Note: This method is preferred for NVIDIA under Wayland."
        echo
    fi
fi

# Pause before exit
echo ""
read -p "Press Enter to exit..."

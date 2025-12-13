#!/bin/bash

echo "Choose detection method:"
echo "1) glxinfo"
echo "2) lspci"
read -p "Enter choice [1/2]: " choice

declare -A seen_gpus

if [[ "$choice" == "1" ]]; then
    # Check for glxinfo
    if ! command -v glxinfo &> /dev/null; then
        echo "Error: glxinfo is not installed. Install it with: sudo apt install mesa-utils"
        exit 1
    fi
    if ! glxinfo >/dev/null 2>&1; then
        echo "Error: glxinfo is installed but failed to run."
        exit 1
    fi

    echo "Scanning GPUs using glxinfo..."
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
            if [[ "$gpu_name" == *"AMD"* || "$gpu_name" == *"Radeon"* ]]; then
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

elif [[ "$choice" == "2" ]]; then
    # Check for lspci
    if ! command -v lspci &> /dev/null; then
        echo "Error: lspci is not installed. Install it with: sudo apt install pciutils"
        exit 1
    fi

    echo "Scanning GPUs using lspci..."
    echo

    # Only VGA and 3D controllers (skip Audio)
    lspci | grep -E "VGA|3D"
else
    echo "Invalid choice."
    exit 1
fi

echo ""
read -p "Press Enter to exit..."

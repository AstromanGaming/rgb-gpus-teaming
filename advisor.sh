#!/usr/bin/env bash
set -euo pipefail

# Simple GPU detection helper (English output)
# Usage: run and choose 1 for glxinfo-based detection or 2 for lspci-based detection.

read_yesno() {
    # not used interactively here, but kept for future extension
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

echo "Choose detection method:"
echo "1) glxinfo (render offload / DRI_PRIME detection)"
echo "2) lspci (PCI device list)"
read -r -p "Enter choice [1/2]: " choice

declare -A seen_gpus

if [[ "$choice" == "1" ]]; then
    if ! command -v glxinfo &>/dev/null; then
        echo "Error: glxinfo not found. Install with: sudo apt install mesa-utils"
        exit 1
    fi

    echo "Scanning GPUs using glxinfo (DRI_PRIME 0..15)..."
    echo

    # Try each DRI_PRIME value once; use a timeout to avoid hangs
    for i in $(seq 0 15); do
        # run glxinfo with a short timeout to avoid long stalls
        output="$(timeout 2s env DRI_PRIME="$i" glxinfo 2>/dev/null || true)"
        # find the first "Device:" line (if any)
        device_line="$(printf '%s\n' "$output" | grep -m1 'Device:' || true)"
        if [[ -n "$device_line" ]]; then
            # Extract the device name after "Device:"
            gpu_name="$(printf '%s' "$device_line" | sed -E 's/.*Device:[[:space:]]*//')"
            gpu_name="$(printf '%s' "$gpu_name" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
            [[ -z "$gpu_name" ]] && continue

            # Skip duplicates
            if [[ -n "${seen_gpus["$gpu_name"]:-}" ]]; then
                continue
            fi
            seen_gpus["$gpu_name"]=1

            # Vendor detection (simple heuristics)
            vendor="Unknown"
            case "$gpu_name" in
                *NVIDIA*|*nvidia*) vendor="NVIDIA" ;;
                *AMD*|*Radeon*|*radeon*) vendor="AMD" ;;
                *Intel*|*intel*) vendor="Intel" ;;
            esac

            printf 'DRI_PRIME=%s → %s GPU: %s\n' "$i" "$vendor" "$gpu_name"
            printf 'Suggested launch command:\n'
            if [[ "$vendor" == "NVIDIA" ]]; then
                if [[ "$gpu_name" == *zink* || "$gpu_name" == *Zink* ]]; then
                    printf '  # Detected via Zink Vulkan layer — fallback mode\n'
                    printf '  __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia your_app\n'
                else
                    printf '  __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia your_app\n'
                    printf '  or: DRI_PRIME=%s your_app\n' "$i"
                fi
                printf '  Note: DRI_PRIME may be experimental for NVIDIA under Wayland; prefer Render Offload when possible.\n'
            else
                printf '  DRI_PRIME=%s your_app\n' "$i"
            fi
            printf '\n'
        fi
    done

elif [[ "$choice" == "2" ]]; then
    if ! command -v lspci &>/dev/null; then
        echo "Error: lspci not found. Install with: sudo apt install pciutils"
        exit 1
    fi

    echo "Scanning GPUs using lspci (VGA and 3D controllers)..."
    echo

    # Print a cleaned list: bus id + device class + device name
    # Example line: "0000:01:00.0 VGA compatible controller: NVIDIA Corporation Device ..."
    lspci | grep -E "VGA|3D" | while IFS= read -r line; do
        # Trim leading/trailing whitespace and collapse multiple spaces
        clean="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | tr -s ' ')"
        printf '%s\n' "$clean"
    done

else
    echo "Invalid choice."
    exit 1
fi

echo
read -r -p "Press Enter to exit..."

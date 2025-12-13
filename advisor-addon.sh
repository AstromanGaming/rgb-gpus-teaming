#!/bin/bash

CONFIG_FILE="$HOME/.gpu_all-ways-egpu_config"
> "$CONFIG_FILE"

# Check if lspci is available
if ! command -v lspci &> /dev/null; then
    echo "Error: lspci is not installed. Install it with: sudo apt install pciutils"
    exit 1
fi

echo "Scanning GPUs and Audio devices using lspci..."
echo

i=1
# Capture VGA and 3D controllers
while IFS= read -r line; do
    gpu_name=$(echo "$line" | sed 's/.*controller: //')
    echo "GPU_${i}_name=\"$gpu_name\"" >> "$CONFIG_FILE"
    ((i++))
done < <(lspci | grep -E "VGA|3D")

j=1
# Capture Audio devices
while IFS= read -r line; do
    audio_name=$(echo "$line" | sed 's/.*Audio device: //')
    echo "AUDIO_${j}_name=\"$audio_name\"" >> "$CONFIG_FILE"
    ((j++))
done < <(lspci | grep -E "Audio")

echo "Initial configuration written to $CONFIG_FILE"

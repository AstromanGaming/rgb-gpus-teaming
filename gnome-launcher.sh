#!/bin/bash

MEM_FILE="$HOME/.gpu_launcher_config"
source "$MEM_FILE"

if [[ "$GPU_MODE" == "NVIDIA" ]]; then
    __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia bash -c "$@"
else
    DRI_PRIME=$DRI_PRIME bash -c "$@"
fi

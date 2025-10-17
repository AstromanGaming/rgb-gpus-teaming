#!/bin/bash

CONFIG="$HOME/.gpu_launcher_compositor_config"
[[ -f "$CONFIG" ]] && source "$CONFIG"

if [[ "$GPU_MODE" == "NVIDIA" ]]; then
    echo "Compositor launched with NVIDIA"
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    export __NV_PRIME_RENDER_OFFLOAD=1
else
    echo "Compositor launched with DRI_PRIME=${DRI_PRIME:-1}"
    export DRI_PRIME=${DRI_PRIME:-1}
fi

exec dbus-run-session gnome-session

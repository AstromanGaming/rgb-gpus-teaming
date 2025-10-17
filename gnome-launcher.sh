#!/bin/bash

input="$1"
MEM_FILE="$HOME/.gpu_launcher_config"
[[ -f "$MEM_FILE" ]] && source "$MEM_FILE"

if [[ -f "$input" ]]; then
    input="$(realpath "$input")"
fi

get_common_terminal() {
    for term in ptyxis gnome-terminal xfce4-terminal konsole tilix x-terminal-emulator alacritty kitty urxvt terminator xterm; do
        if command -v "$term" >/dev/null 2>&1; then
            echo "$term"
            return
        fi
    done
    echo "xterm"
}

launch_with_gpu() {
    echo "Running: $1 with GPU mode: ${GPU_MODE:-default}"
    if [[ "$GPU_MODE" == "NVIDIA" ]]; then
        __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia eval "$1"
    else
        DRI_PRIME=${DRI_PRIME:-1} eval "$1"
    fi
}

launch_in_terminal() {
    terminal="$1"
    executable="$2"

    case "$terminal" in
        ptyxis)
            launch_with_gpu "$terminal --execute \"$executable\""
            ;;
        gnome-terminal|xfce4-terminal|x-terminal-emulator|konsole|tilix|kitty)
            launch_with_gpu "$terminal -- bash -c '$executable; exec bash'"
            ;;
        alacritty|urxvt|xterm|terminator)
            launch_with_gpu "$terminal -e \"$executable\""
            ;;
        *)
            echo "Unsupported terminal: $terminal"
            ;;
    esac
}

if [[ -f "$input" && -x "$input" ]]; then
    terminal=$(get_common_terminal)
    echo "Launching executable in terminal: $input via $terminal"
    launch_in_terminal "$terminal" "$input"
    exit 0
fi

if command -v ${input%% *} >/dev/null 2>&1; then
    echo "Launching command: $input"
    launch_with_gpu "$input" &
    exit 0
fi

echo "Error: '$input' is not a valid executable or command."
exit 1

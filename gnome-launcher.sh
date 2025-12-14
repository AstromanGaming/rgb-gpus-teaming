#!/bin/bash
set -euo pipefail

# gnome-launcher.sh
# Launch a command or executable with GPU offload, using system-wide config under /opt.

INSTALL_BASE="/opt/RGB-GPUs-Teaming.OP"
MEM_FILE="$INSTALL_BASE/config/gpu_launcher_gnome_config"
REAL_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$REAL_USER" | cut -d: -f6 || true)"

# Load user memory file if present (fall back to nothing)
[[ -f "$MEM_FILE" ]] && source "$MEM_FILE"

input="${1:-}"
if [[ -z "$input" ]]; then
  echo "Usage: $0 \"<command-or-path>\""
  exit 2
fi

# If input is a file path, resolve it
if [[ -f "$input" ]]; then
  input="$(realpath "$input")"
fi

get_common_terminal() {
  for term in ptyxis gnome-terminal xfce4-terminal konsole tilix x-terminal-emulator alacritty kitty urxvt terminator xterm; do
    if type -P "$term" >/dev/null 2>&1; then
      echo "$term"
      return
    fi
  done
  echo "xterm"
}

launch_with_gpu() {
  local cmd="$1"
  echo "Running: $cmd with GPU mode: ${GPU_MODE:-default}"
  if [[ "${GPU_MODE:-}" == "NVIDIA" ]]; then
    __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia eval "$cmd"
  else
    DRI_PRIME="${DRI_PRIME:-1}" eval "$cmd"
  fi
}

launch_in_terminal() {
  local terminal="$1"
  local executable="$2"

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

# If input is an executable file, open it in a terminal
if [[ -f "$input" && -x "$input" ]]; then
  terminal="$(get_common_terminal)"
  echo "Launching executable in terminal: $input via $terminal"
  launch_in_terminal "$terminal" "$input"
  exit 0
fi

# If the first word is an available command, run it with GPU env
first_word="${input%% *}"
if type -P "$first_word" >/dev/null 2>&1; then
  echo "Launching command: $input"
  launch_with_gpu "$input" &
  exit 0
fi

echo "Error: '$input' is not a valid executable or command."
exit 1

#!/usr/bin/env bash
set -euo pipefail

# gnome-launcher.sh
# Launch a command or executable with GPU offload, using per-user config when available.
# Script lives in /opt and is intended to be executable by normal users.

INSTALL_BASE="/opt/rgb-gpus-teaming"
SYSTEM_MEM_FILE="$INSTALL_BASE/config/gpu_launcher_gnome_config"

# Determine the target user whose config we should read:
# - If invoked via sudo, SUDO_USER is the real user; otherwise use current user.
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"

# Per-user config path (XDG_CONFIG_HOME if set for that user, else ~/.config)
USER_CONFIG_DIR=""
USER_MEM_FILE=""

if [[ -n "$TARGET_HOME" ]]; then
  # If the target user has XDG_CONFIG_HOME set in their environment, we can't reliably read it here.
  # Use the conventional path under their home.
  USER_CONFIG_DIR="$TARGET_HOME/.config/rgb-gpus-teaming"
  USER_MEM_FILE="$USER_CONFIG_DIR/gpu_launcher_gnome_config"
fi

# Load configuration: prefer per-user config, fall back to system config
GPU_MODE=""
DRI_PRIME=""

if [[ -n "$USER_MEM_FILE" && -f "$USER_MEM_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$USER_MEM_FILE"
elif [[ -f "$SYSTEM_MEM_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$SYSTEM_MEM_FILE"
fi

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
  for term in gnome-terminal xfce4-terminal konsole tilix x-terminal-emulator alacritty kitty urxvt terminator xterm; do
    if type -P "$term" >/dev/null 2>&1; then
      echo "$term"
      return
    fi
  done
  echo "xterm"
}

# Run a command string with the appropriate GPU environment
launch_with_gpu() {
  local cmd="$1"

  # Choose env based on GPU_MODE
  if [[ "${GPU_MODE:-}" == "NVIDIA_RENDER_OFFLOAD" || "${GPU_MODE:-}" == "NVIDIA" ]]; then
    # Render offload env
    env __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia bash -c "$cmd"
  else
    # DRI_PRIME mode (default to 1 if not set)
    local dpi="${DRI_PRIME:-1}"
    env DRI_PRIME="$dpi" bash -c "$cmd"
  fi
}

launch_in_terminal() {
  local terminal="$1"
  local executable="$2"

  case "$terminal" in
    gnome-terminal|xfce4-terminal|x-terminal-emulator|konsole|tilix|kitty)
      launch_with_gpu "$terminal -- bash -c '$executable; exec bash'"
      ;;
    alacritty|urxvt|xterm|terminator)
      launch_with_gpu "$terminal -e \"$executable\""
      ;;
    *)
      # Fallback: try to run directly
      launch_with_gpu "$executable"
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
  # Run in background so launcher returns quickly
  launch_with_gpu "$input" &
  exit 0
fi

echo "Error: '$input' is not a valid executable or command."
exit 1

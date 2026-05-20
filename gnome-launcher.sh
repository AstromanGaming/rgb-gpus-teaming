#!/usr/bin/env bash
set -euo pipefail

# gnome-launcher.sh
# Usage:
#   gnome-launcher.sh "<command-or-path-or-desktopId>" [as-root]
# If second arg is "as-root", attempt to elevate via pkexec or sudo.

INSTALL_BASE="/opt/rgb-gpus-teaming"
SYSTEM_MEM_FILE="$INSTALL_BASE/config/gpu_launcher_gnome_config"

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"

USER_CONFIG_DIR=""
USER_MEM_FILE=""

if [[ -n "$TARGET_HOME" ]]; then
  USER_CONFIG_DIR="$TARGET_HOME/.config/rgb-gpus-teaming"
  USER_MEM_FILE="$USER_CONFIG_DIR/gpu_launcher_gnome_config"
fi

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
elevate_flag="${2:-}"

log() {
  logger -t rgb-gpus-teaming "$*"
}

if [[ -z "$input" ]]; then
  echo "Usage: $0 \"<command-or-path-or-desktopId>\" [as-root]"
  exit 2
fi

# Normalize input
if [[ -f "$input" ]]; then
  input="$(realpath "$input")"
fi

get_gpu_wrapper_cmd() {
  if command -v prime-run >/dev/null 2>&1; then
    echo "prime-run"
  else
    echo "env DRI_PRIME=${DRI_PRIME:-1}"
  fi
}

run_cmd_array() {
  local -n arr=$1
  local elevated="$2"
  local wrapper
  wrapper="$(get_gpu_wrapper_cmd)"

  if [[ "$elevated" == "yes" ]]; then
    # Try pkexec first (preferred for GUI elevation)
    if command -v pkexec >/dev/null 2>&1; then
      log "Elevating with pkexec: ${arr[*]}"
      if [[ "$wrapper" == "prime-run" ]]; then
        pkexec --disable-internal-agent env DISPLAY="$DISPLAY" XAUTHORITY="${XAUTHORITY:-}" prime-run "${arr[@]}" &
      else
        pkexec --disable-internal-agent env DRI_PRIME="${DRI_PRIME:-1}" "${arr[@]}" &
      fi
      disown
      return 0
    fi

    # Fallback to sudo
    if command -v sudo >/dev/null 2>&1; then
      log "Elevating with sudo: ${arr[*]}"
      if [[ "$wrapper" == "prime-run" ]]; then
        sudo prime-run "${arr[@]}" &
      else
        sudo env DRI_PRIME="${DRI_PRIME:-1}" "${arr[@]}" &
      fi
      disown
      return 0
    fi

    log "No pkexec or sudo available for elevation"
    return 1
  else
    # Non-elevated run
    if [[ "$wrapper" == "prime-run" ]]; then
      prime-run "${arr[@]}" & disown
    else
      env DRI_PRIME="${DRI_PRIME:-1}" "${arr[@]}" & disown
    fi
    return 0
  fi
}

# If input is a .desktop entry
if [[ "$input" == *.desktop ]]; then
  DESKTOP_ID="${input%.desktop}"
  log "Requested desktop launch: ${DESKTOP_ID} (elevate=${elevate_flag})"

  # Prefer gtk-launch
  if command -v gtk-launch >/dev/null 2>&1; then
    CMD=("gtk-launch" "${DESKTOP_ID}")
    if [[ "$elevate_flag" == "as-root" ]]; then
      run_cmd_array CMD yes || { echo "Elevation failed"; exit 1; }
    else
      run_cmd_array CMD no || { echo "Launch failed"; exit 1; }
    fi
    exit 0
  fi

  # Try flatpak run if flatpak exists (best-effort)
  if command -v flatpak >/dev/null 2>&1; then
    CMD=("flatpak" "run" "${DESKTOP_ID}")
    if [[ "$elevate_flag" == "as-root" ]]; then
      run_cmd_array CMD yes || true
    else
      run_cmd_array CMD no || true
    fi
    # continue to other fallbacks if flatpak run didn't work
  fi

  # Fallback to gio open
  if command -v gio >/dev/null 2>&1; then
    CMD=("gio" "open" "desktop:${DESKTOP_ID}")
    if [[ "$elevate_flag" == "as-root" ]]; then
      run_cmd_array CMD yes || { echo "Elevation failed"; exit 1; }
    else
      run_cmd_array CMD no || { echo "Launch failed"; exit 1; }
    fi
    exit 0
  fi

  log "Failed to launch desktop entry ${DESKTOP_ID}: no gtk-launch, flatpak or gio available"
  echo "Error: cannot launch desktop entry ${DESKTOP_ID} on this system" >&2
  exit 1
fi

# If input is an executable path and executable, run it in a terminal
if [[ -f "$input" && -x "$input" ]]; then
  get_common_terminal() {
    for term in gnome-terminal xfce4-terminal konsole tilix x-terminal-emulator alacritty kitty urxvt terminator xterm; do
      if type -P "$term" >/dev/null 2>&1; then
        echo "$term"
        return
      fi
    done
    echo "xterm"
  }

  terminal="$(get_common_terminal)"
  log "Launching executable in terminal: $input via $terminal (elevate=${elevate_flag})"

  case "$terminal" in
    gnome-terminal|xfce4-terminal|x-terminal-emulator|konsole|tilix|kitty)
      CMD=("$terminal" "--" "bash" "-c" "$input; exec bash")
      ;;
    alacritty|urxvt|xterm|terminator)
      CMD=("$terminal" "-e" "$input")
      ;;
    *)
      CMD=("$input")
      ;;
  esac

  if [[ "$elevate_flag" == "as-root" ]]; then
    run_cmd_array CMD yes || { echo "Elevation failed"; exit 1; }
  else
    run_cmd_array CMD no || { echo "Launch failed"; exit 1; }
  fi
  exit 0
fi

# If first token is an available command, run it with GPU env
first_word="${input%% *}"
if type -P "$first_word" >/dev/null 2>&1; then
  log "Launching command: $input (elevate=${elevate_flag})"
  read -r -a ARGS <<< "$input"
  if [[ "$elevate_flag" == "as-root" ]]; then
    run_cmd_array ARGS yes || { echo "Elevation failed"; exit 1; }
  else
    run_cmd_array ARGS no || { echo "Launch failed"; exit 1; }
  fi
  exit 0
fi

log "Error: '$input' is not a valid executable, command, or desktop entry"
echo "Error: '$input' is not a valid executable, command, or desktop entry" >&2
exit 1
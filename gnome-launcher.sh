#!/usr/bin/env bash
set -euo pipefail

# gnome-launcher.sh
# Launch a command or executable with GPU offload, using per-user config when available.
# Adds Vulkan-aware launch: sets VK_ICD_FILENAMES when an ICD matching the vendor is found.

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

# Load configuration: prefer per-user config, fall back to system config
GPU_MODE=""
DRI_PRIME=""
PREFERRED_VULKAN_VENDOR=""
PREFERRED_VULKAN_ICD=""

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

# Prefer canonical vendor_icd.json, then normalize names removing "hasvk"
find_icd_for_vendor() {
  local vendor="$1"
  local -a search_paths=(/usr/share/vulkan/icd.d /etc/vulkan/icd.d /usr/local/share/vulkan/icd.d)
  local pattern=""
  case "$vendor" in
    NVIDIA) pattern='nvidia|nv' ;;
    AMD)    pattern='radeon|amd' ;;
    Intel)  pattern='intel|i915' ;;
    *) pattern='' ;;
  esac

  if [[ -z "$pattern" ]]; then
    printf ''
    return
  fi

  # 1) Highest priority: exact vendor_icd.json (e.g. intel_icd.json)
  for p in "${search_paths[@]}"; do
    [[ -d "$p" ]] || continue
    candidate="$p/${vendor,,}_icd.json"
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return
    fi
  done

  # 2) Normalize basenames by removing "hasvk" and prefer exact normalized name
  for p in "${search_paths[@]}"; do
    [[ -d "$p" ]] || continue
    for f in "$p"/*.json; do
      [[ -e "$f" ]] || continue
      bn="$(basename "$f")"
      bn_norm="$(printf '%s' "$bn" | sed -E 's/_?hasvk//Ig')"
      if printf '%s' "$bn_norm" | grep -qiE "^${vendor,,}(_|-)?icd\\.json$"; then
        printf '%s' "$f"
        return
      fi
    done
  done

  # 3) Accept any file whose normalized basename matches the vendor pattern
  for p in "${search_paths[@]}"; do
    [[ -d "$p" ]] || continue
    for f in "$p"/*.json; do
      [[ -e "$f" ]] || continue
      bn="$(basename "$f")"
      bn_norm="$(printf '%s' "$bn" | sed -E 's/_?hasvk//Ig')"
      if printf '%s' "$bn_norm" | grep -qiE "$pattern"; then
        printf '%s' "$f"
        return
      fi
    done
  done

  # 4) Fallback: first .json found
  for p in "${search_paths[@]}"; do
    if [[ -d "$p" ]]; then
      for f in "$p"/*.json; do [[ -e "$f" ]] || continue; printf '%s' "$f"; return; done
    fi
  done

  printf ''
}

# Map vendor heuristics (name or vendorID)
map_vendor() {
  local name="$1"
  local vendor_id="${2:-}"
  local vid_norm=""
  if [[ -n "$vendor_id" ]]; then
    vid_norm="$(printf '%s' "$vendor_id" | tr '[:upper:]' '[:lower:]' | sed -E 's/^0x//')"
  fi
  case "$vid_norm" in
    10de) printf 'NVIDIA'; return ;;
    1002) printf 'AMD'; return ;;
    8086) printf 'Intel'; return ;;
  esac
  local name_lc
  name_lc="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  if printf '%s' "$name_lc" | grep -q -E 'nvidia|geforce|quadro|rtx|gtx'; then
    printf 'NVIDIA'
  elif printf '%s' "$name_lc" | grep -q -E 'amd|radeon|rx|vega'; then
    printf 'AMD'
  elif printf '%s' "$name_lc" | grep -q -E 'intel|iris|hd graphics|uhd graphics'; then
    printf 'Intel'
  else
    printf 'Unknown'
  fi
}

# Build environment prefix for Vulkan launches based on vendor and optional DRI_PRIME index
build_vulkan_env_prefix() {
  local vendor="$1"
  local dri_index="$2"
  local icd
  icd="$(find_icd_for_vendor "$vendor")"
  local -a parts=()

  if [[ -n "$icd" ]]; then
    parts+=( "VK_ICD_FILENAMES=${icd}" )
  fi

  case "$vendor" in
    NVIDIA)
      parts=( "__NV_PRIME_RENDER_OFFLOAD=1" "__GLX_VENDOR_LIBRARY_NAME=nvidia" "${parts[@]}" )
      ;;
    AMD)
      if [[ -n "$dri_index" ]]; then
        parts=( "DRI_PRIME=${dri_index}" "${parts[@]}" )
      fi
      ;;
    Intel)
      ;;
    *)
      ;;
  esac

  # join with space for caller; caller will split safely
  printf '%s' "${parts[*]}"
}

# Helper: detect if a device name looks like a software renderer (llvmpipe, softpipe, swrast)
is_software_renderer() {
  local name_lc
  name_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if printf '%s' "$name_lc" | grep -q -E 'llvmpipe|softpipe|swrast|mesa offscreen'; then
    return 0
  fi
  return 1
}

# Probe Vulkan vendor using vulkaninfo; returns "device|vendorID" or empty
probe_vulkan_vendor() {
  if ! command -v vulkaninfo >/dev/null 2>&1; then
    return 1
  fi
  local out
  out="$(vulkaninfo 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    return 1
  fi
  local device=""
  local vendorid=""
  while IFS= read -r line; do
    if printf '%s' "$line" | grep -q -E 'deviceName[[:space:]]*='; then
      device="$(printf '%s' "$line" | sed -E 's/.*deviceName[[:space:]]*=[[:space:]]*"?//; s/"$//; s/^[[:space:]]+|[[:space:]]+$//g')"
    elif printf '%s' "$line" | grep -q -E 'vendorID[[:space:]]*='; then
      vendorid="$(printf '%s' "$line" | sed -E 's/.*vendorID[[:space:]]*=[[:space:]]*//; s/^[[:space:]]+|[[:space:]]+$//g')"
    fi
    if [[ -n "$device" && -n "$vendorid" ]]; then
      if is_software_renderer "$device"; then
        device=""; vendorid=""
        continue
      fi
      printf '%s|%s' "$device" "$vendorid"
      return 0
    fi
  done <<< "$out"
  return 1
}

# Run with env prefix (prefix may be empty). Split safely into array for env.
run_with_env() {
  local env_prefix="$1"
  local cmd="$2"
  if [[ -n "$env_prefix" ]]; then
    # split on spaces but preserve quoted segments (simple split)
    IFS=' ' read -r -a env_parts <<< "$env_prefix"
    env "${env_parts[@]}" bash -c "$cmd"
  else
    bash -c "$cmd"
  fi
}

# Existing GL/DRI_PRIME/NVIDIA behavior
launch_with_gpu() {
  local cmd="$1"
  if [[ "${GPU_MODE:-}" == "NVIDIA_RENDER_OFFLOAD" || "${GPU_MODE:-}" == "NVIDIA" ]]; then
    env __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia bash -c "$cmd"
  else
    local dpi="${DRI_PRIME:-1}"
    env DRI_PRIME="$dpi" bash -c "$cmd"
  fi
}

# Vulkan-aware launcher
launch_vulkan() {
  local cmd="$1"
  local vendor=""
  local vendorid=""
  local probe

  probe="$(probe_vulkan_vendor 2>/dev/null || true)"
  if [[ -n "$probe" ]]; then
    vendor="$(printf '%s' "$probe" | cut -d'|' -f1)"
    vendorid="$(printf '%s' "$probe" | cut -d'|' -f2 -s)"
    vendor="$(map_vendor "$vendor" "$vendorid")"
  else
    # fallback to config hints
    if [[ -n "$PREFERRED_VULKAN_VENDOR" ]]; then
      vendor="$PREFERRED_VULKAN_VENDOR"
    elif [[ "${GPU_MODE:-}" == "NVIDIA_RENDER_OFFLOAD" || "${GPU_MODE:-}" == "NVIDIA" ]]; then
      vendor="NVIDIA"
    fi
  fi

  # best-effort DRI_PRIME index detection
  local dri_index=""
  if command -v glxinfo >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    for j in $(seq 0 15); do
      out="$(timeout 0.5s env DRI_PRIME="$j" glxinfo 2>/dev/null || true)"
      if [[ -n "$out" ]] && printf '%s' "$out" | grep -qiF "$(printf '%s' "$vendor" | cut -c1-20)"; then
        dri_index="$j"
        break
      fi
    done
  fi

  local env_prefix
  env_prefix="$(build_vulkan_env_prefix "$vendor" "$dri_index")"

  if [[ -z "$env_prefix" ]]; then
    if [[ "${GPU_MODE:-}" == "NVIDIA_RENDER_OFFLOAD" || "${GPU_MODE:-}" == "NVIDIA" ]]; then
      env_prefix="__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia"
    else
      env_prefix="DRI_PRIME=${DRI_PRIME:-1}"
    fi
  fi

  run_with_env "$env_prefix" "$cmd"
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

  is_vulkan_app=false
  if [[ "$first_word" == vulkan:* ]]; then
    input="${input#vulkan:}"
    is_vulkan_app=true
  elif printf '%s' "$first_word" | grep -qiE '(^vk|vulkan|vkcube|vkcube)'; then
    is_vulkan_app=true
  fi

  if [[ "$is_vulkan_app" == true ]]; then
    launch_vulkan "$input" &
  else
    launch_with_gpu "$input" &
  fi

  exit 0
fi

echo "Error: '$input' is not a valid executable or command."
exit 1

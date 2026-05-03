#!/usr/bin/env bash
set -euo pipefail

# manual-setup.sh
# Usage:
#   ./manual-setup.sh
#   ./manual-setup.sh --command "firefox"
#   ./manual-setup.sh --command "vkcube" --vulkan
#   ./manual-setup.sh --vulkan

INSTALL_BASE="/opt/rgb-gpus-teaming"
SYSTEM_CONFIG_DIR="$INSTALL_BASE/config"
SYSTEM_MEM_FILE="$SYSTEM_CONFIG_DIR/gpu_launcher_config"
USER_MEM_FILE="$HOME/.gpu_launcher_config"

REAL_USER="${SUDO_USER:-$(id -un 2>/dev/null || true)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 2>/dev/null || true)"
REAL_HOME="${REAL_HOME:-$HOME}"

VERBOSE=true
NONINTERACTIVE=false
CMD=""
FORCE_VULKAN=false
LOGFILE="/tmp/vulkan-launch.log"

log() { [[ "$VERBOSE" == true ]] && printf '[%s] %s\n' "$(date +'%F %T')" "$*" | tee -a "$LOGFILE"; }
err() { printf 'Error: %s\n' "$*" >&2 | tee -a "$LOGFILE"; }

usage() {
  cat <<EOF
Usage:
  $0 [options]

Options:
  --command, -c "<cmd>"   Run <cmd> immediately (non-interactive).
  --non-interactive       Do not prompt; use saved config (if any).
  --vulkan                Force Vulkan-aware launch for the provided command.
  --help, -h              Show this help and exit.
EOF
}

# Safe read from the controlling terminal to avoid consuming stdin content
read_line() {
  local prompt="$1"
  local __tmp=""
  if [[ -c /dev/tty ]]; then
    read -r -p "$prompt" __tmp < /dev/tty 2>/dev/tty || true
    printf '%s' "$__tmp"
  else
    printf ''
  fi
}

# Parse args
while (( "$#" )); do
  case "$1" in
    --command|-c)
      if [[ -z "${2:-}" ]]; then err "--command requires an argument"; exit 2; fi
      CMD="$2"; NONINTERACTIVE=true; shift 2 ;;
    --non-interactive) NONINTERACTIVE=true; shift ;;
    --vulkan) FORCE_VULKAN=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) err "Unknown argument: $1"; exit 2 ;;
  esac
done

: > "$LOGFILE"

# Choose config file
if [[ "$(id -u)" -eq 0 ]]; then
  MEM_FILE="$SYSTEM_MEM_FILE"
  log "Running as root; using system config: $MEM_FILE"
else
  MEM_FILE="$USER_MEM_FILE"
  log "Running as user; using user config: $MEM_FILE"
fi

if [[ "$(id -u)" -eq 0 ]]; then
  mkdir -p "$SYSTEM_CONFIG_DIR"
  chmod 0755 "$SYSTEM_CONFIG_DIR"
fi

# Load existing config safely
GPU_MODE=""
DRI_PRIME=""
PREFERRED_VULKAN_VENDOR=""
PREFERRED_VULKAN_ICD=""

if [[ -f "$MEM_FILE" ]]; then
  (
    set +e
    # shellcheck disable=SC1090
    source "$MEM_FILE" 2>/dev/null || true
    printf 'GPU_MODE=%s\nDRI_PRIME=%s\nPREFERRED_VULKAN_VENDOR=%s\nPREFERRED_VULKAN_ICD=%s\n' "${GPU_MODE:-}" "${DRI_PRIME:-}" "${PREFERRED_VULKAN_VENDOR:-}" "${PREFERRED_VULKAN_ICD:-}"
  ) > /tmp/.gpu_cfg.$$ || true
  GPU_MODE="$(awk -F= '/^GPU_MODE=/ {sub(/^GPU_MODE=/,""); print}' /tmp/.gpu_cfg.$$ || true)"
  DRI_PRIME="$(awk -F= '/^DRI_PRIME=/ {sub(/^DRI_PRIME=/,""); print}' /tmp/.gpu_cfg.$$ || true)"
  PREFERRED_VULKAN_VENDOR="$(awk -F= '/^PREFERRED_VULKAN_VENDOR=/ {sub(/^PREFERRED_VULKAN_VENDOR=/,""); print}' /tmp/.gpu_cfg.$$ || true)"
  PREFERRED_VULKAN_ICD="$(awk -F= '/^PREFERRED_VULKAN_ICD=/ {sub(/^PREFERRED_VULKAN_ICD=/,""); print}' /tmp/.gpu_cfg.$$ || true)"
  rm -f /tmp/.gpu_cfg.$$ 2>/dev/null || true
  log "Loaded existing config: GPU_MODE=${GPU_MODE:-<none>} DRI_PRIME=${DRI_PRIME:-<none>} PREFERRED_VULKAN_VENDOR=${PREFERRED_VULKAN_VENDOR:-<none>} PREFERRED_VULKAN_ICD=${PREFERRED_VULKAN_ICD:-<none>}"
else
  log "No existing config at $MEM_FILE"
fi

if [[ "$NONINTERACTIVE" == true && -z "${GPU_MODE:-}" && -z "$CMD" ]]; then
  err "No saved GPU configuration found; run interactively first to create one."
  exit 3
fi

# ---------------------------
# Helpers
# ---------------------------

is_software_renderer() {
  local name_lc
  name_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if printf '%s' "$name_lc" | grep -qiE 'llvmpipe|softpipe|swrast|mesa offscreen'; then
    return 0
  fi
  return 1
}

probe_vulkan_vendor() {
  if ! command -v vulkaninfo >/dev/null 2>&1; then
    return 1
  fi
  local out device vendorid
  out="$(vulkaninfo 2>/dev/null || true)"
  if [[ -z "$out" ]]; then return 1; fi
  device=""; vendorid=""
  while IFS= read -r line; do
    line="$(printf '%s' "$line" | tr -d '\000')"
    if printf '%s' "$line" | grep -q -E 'deviceName[[:space:]]*='; then
      device="$(printf '%s' "$line" | sed -E 's/.*deviceName[[:space:]]*=[[:space:]]*"?//; s/"$//; s/^[[:space:]]+|[[:space:]]+$//g')"
    elif printf '%s' "$line" | grep -q -E 'vendorID[[:space:]]*='; then
      vendorid="$(printf '%s' "$line" | sed -E 's/.*vendorID[[:space:]]*=[[:space:]]*//; s/^[[:space:]]+|[[:space:]]+$//g')"
    fi
    if [[ -n "$device" && -n "$vendorid" ]]; then
      if is_software_renderer "$device"; then device=""; vendorid=""; continue; fi
      printf '%s|%s' "$device" "$vendorid"
      return 0
    fi
  done <<< "$out"
  return 1
}

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
  if [[ -z "$pattern" ]]; then printf ''; return 0; fi

  # 1) If an exact vendor_icd.json exists, return it (highest priority)
  for p in "${search_paths[@]}"; do
    [[ -d "$p" ]] || continue
    candidate="$p/${vendor,,}_icd.json"
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  # 2) Otherwise, scan files but normalize names by removing "hasvk" (case-insensitive)
  for p in "${search_paths[@]}"; do
    [[ -d "$p" ]] || continue
    for f in "$p"/*.json; do
      [[ -e "$f" ]] || continue
      bn="$(basename "$f")"
      bn_norm="$(printf '%s' "$bn" | sed -E 's/_?hasvk//Ig')"
      if printf '%s' "$bn_norm" | grep -qiE "^${vendor,,}(_|-)?icd\\.json$"; then
        printf '%s' "$f"
        return 0
      fi
    done
  done

  # 3) Next, accept any file whose normalized basename matches the vendor pattern
  for p in "${search_paths[@]}"; do
    [[ -d "$p" ]] || continue
    for f in "$p"/*.json; do
      [[ -e "$f" ]] || continue
      bn="$(basename "$f")"
      bn_norm="$(printf '%s' "$bn" | sed -E 's/_?hasvk//Ig')"
      if printf '%s' "$bn_norm" | grep -qiE "$pattern"; then
        printf '%s' "$f"
        return 0
      fi
    done
  done

  # 4) Fallback: first .json found (existing behavior)
  for p in "${search_paths[@]}"; do
    if [[ -d "$p" ]]; then
      for f in "$p"/*.json; do [[ -e "$f" ]] || continue; printf '%s' "$f"; return 0; done
    fi
  done

  printf ''; return 0
}

# Build env array with priority: explicit config -> GPU_MODE -> probe vendor
build_vulkan_env_array() {
  local vendor="$1" dri_index="$2" icd
  local -a arr=()

  # 1) If explicit ICD chosen by user, use it
  if [[ -n "${PREFERRED_VULKAN_ICD:-}" ]]; then
    arr+=( "VK_ICD_FILENAMES=${PREFERRED_VULKAN_ICD}" )
    printf '%s\n' "${arr[@]:-}"
    return 0
  fi

  # 2) If GPU_MODE is DRI_PRIME and DRI_PRIME set, prefer DRI_PRIME only
  if [[ "${GPU_MODE:-}" == "DRI_PRIME" && -n "${DRI_PRIME:-}" ]]; then
    arr+=( "DRI_PRIME=${DRI_PRIME}" )
    printf '%s\n' "${arr[@]:-}"
    return 0
  fi

  # 3) If GPU_MODE is NVIDIA_RENDER_OFFLOAD, prefer NVIDIA env + ICD
  if [[ "${GPU_MODE:-}" == "NVIDIA_RENDER_OFFLOAD" ]]; then
    icd="$(find_icd_for_vendor "NVIDIA")"
    [[ -n "$icd" ]] && arr+=( "VK_ICD_FILENAMES=$icd" )
    arr+=( "__NV_PRIME_RENDER_OFFLOAD=1" "__GLX_VENDOR_LIBRARY_NAME=nvidia" "__VK_LAYER_NV_optimus=NVIDIA_only" )
    printf '%s\n' "${arr[@]:-}"
    return 0
  fi

  # 4) Fallback: use vendor argument (from probe or preference)
  icd="$(find_icd_for_vendor "$vendor")"
  if [[ -n "$icd" ]]; then arr+=( "VK_ICD_FILENAMES=$icd" ); fi
  case "$vendor" in
    NVIDIA) arr+=( "__NV_PRIME_RENDER_OFFLOAD=1" "__GLX_VENDOR_LIBRARY_NAME=nvidia" "__VK_LAYER_NV_optimus=NVIDIA_only" ) ;;
    AMD)    [[ -n "$dri_index" ]] && arr+=( "DRI_PRIME=$dri_index" ) ;;
    Intel)  ;;
  esac
  printf '%s\n' "${arr[@]:-}"
}

# Determine the graphical user (best-effort)
detect_graphical_user() {
  if [[ -n "${SUDO_USER:-}" ]]; then
    printf '%s' "$SUDO_USER"
    return 0
  fi
  if command -v loginctl >/dev/null 2>&1; then
    local sess user
    sess="$(loginctl list-sessions --no-legend | awk '{print $1}' | head -n1 || true)"
    if [[ -n "$sess" ]]; then
      user="$(loginctl show-session "$sess" -p Name --value 2>/dev/null || true)"
      if [[ -n "$user" ]]; then
        printf '%s' "$user"
        return 0
      fi
    fi
    user="$(loginctl list-sessions --no-legend | awk '{print $3}' | head -n1 || true)"
    if [[ -n "$user" ]]; then
      printf '%s' "$user"
      return 0
    fi
  fi
  user="$(who | awk '{print $1}' | head -n1 || true)"
  if [[ -n "$user" ]]; then
    printf '%s' "$user"
    return 0
  fi
  printf '%s' "$REAL_USER"
  return 0
}

# Run command with proper graphical env (and log)
run_with_graphical_env() {
  local run_cmd="$1"
  local vendor="$2"
  local -a env_array
  mapfile -t env_array < <(build_vulkan_env_array "$vendor" "$DRI_PRIME" || true)

  local GUSER
  GUSER="$(detect_graphical_user)"
  local GUID
  GUID="$(id -u "$GUSER" 2>/dev/null || echo "$(id -u)")"

  local USE_DISPLAY="${DISPLAY:-:0}"
  local USE_XDG="${XDG_RUNTIME_DIR:-/run/user/$GUID}"
  local USE_WAYLAND="${WAYLAND_DISPLAY:-}"

  local -a env_args=()
  for a in "${env_array[@]}"; do
    env_args+=( "$a" )
  done
  env_args+=( "DISPLAY=$USE_DISPLAY" "XDG_RUNTIME_DIR=$USE_XDG" )
  [[ -n "$USE_WAYLAND" ]] && env_args+=( "WAYLAND_DISPLAY=$USE_WAYLAND" )

  # Debug: log env to be passed
  printf '\n-- Debug env (to be passed) --\n' >> "$LOGFILE"
  for e in "${env_args[@]}"; do printf '%s\n' "$e" >> "$LOGFILE"; done
  printf '\n' >> "$LOGFILE"

  log "Running command as user='$GUSER' (uid=$GUID) with env: ${env_args[*]}"
  log "Command: $run_cmd"

  if [[ "$(id -u)" -eq 0 && -n "$GUSER" ]]; then
    sudo -u "$GUSER" env "${env_args[@]}" bash -lc "$run_cmd" >> "$LOGFILE" 2>&1 || return $?
  else
    env "${env_args[@]}" bash -lc "$run_cmd" >> "$LOGFILE" 2>&1 || return $?
  fi
  return 0
}

# ---------------------------
# Vulkan device selection helper (menu integration)
# ---------------------------

select_vulkan_preference() {
  # Collect devices from vulkaninfo, but skip llvmpipe and vendorID 0x10005
  devices=()
  if command -v vulkaninfo >/dev/null 2>&1; then
    cur_name=""; cur_vendor=""
    while IFS= read -r line; do
      l="$line"
      if printf '%s' "$l" | grep -q -E 'deviceName[[:space:]]*='; then
        name="$(printf '%s' "$l" | sed -E 's/.*deviceName[[:space:]]*=[[:space:]]*"?//; s/"$//; s/^[[:space:]]+|[[:space:]]+$//g')"
        cur_name="$name"
      fi
      if printf '%s' "$l" | grep -q -E 'vendorID[[:space:]]*='; then
        cur_vendor="$(printf '%s' "$l" | sed -E 's/.*vendorID[[:space:]]*=[[:space:]]*//; s/^[[:space:]]+|[[:space:]]+$//')"
      fi
      if [[ -n "$cur_name" && -n "$cur_vendor" ]]; then
        # Normalize for checks
        name_lc="$(printf '%s' "$cur_name" | tr '[:upper:]' '[:lower:]')"
        vendor_norm="$(printf '%s' "$cur_vendor" | tr '[:upper:]' '[:lower:]')"
        # Skip llvmpipe or vendorID 0x10005
        if printf '%s' "$name_lc" | grep -qi 'llvmpipe'; then
          cur_name=""; cur_vendor=""; continue
        fi
        if [[ "$vendor_norm" == "0x10005" || "$vendor_norm" == "10005" ]]; then
          cur_name=""; cur_vendor=""; continue
        fi
        devices+=( "$cur_name|$cur_vendor" )
        cur_name=""; cur_vendor=""
      fi
    done < <(vulkaninfo 2>/dev/null || true)
  fi

  # Fallback to probe_vulkan_vendor (probe already filters software renderers)
  if [[ "${#devices[@]}" -eq 0 ]]; then
    probe="$(probe_vulkan_vendor 2>/dev/null || true)"
    if [[ -n "$probe" ]]; then
      # probe returns "name|vendorid" — skip if llvmpipe or vendorID 0x10005
      p_name="$(printf '%s' "$probe" | cut -d'|' -f1)"
      p_vid="$(printf '%s' "$probe" | cut -d'|' -f2 -s)"
      p_name_lc="$(printf '%s' "$p_name" | tr '[:upper:]' '[:lower:]')"
      p_vid_norm="$(printf '%s' "$p_vid" | tr '[:upper:]' '[:lower:]')"
      if ! printf '%s' "$p_name_lc" | grep -qi 'llvmpipe' && [[ "$p_vid_norm" != "0x10005" && "$p_vid_norm" != "10005" ]]; then
        devices+=( "$probe" )
      fi
    fi
  fi

  # Present choices (same UI as before)
  if [[ "${#devices[@]}" -gt 0 ]]; then
    echo "Detected Vulkan devices:"
    i=1
    for d in "${devices[@]}"; do
      name="$(printf '%s' "$d" | cut -d'|' -f1)"
      vid="$(printf '%s' "$d" | cut -d'|' -f2 -s)"
      printf '  %d) %s (vendorID=%s)\n' "$i" "$name" "$vid"
      i=$((i+1))
    done
    printf '  %d) Manual vendor/ICD entry\n' "$i"
    choice="$(read_line "Choose device to prefer for Vulkan launches [1-$i]: ")"
    if [[ -n "$choice" && "$choice" =~ ^[0-9]+$ ]]; then
      if (( choice >= 1 && choice < i )); then
        sel_index=$((choice-1))
        sel="${devices[$sel_index]}"
        sel_name="$(printf '%s' "$sel" | cut -d'|' -f1)"
        sel_vid="$(printf '%s' "$sel" | cut -d'|' -f2 -s)"
        case "$(printf '%s' "$sel_vid" | tr '[:upper:]' '[:lower:]' | sed -E 's/^0x//')" in
          10de) PREFERRED_VULKAN_VENDOR="NVIDIA" ;;
          1002) PREFERRED_VULKAN_VENDOR="AMD" ;;
          8086) PREFERRED_VULKAN_VENDOR="Intel" ;;
          *) PREFERRED_VULKAN_VENDOR="" ;;
        esac
        icd_candidate="$(find_icd_for_vendor "${PREFERRED_VULKAN_VENDOR:-}" || true)"
        if [[ -n "$icd_candidate" ]]; then
          PREFERRED_VULKAN_ICD="$icd_candidate"
          printf 'Selected device: %s -> vendor=%s, ICD=%s\n' "$sel_name" "${PREFERRED_VULKAN_VENDOR:-<unknown>}" "$PREFERRED_VULKAN_ICD"
        else
          PREFERRED_VULKAN_ICD=""
          printf 'Selected device: %s -> vendor=%s (no ICD auto-found)\n' "$sel_name" "${PREFERRED_VULKAN_VENDOR:-<unknown>}"
        fi
      else
        manual="$(read_line "Enter vendor (NVIDIA, AMD, Intel) or full path to ICD JSON: ")"
        if [[ -n "$manual" ]]; then
          if [[ -f "$manual" ]]; then
            PREFERRED_VULKAN_ICD="$manual"
            PREFERRED_VULKAN_VENDOR=""
            printf 'Using ICD file: %s\n' "$PREFERRED_VULKAN_ICD"
          else
            manual_u="$(printf '%s' "$manual" | tr '[:lower:]' '[:upper:]')"
            case "$manual_u" in
              NVIDIA|AMD|INTEL)
                PREFERRED_VULKAN_VENDOR="$manual_u"
                PREFERRED_VULKAN_ICD="$(find_icd_for_vendor "$PREFERRED_VULKAN_VENDOR" || true)"
                printf 'Preferred vendor set to: %s (ICD=%s)\n' "$PREFERRED_VULKAN_VENDOR" "${PREFERRED_VULKAN_ICD:-<none>}"
                ;;
              *)
                echo "Unrecognized input; no change."
                ;;
            esac
          fi
        fi
      fi
    else
      echo "No valid choice entered; keeping previous preference."
    fi
  else
    echo "No Vulkan devices detected by vulkaninfo."
    manual="$(read_line "Enter vendor (NVIDIA, AMD, Intel) or full path to ICD JSON (or leave empty): ")"
    if [[ -n "$manual" ]]; then
      if [[ -f "$manual" ]]; then
        PREFERRED_VULKAN_ICD="$manual"
        PREFERRED_VULKAN_VENDOR=""
      else
        manual_u="$(printf '%s' "$manual" | tr '[:lower:]' '[:upper:]')"
        case "$manual_u" in
          NVIDIA|AMD|INTEL)
            PREFERRED_VULKAN_VENDOR="$manual_u"
            PREFERRED_VULKAN_ICD="$(find_icd_for_vendor "$PREFERRED_VULKAN_VENDOR" || true)"
            ;;
          *)
            echo "No valid input"
            ;;
        esac
      fi
    fi
  fi

  # If GPU_MODE is DRI_PRIME, allow setting numeric DRI_PRIME
  if [[ "${GPU_MODE:-}" == "DRI_PRIME" ]]; then
    dprompt="$(read_line "DRI_PRIME is active. Enter DRI_PRIME index to use (current: ${DRI_PRIME:-<unset>}) or press Enter to keep: ")"
    if [[ -n "$dprompt" ]]; then
      if printf '%s' "$dprompt" | grep -Eq '^[0-9]+$'; then
        DRI_PRIME="$dprompt"
        printf 'Set DRI_PRIME=%s\n' "$DRI_PRIME"
      else
        echo "Invalid DRI_PRIME; ignoring."
      fi
    fi
  fi
}

# ---------------------------
# Main flow
# ---------------------------

# If --vulkan was passed, skip the mode menu entirely and go straight to command prompt/execution.
if [[ "$FORCE_VULKAN" != true && "$NONINTERACTIVE" != true && -z "$CMD" ]]; then
  echo
  echo "Select GPU launch mode (press Enter to reuse saved configuration):"
  echo "1) Intel / AMD / NVIDIA (DRI_PRIME)"
  echo "2) NVIDIA (Render Offload)"
  echo "3) Configure Vulkan preference (probe and choose vendor)"
  mode="$(read_line "Choice (1, 2 or 3): ")"

  if [[ -z "$mode" ]]; then
    if [[ -n "${GPU_MODE:-}" ]]; then
      log "Reusing saved configuration: GPU_MODE=$GPU_MODE"
      echo "Reusing saved configuration: ${GPU_MODE:-<none>}"
    else
      echo "No saved configuration; please choose an option."
      mode="$(read_line "Choice (1, 2 or 3): ")"
    fi
  fi

  if [[ -n "$mode" ]]; then
    case "$mode" in
      1)
        dri_value="$(read_line "Enter DRI_PRIME value (e.g., 0,1,2): ")"
        if [[ ! "$dri_value" =~ ^[0-9]+$ ]]; then err "DRI_PRIME must be a non-negative integer"; exit 1; fi
        DRI_PRIME="$dri_value"; GPU_MODE="DRI_PRIME"
        printf 'DRI_PRIME mode enabled with DRI_PRIME=%s\n' "$DRI_PRIME"
        ;;
      2)
        GPU_MODE="NVIDIA_RENDER_OFFLOAD"; unset DRI_PRIME
        printf 'NVIDIA Render Offload mode selected\n'
        ;;
      3)
        select_vulkan_preference
        ;;
      *)
        err "Invalid choice"; exit 1
        ;;
    esac

    # Persist config
    if [[ "$(id -u)" -eq 0 ]]; then mkdir -p "$(dirname "$MEM_FILE")"; fi
    {
      printf 'GPU_MODE="%s"\n' "${GPU_MODE:-}"
      if [[ -n "${DRI_PRIME:-}" ]]; then printf 'DRI_PRIME="%s"\n' "${DRI_PRIME:-}"; else printf 'DRI_PRIME=""\n'; fi
      printf 'PREFERRED_VULKAN_VENDOR="%s"\n' "${PREFERRED_VULKAN_VENDOR:-}"
      printf 'PREFERRED_VULKAN_ICD="%s"\n' "${PREFERRED_VULKAN_ICD:-}"
    } > "$MEM_FILE"
    if [[ "$(id -u)" -eq 0 && -n "$REAL_USER" ]]; then
      if id -u "$REAL_USER" >/dev/null 2>&1; then
        chown "$REAL_USER":"$REAL_USER" "$MEM_FILE" 2>/dev/null || true
      fi
    fi
    chmod 0644 "$MEM_FILE" 2>/dev/null || true
    log "Wrote config to $MEM_FILE"
    echo "Configuration saved to $MEM_FILE"
  fi
fi

# Determine command to run
if [[ -n "$CMD" ]]; then
  user_cmd="$CMD"
else
  if [[ ! -t 0 ]]; then err "No TTY available to prompt for a command; use --command"; exit 5; fi
  if [[ "$FORCE_VULKAN" == true ]]; then
    read -r -e -p "Vulkan mode forced. Command to run (or press Enter to exit): " user_cmd < /dev/tty 2>/dev/tty || true
  else
    read -r -e -p "Command to run (or press Enter to exit): " user_cmd < /dev/tty 2>/dev/tty || true
  fi
  if [[ -z "${user_cmd// /}" ]]; then log "No command entered; exiting."; exit 0; fi
fi

echo
echo "Executing command with GPU mode: ${GPU_MODE:-<none>}"
echo

# Heuristic: treat as Vulkan app if forced or name contains vk/vulkan
is_vulkan_app=false
if [[ "$FORCE_VULKAN" == true ]]; then
  is_vulkan_app=true
else
  first_word="${user_cmd%% *}"
  if printf '%s' "$first_word" | grep -qiE '(^vk|vulkan|vkcube|vktrace|vulkaninfo)'; then
    is_vulkan_app=true
  fi
fi

if [[ "$is_vulkan_app" == true ]]; then
  log "Launching as Vulkan application"
  vendor="$PREFERRED_VULKAN_VENDOR"
  if [[ -z "$vendor" ]]; then
    probe="$(probe_vulkan_vendor 2>/dev/null || true)"
    if [[ -n "$probe" ]]; then
      vendorid="$(printf '%s' "$probe" | cut -d'|' -f2 -s)"
      case "$(printf '%s' "$vendorid" | tr '[:upper:]' '[:lower:]' | sed -E 's/^0x//')" in
        10de) vendor="NVIDIA" ;;
        1002) vendor="AMD" ;;
        8086) vendor="Intel" ;;
      esac
    fi
  fi

  # Build proposal env and show to user
  mapfile -t proposal_env < <(build_vulkan_env_array "$vendor" "$DRI_PRIME" || true)
  echo
  echo "Vulkan launch proposal:"
  if [[ "${#proposal_env[@]}" -gt 0 ]]; then
    for e in "${proposal_env[@]}"; do echo "  $e"; done
  else
    echo "  No vendor-specific env detected; will fall back to saved GPU_MODE/DRI_PRIME behavior."
  fi
  echo "  Command: $user_cmd"
  echo

  if [[ "$NONINTERACTIVE" == true || -n "$CMD" || ! -t 0 ]]; then
    yn="y"
  else
    read -r -p "Run with the above environment? (Y/n): " yn < /dev/tty 2>/dev/tty || true
  fi

  if [[ -z "$yn" || "${yn,,}" == "y" || "${yn,,}" == "yes" ]]; then
    run_with_graphical_env "$user_cmd" "$vendor" || { err "Execution failed; voir $LOGFILE"; exit 1; }
  else
    echo "Aborted by user."
    exit 0
  fi
else
  log "Launching non-Vulkan application"
  run_with_graphical_env "$user_cmd" "${PREFERRED_VULKAN_VENDOR:-}" || { err "Execution failed; voir $LOGFILE"; exit 1; }
fi

log "Done"
exit 0

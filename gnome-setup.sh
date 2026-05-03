#!/usr/bin/env bash
set -euo pipefail

# gnome-setup.sh
# Interactive helper to choose GPU launch mode and persist it per-user.
# Writes config to: $USER_HOME/.config/rgb-gpus-teaming/gpu_launcher_gnome_config

INSTALL_BASE="/opt/rgb-gpus-teaming"
SYSTEM_CONFIG_DIR="$INSTALL_BASE/config"
SYSTEM_MEM_FILE="$SYSTEM_CONFIG_DIR/gpu_launcher_gnome_config"

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"

USER_CONFIG_DIR="${XDG_CONFIG_HOME:-$TARGET_HOME/.config}/rgb-gpus-teaming"
USER_MEM_FILE="$USER_CONFIG_DIR/gpu_launcher_gnome_config"

read_line() { read -r -p "$1" __tmp; printf '%s' "$__tmp"; }
read_choice_simple() { read -r -p "$1" __tmp; printf '%s' "${__tmp:-}"; }

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Running as user: $USER (will write per-user config to $USER_MEM_FILE)"
else
    if [[ -z "$TARGET_USER" || -z "$TARGET_HOME" ]]; then
        printf '%s\n' "Error: could not determine target user or home directory." >&2
        exit 1
    fi
    echo "Running as root; will write per-user config for: $TARGET_USER -> $USER_MEM_FILE"
fi

mkdir -p "$USER_CONFIG_DIR"
chmod 0755 "$USER_CONFIG_DIR"
if [[ "$(id -u)" -eq 0 ]]; then
    chown "$TARGET_USER":"$TARGET_USER" "$USER_CONFIG_DIR" 2>/dev/null || true
fi

GPU_MODE=""
DRI_PRIME=""
PREFERRED_VULKAN_VENDOR=""
PREFERRED_VULKAN_ICD=""

if [[ -f "$USER_MEM_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$USER_MEM_FILE"
    printf 'Last mode used: %s\n' "${GPU_MODE:-<none>}"
    printf 'Last DRI_PRIME index: %s\n' "${DRI_PRIME:-<none>}"
    printf 'Last preferred Vulkan vendor: %s\n' "${PREFERRED_VULKAN_VENDOR:-<none>}"
    printf 'Last preferred Vulkan ICD: %s\n' "${PREFERRED_VULKAN_ICD:-<none>}"
fi

echo
echo "What type of GPU do you want to use?"
echo "Note: DRI_PRIME is experimental for NVIDIA under Wayland. Render Offload is preferred for NVIDIA."
echo "1) DRI_PRIME (Intel/AMD/discrete via DRI_PRIME)"
echo "2) NVIDIA Render Offload"
echo "3) Configure Vulkan preference / probe Vulkan ICD and choose vendor"
mode="$(read_choice_simple "Your choice (1, 2 or 3): ")"

if [[ -z "$mode" ]]; then
    echo "No choice entered. Exiting."
    exit 1
fi

# Helpers
is_software_renderer() {
  local name_lc
  name_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if printf '%s' "$name_lc" | grep -q -E 'llvmpipe|softpipe|swrast|mesa offscreen'; then
    return 0
  fi
  return 1
}

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

# Prefer a canonical vendor_icd.json (intel_icd.json) then normalize names removing "hasvk"
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
    return 0
  fi

  # 1) If exact vendor_icd.json exists, return it (highest priority)
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

  printf ''
}

# Probe Vulkan devices via vulkaninfo; return newline-separated canonical vendors (Intel/AMD/NVIDIA)
probe_vulkan_vendors() {
  if ! command -v vulkaninfo >/dev/null 2>&1; then
    return 0
  fi
  local out
  out="$(vulkaninfo 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    return 0
  fi

  local device=""
  local vendorid=""
  local -a vendors=()
  while IFS= read -r line; do
    # remove any NUL bytes just in case
    line="$(printf '%s' "$line" | tr -d '\000')"
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
      v="$(map_vendor "$device" "$vendorid")"
      if [[ "$v" != "Unknown" ]]; then
        vendors+=("$v")
      fi
      device=""; vendorid=""
    fi
  done <<< "$out"

  # print unique vendors
  if [[ "${#vendors[@]}" -gt 0 ]]; then
    printf '%s\n' "${vendors[@]}" | awk '!seen[$0]++'
  fi
}

# Probe GL renderers via glxinfo across DRI_PRIME 0..15
probe_glx_vendors() {
  if ! command -v glxinfo >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
    return 0
  fi
  local -a vendors=()
  for i in $(seq 0 15); do
    out="$(timeout 0.5s env DRI_PRIME="$i" glxinfo 2>/dev/null || true)"
    if [[ -z "$out" ]]; then
      continue
    fi
    vendor_line="$(printf '%s\n' "$out" | grep -m1 -E 'OpenGL vendor string|OpenGL renderer string|Device:' || true)"
    if [[ -z "$vendor_line" ]]; then
      continue
    fi
    gpu_name="$(printf '%s' "$vendor_line" | sed -E 's/.*(OpenGL vendor string:|OpenGL renderer string:|Device:)[[:space:]]*//; s/^[[:space:]]+|[[:space:]]+$//g')"
    if [[ -z "$gpu_name" ]]; then
      continue
    fi
    if is_software_renderer "$gpu_name"; then
      continue
    fi
    v="$(map_vendor "$gpu_name" "")"
    if [[ "$v" != "Unknown" ]]; then
      vendors+=("$v")
    fi
  done
  if [[ "${#vendors[@]}" -gt 0 ]]; then
    printf '%s\n' "${vendors[@]}" | awk '!seen[$0]++'
  fi
}

# Probe lspci for vendors
probe_lspci_vendors() {
  if ! command -v lspci >/dev/null 2>&1; then
    return 0
  fi
  local -a vendors=()
  while IFS= read -r line; do
    # sanitize line
    line="$(printf '%s' "$line" | tr -d '\000')"
    desc="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[^:]+:[[:space:]]*//')"
    pci_pair="$(printf '%s' "$line" | grep -oE '[0-9a-fA-F]{4}:[0-9a-fA-F]{4}' || true)"
    vendor_id=""
    if [[ -n "$pci_pair" ]]; then
      vendor_id="$(printf '%s' "$pci_pair" | head -n1 | cut -d: -f1)"
    fi
    v="$(map_vendor "$desc" "$vendor_id")"
    if [[ "$v" != "Unknown" ]]; then
      vendors+=("$v")
    fi
  done < <(lspci -nn | grep -E "VGA|3D" || true)

  if [[ "${#vendors[@]}" -gt 0 ]]; then
    printf '%s\n' "${vendors[@]}" | awk '!seen[$0]++'
  fi
}

# Collect vendors from all probes and return unique, filtered list (Intel/AMD/NVIDIA)
collect_all_vendors() {
  local -a all=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && all+=("$line")
  done < <(probe_vulkan_vendors)
  while IFS= read -r line; do
    [[ -n "$line" ]] && all+=("$line")
  done < <(probe_glx_vendors)
  while IFS= read -r line; do
    [[ -n "$line" ]] && all+=("$line")
  done < <(probe_lspci_vendors)

  if [[ "${#all[@]}" -eq 0 ]]; then
    return 0
  fi

  # keep only recognized vendors and unique
  printf '%s\n' "${all[@]}" | awk '!seen[$0]++' | grep -E '^(Intel|AMD|NVIDIA)$' || true
}

case "$mode" in
    1)
        dri_value="$(read_line "Enter the DRI_PRIME value to use (e.g., 0, 1, 2...): ")"
        if [[ ! "$dri_value" =~ ^[0-9]+$ ]]; then
            echo "Invalid DRI_PRIME value: must be a non-negative integer."
            exit 1
        fi
        DRI_PRIME="$dri_value"
        GPU_MODE="DRI_PRIME"
        printf 'DRI_PRIME mode enabled with DRI_PRIME=%s\n' "$DRI_PRIME"

        if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
            echo "Warning: DRI_PRIME may not work reliably with NVIDIA under Wayland."
        fi

        {
            printf 'GPU_MODE="%s"\n' "$GPU_MODE"
            printf 'DRI_PRIME="%s"\n' "$DRI_PRIME"
            printf 'PREFERRED_VULKAN_VENDOR="%s"\n' "${PREFERRED_VULKAN_VENDOR:-}"
            printf 'PREFERRED_VULKAN_ICD="%s"\n' "${PREFERRED_VULKAN_ICD:-}"
        } > "$USER_MEM_FILE"
        ;;
    2)
        GPU_MODE="NVIDIA_RENDER_OFFLOAD"
        printf 'NVIDIA Render Offload mode enabled\n'

        {
            printf 'GPU_MODE="%s"\n' "$GPU_MODE"
            printf 'DRI_PRIME=""\n'
            printf 'PREFERRED_VULKAN_VENDOR="%s"\n' "NVIDIA"
            printf 'PREFERRED_VULKAN_ICD="%s"\n' ""
        } > "$USER_MEM_FILE"
        ;;
    3)
        echo "Probing system for available GPU vendors (Vulkan, GL, PCI)..."
        vendors="$(collect_all_vendors || true)"

        # Build vendor_list safely (no NULs) and only accept Intel/AMD/NVIDIA
        vendor_list=()
        if [[ -n "$vendors" ]]; then
          while IFS= read -r v; do
            v="$(printf '%s' "$v" | tr -d '\000' | tr -d '\r' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
            case "$v" in
              Intel|AMD|NVIDIA) vendor_list+=("$v") ;;
              *) ;; # ignore anything else
            esac
          done <<< "$vendors"
        fi

        if [[ "${#vendor_list[@]}" -gt 0 ]]; then
            echo "Detected GPU vendors:"
            idx=1
            for v in "${vendor_list[@]}"; do
                printf '  %d) %s\n' "$idx" "$v"
                idx=$((idx+1))
            done
            printf '  %d) %s\n' "$idx" "None of the above / Manual entry"
            choice="$(read_choice_simple "Choose the vendor to prefer for Vulkan launches [1-$idx]: ")"
            if [[ -z "$choice" ]]; then
                echo "No choice entered. Exiting."
                exit 1
            fi
            if ! printf '%s' "$choice" | grep -Eq "^[0-9]+$"; then
                echo "Invalid selection."
                exit 1
            fi
            if (( choice >= 1 && choice < idx )); then
                sel_index=$((choice-1))
                PREFERRED_VULKAN_VENDOR="${vendor_list[$sel_index]}"
                printf 'Selected preferred Vulkan vendor: %s\n' "$PREFERRED_VULKAN_VENDOR"
            else
                read -r -p "Enter vendor name to prefer (NVIDIA, AMD, Intel): " manual_vendor
                manual_vendor="$(printf '%s' "$manual_vendor" | tr '[:lower:]' '[:upper:]')"
                case "$manual_vendor" in
                  NVIDIA|AMD|INTEL) PREFERRED_VULKAN_VENDOR="$manual_vendor" ;;
                  *) echo "Unrecognized vendor; aborting."; exit 1 ;;
                esac
                printf 'Manually set preferred Vulkan vendor: %s\n' "$PREFERRED_VULKAN_VENDOR"
            fi
        else
            echo "No hardware GPU vendor detected by probes (vulkaninfo/glxinfo/lspci)."
            read -r -p "Do you want to manually set a preferred Vulkan vendor? (N/y): " yn2
            if [[ "${yn2,,}" == "y" || "${yn2,,}" == "yes" ]]; then
                read -r -p "Enter vendor (NVIDIA, AMD, Intel): " manual_vendor
                manual_vendor="$(printf '%s' "$manual_vendor" | tr '[:lower:]' '[:upper:]')"
                case "$manual_vendor" in
                  NVIDIA|AMD|INTEL) PREFERRED_VULKAN_VENDOR="$manual_vendor" ;;
                  *) echo "Unrecognized vendor; aborting."; exit 1 ;;
                esac
                printf 'Manually set preferred Vulkan vendor: %s\n' "$PREFERRED_VULKAN_VENDOR"
            else
                echo "No change to preferred Vulkan vendor."
            fi
        fi

        # Resolve ICD file for the chosen vendor (if any)
        if [[ -n "${PREFERRED_VULKAN_VENDOR:-}" ]]; then
          PREFERRED_VULKAN_ICD="$(find_icd_for_vendor "$PREFERRED_VULKAN_VENDOR" || true)"
          if [[ -n "$PREFERRED_VULKAN_ICD" ]]; then
            printf 'Preferred Vulkan vendor: %s (ICD: %s)\n' "$PREFERRED_VULKAN_VENDOR" "$PREFERRED_VULKAN_ICD"
          else
            printf 'Preferred Vulkan vendor: %s (no vendor_icd.json found)\n' "$PREFERRED_VULKAN_VENDOR"
          fi
        fi

        {
            printf 'GPU_MODE="%s"\n' "${GPU_MODE:-}"
            printf 'DRI_PRIME="%s"\n' "${DRI_PRIME:-}"
            printf 'PREFERRED_VULKAN_VENDOR="%s"\n' "${PREFERRED_VULKAN_VENDOR:-}"
            printf 'PREFERRED_VULKAN_ICD="%s"\n' "${PREFERRED_VULKAN_ICD:-}"
        } > "$USER_MEM_FILE"
        ;;
    *)
        echo "Invalid choice. Please enter 1, 2 or 3."
        exit 1
        ;;
esac

if [[ -n "$TARGET_USER" && "$(id -u)" -eq 0 ]]; then
    chown "$TARGET_USER":"$TARGET_USER" "$USER_MEM_FILE" 2>/dev/null || true
fi
chmod 0644 "$USER_MEM_FILE" 2>/dev/null || true

printf 'Configuration saved to: %s\n' "$USER_MEM_FILE"

if [[ ! -f "$SYSTEM_MEM_FILE" ]]; then
    mkdir -p "$SYSTEM_CONFIG_DIR"
    chmod 0755 "$SYSTEM_CONFIG_DIR"
    cp -n "$USER_MEM_FILE" "$SYSTEM_MEM_FILE" 2>/dev/null || true
    chmod 0644 "$SYSTEM_MEM_FILE" 2>/dev/null || true
    printf 'System default created at: %s\n' "$SYSTEM_MEM_FILE"
fi

exit 0

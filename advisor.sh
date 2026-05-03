#!/usr/bin/env bash
set -euo pipefail

# System-wide GPU detection helper with Vulkan suggestions
#
# Usage:
#   sudo /opt/rgb-gpus-teaming/advisor.sh [--method glxinfo|lspci|vulkan] [--timeout N] [--json] [--list] [--help]
#
# Notes:
# - Designed for system-wide installs under /opt/rgb-gpus-teaming
# - If run without sudo it still works; no files are modified
# - --json prints machine-readable output; --list prints a compact list (one entry per line)

INSTALL_BASE="/opt/rgb-gpus-teaming"
SCRIPT_NAME="$(basename "$0")"

METHOD=""
TIMEOUT_SECS=2
OUTPUT_JSON=false
OUTPUT_LIST=false

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  --method glxinfo|lspci|vulkan   Choose detection method (interactive fallback if omitted)
  --timeout N                     Timeout seconds for probes (default: 2)
  --json                          Output results as JSON
  --list                          Output compact list (one entry per line)
  -h, --help                      Show this help message and exit
EOF
}

# Parse args
while (( "$#" )); do
  case "$1" in
    --method) METHOD="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT_SECS="${2:-}"; shift 2 ;;
    --json) OUTPUT_JSON=true; shift ;;
    --list) OUTPUT_LIST=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Warning: unknown argument '$1' (ignored)"; shift ;;
  esac
done

log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

if [[ ! -d "$INSTALL_BASE" ]]; then
  err "Warning: expected system install at $INSTALL_BASE not found"
fi

if ! printf '%s' "$TIMEOUT_SECS" | grep -Eq '^[0-9]+$'; then
  err "Invalid --timeout value: must be a non-negative integer"
  exit 1
fi

if [[ -z "$METHOD" ]]; then
  if [[ -t 0 ]]; then
    echo "Choose detection method:"
    echo "1) glxinfo (render offload / DRI_PRIME detection)"
    echo "2) lspci (PCI device list)"
    echo "3) vulkan (vulkaninfo)"
    read -r -p "Enter choice [1/2/3]: " choice
    case "$choice" in
      1) METHOD="glxinfo" ;;
      2) METHOD="lspci" ;;
      3) METHOD="vulkan" ;;
      *) err "Invalid choice"; exit 1 ;;
    esac
  else
    err "No method provided and no TTY available to prompt; use --method"
    exit 1
  fi
fi

declare -A seen_gpus
results=()

append_result() {
  results+=("$1")
}

map_vendor() {
  local name="$1"
  local vendor_id="$2"
  local vid_norm=""
  local name_lc=""

  if [[ -n "$vendor_id" ]]; then
    vendor_id="$(printf '%s' "$vendor_id" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | tr -d '"')"
    vid_norm="$(printf '%s' "$vendor_id" | tr '[:upper:]' '[:lower:]' | sed -E 's/^0x//')"
  fi

  case "$vid_norm" in
    10de) printf '%s' "NVIDIA"; return 0 ;;
    1002) printf '%s' "AMD"; return 0 ;;
    8086) printf '%s' "Intel"; return 0 ;;
  esac

  name_lc="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"

  if printf '%s' "$name_lc" | grep -q -E 'nvidia|geforce|quadro|rtx|gtx'; then
    printf '%s' "NVIDIA"
  elif printf '%s' "$name_lc" | grep -q -E 'amd|radeon|rx|vega'; then
    printf '%s' "AMD"
  elif printf '%s' "$name_lc" | grep -q -E 'intel|iris|hd graphics|uhd graphics'; then
    printf '%s' "Intel"
  else
    printf '%s' "Unknown"
  fi
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

  if [[ -z "$pattern" ]]; then
    printf ''
    return 0
  fi

  for p in "${search_paths[@]}"; do
    [[ -d "$p" ]] || continue
    candidate="$p/${vendor,,}_icd.json"
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

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

  for p in "${search_paths[@]}"; do
    if [[ -d "$p" ]]; then
      for f in "$p"/*.json; do [[ -e "$f" ]] || continue; printf '%s' "$f"; return 0; done
    fi
  done

  printf ''
}

build_vulkan_suggestion() {
  local vendor="$1"
  local dri_index="$2"
  local icd_file
  icd_file="$(find_icd_for_vendor "$vendor")"
  local cmd="your_vulkan_app"

  if [[ -n "$icd_file" ]]; then
    cmd="VK_ICD_FILENAMES=${icd_file} ${cmd}"
  fi

  case "$vendor" in
    NVIDIA)
      if [[ -n "$icd_file" ]]; then
        cmd="__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia VK_ICD_FILENAMES=${icd_file} ${cmd#* }"
      else
        cmd="__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia ${cmd}"
      fi
      ;;
    AMD)
      if [[ -n "$dri_index" ]]; then
        cmd="DRI_PRIME=${dri_index} ${cmd}"
      fi
      ;;
    Intel)
      ;;
    *)
      ;;
  esac

  printf '%s' "$cmd"
}

# Helper: detect if a device name looks like a software renderer (llvmpipe, softpipe, swrast)
is_software_renderer() {
  local name_lc
  name_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if printf '%s' "$name_lc" | grep -q -E 'llvmpipe|softpipe|swrast|mesa offscreen|llvmpipe'; then
    return 0
  fi
  return 1
}

detect_vulkan() {
  if ! command -v vulkaninfo >/dev/null 2>&1; then
    err "vulkaninfo not found; skipping Vulkan detection"
    return 0
  fi

  if ! command -v timeout >/dev/null 2>&1; then
    err "Error: 'timeout' command not found. Install coreutils or use a system that provides timeout."
    return 1
  fi

  log "Scanning GPUs using vulkaninfo (timeout ${TIMEOUT_SECS}s)"

  vul_out="$(timeout "${TIMEOUT_SECS}s" vulkaninfo 2>&1 || true)"
  if [[ -z "$vul_out" ]]; then
    return 0
  fi

  IFS=$'\n'
  names=()
  vids=()
  for l in $vul_out; do
    if printf '%s' "$l" | grep -q -E 'deviceName[[:space:]]*='; then
      n="$(printf '%s' "$l" | sed -E 's/.*deviceName[[:space:]]*=[[:space:]]*"?//; s/"$//; s/^[[:space:]]+|[[:space:]]+$//g')"
      names+=("$n")
    elif printf '%s' "$l" | grep -q -E 'vendorID[[:space:]]*='; then
      v="$(printf '%s' "$l" | sed -E 's/.*vendorID[[:space:]]*=[[:space:]]*//; s/^[[:space:]]+|[[:space:]]+$//g')"
      vids+=("$v")
    fi
  done

  local count=${#names[@]}
  for i in $(seq 0 $((count-1))); do
    name="${names[$i]}"
    vid="${vids[$i]:-}"
    [[ -z "$name" ]] && continue

    # Skip software renderers like llvmpipe, softpipe, swrast
    if is_software_renderer "$name"; then
      # do not add to results; optionally log a short note when not in JSON/list mode
      if [[ "$OUTPUT_JSON" != true && "$OUTPUT_LIST" != true ]]; then
        printf 'Skipping software renderer: %s\n' "$name"
      fi
      continue
    fi

    if [[ -n "${seen_gpus["$name"]:-}" ]]; then
      continue
    fi
    seen_gpus["$name"]=1

    vendor="$(map_vendor "$name" "$vid")"

    dri_index=""
    if command -v glxinfo >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
      for j in $(seq 0 15); do
        out="$(timeout 0.5s env DRI_PRIME="$j" glxinfo 2>/dev/null || true)"
        if [[ -n "$out" ]] && printf '%s' "$out" | grep -qiF "$(printf '%s' "$name" | sed 's/"/\\"/g' | cut -c1-40)"; then
          dri_index="$j"
          break
        fi
      done
    fi

    suggested_cmd="$(build_vulkan_suggestion "$vendor" "$dri_index")"

    esc_name="$(printf '%s' "$name" | sed 's/"/\\"/g')"
    esc_suggested="$(printf '%s' "$suggested_cmd" | sed 's/"/\\"/g')"

    entry="{\"method\":\"vulkan\",\"vendor_id\":\"${vid}\",\"vendor\":\"${vendor}\",\"name\":\"${esc_name}\",\"suggested\":\"${esc_suggested}\"}"
    append_result "$entry"

    if [[ "$OUTPUT_JSON" != true && "$OUTPUT_LIST" != true ]]; then
      printf 'Vulkan device → %s GPU: %s (vendorID=%s)\n' "$vendor" "$name" "${vid:-?}"
      printf 'Suggested launch command:\n  %s\n\n' "$suggested_cmd"
    fi
  done
  unset IFS
}

detect_glxinfo() {
  if ! command -v glxinfo >/dev/null 2>&1; then
    err "glxinfo not found."
    return 1
  fi
  if ! command -v timeout >/dev/null 2>&1; then
    err "Error: 'timeout' command not found. Install coreutils or use a system that provides timeout."
    return 1
  fi

  log "Scanning GPUs using glxinfo (DRI_PRIME 0..15) with timeout ${TIMEOUT_SECS}s"

  for i in $(seq 0 15); do
    output="$(timeout "${TIMEOUT_SECS}s" env DRI_PRIME="$i" glxinfo 2>&1 || true)"
    if [[ -z "$output" ]]; then
      continue
    fi

    vendor_line="$(printf '%s\n' "$output" | grep -m1 -E 'OpenGL vendor string|OpenGL renderer string|Device:' || true)"
    if [[ -z "$vendor_line" ]]; then
      continue
    fi

    gpu_name="$(printf '%s' "$vendor_line" | sed -E 's/.*(OpenGL vendor string:|OpenGL renderer string:|Device:)[[:space:]]*//; s/^[[:space:]]+|[[:space:]]+$//g')"
    [[ -z "$gpu_name" ]] && continue

    # Skip software renderers reported by glxinfo
    if is_software_renderer "$gpu_name"; then
      if [[ "$OUTPUT_JSON" != true && "$OUTPUT_LIST" != true ]]; then
        printf 'Skipping software renderer: %s\n' "$gpu_name"
      fi
      continue
    fi

    if [[ -n "${seen_gpus["$gpu_name"]:-}" ]]; then
      continue
    fi
    seen_gpus["$gpu_name"]=1

    vendor_id=""
    vendor="$(map_vendor "$gpu_name" "$vendor_id")"

    suggested_cmd=""
    if [[ "$vendor" == "NVIDIA" ]]; then
      suggested_cmd="__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia your_app"
    else
      suggested_cmd="DRI_PRIME=${i} your_app"
    fi

    esc_name="$(printf '%s' "$gpu_name" | sed 's/"/\\"/g')"
    esc_suggested="$(printf '%s' "$suggested_cmd" | sed 's/"/\\"/g')"

    entry="{\"method\":\"glxinfo\",\"dri_prime\":${i},\"vendor\":\"${vendor}\",\"name\":\"${esc_name}\",\"suggested\":\"${esc_suggested}\"}"
    append_result "$entry"

    if [[ "$OUTPUT_JSON" != true && "$OUTPUT_LIST" != true ]]; then
      printf 'DRI_PRIME=%s → %s GPU: %s\n' "$i" "$vendor" "$gpu_name"
      printf 'Suggested launch command:\n  %s\n\n' "$suggested_cmd"
    fi
  done
}

detect_lspci() {
  if ! command -v lspci >/dev/null 2>&1; then
    err "Error: lspci not found. Install with your distro package manager (pciutils)"
    return 1
  fi

  log "Scanning GPUs using lspci (VGA and 3D controllers)"

  while IFS= read -r line; do
    clean="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | tr -s ' ')"
    bus="$(printf '%s' "$clean" | awk '{print $1}')"
    desc="$(printf '%s' "$clean" | cut -d' ' -f2-)"
    pci_pair="$(printf '%s' "$line" | grep -oE '[0-9a-fA-F]{4}:[0-9a-fA-F]{4}' || true)"
    vendor_id=""
    if [[ -n "$pci_pair" ]]; then
      vendor_id="$(printf '%s' "$pci_pair" | head -n1 | cut -d: -f1)"
    fi

    vendor="$(map_vendor "$desc" "$vendor_id")"
    name="$desc"
    esc_name="$(printf '%s' "$name" | sed 's/"/\\"/g')"
    entry="{\"method\":\"lspci\",\"bus\":\"${bus}\",\"vendor_id\":\"${vendor_id}\",\"vendor\":\"${vendor}\",\"name\":\"${esc_name}\"}"
    append_result "$entry"

    if [[ "$OUTPUT_JSON" != true && "$OUTPUT_LIST" != true ]]; then
      printf '%s\n' "$clean"
    fi
  done < <(lspci -nn | grep -E "VGA|3D" || true)
}

case "$METHOD" in
  vulkan)
    detect_vulkan || true
    ;;
  glxinfo)
    detect_glxinfo || true
    ;;
  lspci)
    detect_lspci || true
    ;;
  *)
    err "Unsupported method: $METHOD"
    exit 1
    ;;
esac

if [[ "$OUTPUT_LIST" == true ]]; then
  for e in "${results[@]}"; do
    if printf '%s' "$e" | grep -q '"dri_prime"'; then
      dri="$(printf '%s' "$e" | sed -n 's/.*"dri_prime":\([0-9]*\).*/\1/p')"
      name="$(printf '%s' "$e" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
      printf 'DRI_PRIME=%s\t%s\n' "${dri:-?}" "${name:-?}"
    elif printf '%s' "$e" | grep -q '"method":"vulkan"'; then
      name="$(printf '%s' "$e" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
      vendor="$(printf '%s' "$e" | sed -n 's/.*"vendor":"\([^"]*\)".*/\1/p')"
      printf 'vulkan\t%s\t%s\n' "${vendor:-?}" "${name:-?}"
    else
      bus="$(printf '%s' "$e" | sed -n 's/.*"bus":"\([^"]*\)".*/\1/p')"
      name="$(printf '%s' "$e" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
      printf '%s\t%s\n' "${bus:-?}" "${name:-?}"
    fi
  done
fi

if [[ "$OUTPUT_JSON" == true ]]; then
  printf '[\n'
  first=true
  for e in "${results[@]}"; do
    if [[ "$first" == true ]]; then
      printf '  %s\n' "$e"
      first=false
    else
      printf '  ,%s\n' "$e"
    fi
  done
  printf ']\n'
fi

if [[ -t 1 && "$OUTPUT_JSON" != true && "$OUTPUT_LIST" != true ]]; then
  printf '\nPress Enter to continue...'
  IFS= read -r _
fi

exit 0


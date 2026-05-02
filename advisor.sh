#!/usr/bin/env bash
set -euo pipefail

# System-wide GPU detection helper
#
# Usage:
#   sudo /opt/rgb-gpus-teaming/advisor.sh [--method glxinfo|lspci] [--timeout N] [--json] [--list] [--help]
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
  --method glxinfo|lspci   Choose detection method (interactive fallback if omitted)
  --timeout N              Timeout seconds for glxinfo probes (default: 2)
  --json                   Output results as JSON
  --list                   Output compact list (one entry per line)
  -h, --help               Show this help message and exit
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

# Ensure /opt install exists (best-effort)
if [[ ! -d "$INSTALL_BASE" ]]; then
  err "Warning: expected system install at $INSTALL_BASE not found"
fi

# Validate timeout is a positive integer
if ! printf '%s' "$TIMEOUT_SECS" | grep -Eq '^[0-9]+$'; then
  err "Invalid --timeout value: must be a non-negative integer"
  exit 1
fi

# Interactive prompt if method not provided
if [[ -z "$METHOD" ]]; then
  if [[ -t 0 ]]; then
    echo "Choose detection method:"
    echo "1) glxinfo (render offload / DRI_PRIME detection)"
    echo "2) lspci (PCI device list)"
    read -r -p "Enter choice [1/2]: " choice
    case "$choice" in
      1) METHOD="glxinfo" ;;
      2) METHOD="lspci" ;;
      *) err "Invalid choice"; exit 1 ;;
    esac
  else
    err "No method provided and no TTY available to prompt; use --method"
    exit 1
  fi
fi

declare -A seen_gpus
results=()

# Helper to append result (keeps JSON objects as strings)
append_result() {
  results+=("$1")
}

# If glxinfo is requested but missing, fail; if not requested and missing, fallback to lspci
if [[ "$METHOD" == "glxinfo" ]]; then
  if ! command -v glxinfo >/dev/null 2>&1; then
    err "glxinfo not found."
    # If user explicitly requested glxinfo, exit with error
    if printf '%s' "$@" | grep -q -- '--method'; then
      err "Error: --method glxinfo requested but glxinfo is not installed. Install mesa-utils / mesa-demos."
      exit 1
    else
      # fallback to lspci
      log "glxinfo not found; falling back to lspci"
      METHOD="lspci"
    fi
  fi
fi

# Ensure timeout command exists when using glxinfo
if [[ "$METHOD" == "glxinfo" ]]; then
  if ! command -v timeout >/dev/null 2>&1; then
    err "Error: 'timeout' command not found. Install coreutils or use a system that provides timeout."
    exit 1
  fi
fi

if [[ "$METHOD" == "glxinfo" ]]; then
  log "Scanning GPUs using glxinfo (DRI_PRIME 0..15) with timeout ${TIMEOUT_SECS}s"

  for i in $(seq 0 15); do
    # Run glxinfo under timeout; capture both stdout and stderr
    output="$(timeout "${TIMEOUT_SECS}s" env DRI_PRIME="$i" glxinfo 2>&1 || true)"
    # If output is empty, skip
    if [[ -z "$output" ]]; then
      continue
    fi

    # Try to find a Device: line
    device_line="$(printf '%s\n' "$output" | grep -m1 'Device:' || true)"
    if [[ -z "$device_line" ]]; then
      # Some glxinfo versions use "Device:" or "Device:" may be absent; try "OpenGL renderer string"
      device_line="$(printf '%s\n' "$output" | grep -m1 -E 'OpenGL renderer string|Device:' || true)"
    fi

    if [[ -n "$device_line" ]]; then
      gpu_name="$(printf '%s' "$device_line" | sed -E 's/.*(Device:|OpenGL renderer string:)[[:space:]]*//; s/^[[:space:]]+|[[:space:]]+$//g')"
      [[ -z "$gpu_name" ]] && continue
      if [[ -n "${seen_gpus["$gpu_name"]:-}" ]]; then
        continue
      fi
      seen_gpus["$gpu_name"]=1

      vendor="Unknown"
      case "$gpu_name" in
        *NVIDIA*|*nvidia*) vendor="NVIDIA" ;;
        *AMD*|*Radeon*|*radeon*) vendor="AMD" ;;
        *Intel*|*intel*) vendor="Intel" ;;
      esac

      suggested_cmd=""
      if [[ "$vendor" == "NVIDIA" ]]; then
        suggested_cmd="__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia your_app"
      else
        suggested_cmd="DRI_PRIME=${i} your_app"
      fi

      # Escape quotes in name for JSON safety (simple)
      esc_name="$(printf '%s' "$gpu_name" | sed 's/"/\\"/g')"
      esc_suggested="$(printf '%s' "$suggested_cmd" | sed 's/"/\\"/g')"

      entry="{\"method\":\"glxinfo\",\"dri_prime\":${i},\"vendor\":\"${vendor}\",\"name\":\"${esc_name}\",\"suggested\":\"${esc_suggested}\"}"
      append_result "$entry"

      if [[ "$OUTPUT_JSON" != true && "$OUTPUT_LIST" != true ]]; then
        printf 'DRI_PRIME=%s → %s GPU: %s\n' "$i" "$vendor" "$gpu_name"
        printf 'Suggested launch command:\n  %s\n\n' "$suggested_cmd"
      fi
    fi
  done

elif [[ "$METHOD" == "lspci" ]]; then
  if ! command -v lspci >/dev/null 2>&1; then
    err "Error: lspci not found. Install with your distro package manager (pciutils)"
    exit 1
  fi

  log "Scanning GPUs using lspci (VGA and 3D controllers)"

  while IFS= read -r line; do
    clean="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | tr -s ' ')"
    bus="$(printf '%s' "$clean" | awk '{print $1}')"
    desc="$(printf '%s' "$clean" | cut -d' ' -f2-)"
    vendor="Unknown"
    case "$desc" in
      *NVIDIA*|*nvidia*) vendor="NVIDIA" ;;
      *AMD*|*Radeon*|*radeon*) vendor="AMD" ;;
      *Intel*|*intel*) vendor="Intel" ;;
    esac
    name="$desc"
    esc_name="$(printf '%s' "$name" | sed 's/"/\\"/g')"
    entry="{\"method\":\"lspci\",\"bus\":\"${bus}\",\"vendor\":\"${vendor}\",\"name\":\"${esc_name}\"}"
    append_result "$entry"

    if [[ "$OUTPUT_JSON" != true && "$OUTPUT_LIST" != true ]]; then
      printf '%s\n' "$clean"
    fi
  done < <(lspci | grep -E "VGA|3D" || true)

else
  err "Unsupported method: $METHOD"
  exit 1
fi

# Output modes
if [[ "$OUTPUT_LIST" == true ]]; then
  for e in "${results[@]}"; do
    if printf '%s' "$e" | grep -q '"dri_prime"'; then
      dri="$(printf '%s' "$e" | sed -n 's/.*"dri_prime":\([0-9]*\).*/\1/p')"
      name="$(printf '%s' "$e" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
      printf 'DRI_PRIME=%s\t%s\n' "${dri:-?}" "${name:-?}"
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

# Pause before exit when running interactively and not producing machine-readable output
if [[ -t 1 && "$OUTPUT_JSON" != true && "$OUTPUT_LIST" != true ]]; then
  printf '\nPress Enter to continue...'
  IFS= read -r _
fi

exit 0

#!/usr/bin/env bash
set -euo pipefail

# /opt/RGB-GPUs-Teaming.OP/bin/gpu-detect.sh
# System-wide GPU detection helper
#
# Usage:
#   sudo /opt/RGB-GPUs-Teaming.OP/bin/gpu-detect.sh [--method glxinfo|lspci] [--timeout N] [--json] [--list] [--help]
#
# Notes:
# - Designed for system-wide installs under /opt/RGB-GPUs-Teaming.OP
# - If run without sudo it still works; no files are modified
# - --json prints machine-readable output; --list prints a compact list (one entry per line)

INSTALL_BASE="/opt/RGB-GPUs-Teaming.OP"
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

Examples:
  $SCRIPT_NAME --method glxinfo --timeout 3
  $SCRIPT_NAME --method lspci --json
EOF
}

# Parse args
while (( "$#" )); do
  case "$1" in
    --method) METHOD="$2"; shift 2 ;;
    --timeout) TIMEOUT_SECS="$2"; shift 2 ;;
    --json) OUTPUT_JSON=true; shift ;;
    --list) OUTPUT_LIST=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Warning: unknown argument '$1' (ignored)"; shift ;;
  esac
done

# Helpers
log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

# Ensure /opt install exists (best-effort)
if [[ ! -d "$INSTALL_BASE" ]]; then
  err "Warning: expected system install at $INSTALL_BASE not found"
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

if [[ "$METHOD" == "glxinfo" ]]; then
  if ! command -v glxinfo &>/dev/null; then
    err "Error: glxinfo not found. Install with your distro package manager (mesa-utils / mesa-demos)"
    exit 1
  fi

  log "Scanning GPUs using glxinfo (DRI_PRIME 0..15) with timeout ${TIMEOUT_SECS}s"

  for i in $(seq 0 15); do
    output="$(timeout "${TIMEOUT_SECS}s" env DRI_PRIME="$i" glxinfo 2>/dev/null || true)"
    device_line="$(printf '%s\n' "$output" | grep -m1 'Device:' || true)"
    if [[ -n "$device_line" ]]; then
      gpu_name="$(printf '%s' "$device_line" | sed -E 's/.*Device:[[:space:]]*//; s/^[[:space:]]+|[[:space:]]+$//g')"
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

      entry="{\"method\":\"glxinfo\",\"dri_prime\":${i},\"vendor\":\"${vendor}\",\"name\":\"${gpu_name}\",\"suggested\":\"${suggested_cmd}\"}"
      results+=("$entry")

      # Print human-friendly output unless JSON/list requested
      if [[ "$OUTPUT_JSON" != true && "$OUTPUT_LIST" != true ]]; then
        printf 'DRI_PRIME=%s → %s GPU: %s\n' "$i" "$vendor" "$gpu_name"
        printf 'Suggested launch command:\n  %s\n\n' "$suggested_cmd"
      fi
    fi
  done

elif [[ "$METHOD" == "lspci" ]]; then
  if ! command -v lspci &>/dev/null; then
    err "Error: lspci not found. Install with your distro package manager (pciutils)"
    exit 1
  fi

  log "Scanning GPUs using lspci (VGA and 3D controllers)"

  while IFS= read -r line; do
    clean="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | tr -s ' ')"
    # Example: 0000:01:00.0 VGA compatible controller: NVIDIA Corporation ...
    bus="$(printf '%s' "$clean" | awk '{print $1}')"
    desc="$(printf '%s' "$clean" | cut -d' ' -f2-)"
    vendor="Unknown"
    case "$desc" in
      *NVIDIA*|*nvidia*) vendor="NVIDIA" ;;
      *AMD*|*Radeon*|*radeon*) vendor="AMD" ;;
      *Intel*|*intel*) vendor="Intel" ;;
    esac
    name="$desc"
    entry="{\"method\":\"lspci\",\"bus\":\"${bus}\",\"vendor\":\"${vendor}\",\"name\":\"${name}\"}"
    results+=("$entry")

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
    # crude extraction for list mode
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
  # read without printing input (in case of special chars)
  IFS= read -r _
fi

exit 0

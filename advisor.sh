#!/usr/bin/env bash
set -euo pipefail

# System-wide GPU detection helper
#
# Usage:
#   sudo /opt/rgb-gpus-teaming/advisor.sh [--method switcherooctl|glxinfo|lspci] [--timeout N] [--json] [--list] [--help]
#
# Notes:
# - Designed for system-wide installs under /opt/rgb-gpus-teaming
# - If run without sudo it still works; no files are modified (except when switcherooctl method requests starting/stopping a service via sudo)
# - --json prints machine-readable output; --list prints a compact list (one entry per line)

INSTALL_BASE="/opt/rgb-gpus-teaming"
SCRIPT_NAME="$(basename "$0")"

METHOD=""
TIMEOUT_SECS=2
OUTPUT_JSON=false
OUTPUT_LIST=false
EXPLICIT_METHOD=false

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  --method switcherooctl|glxinfo|lspci   Choose detection method (interactive fallback if omitted)
  --timeout N                            Timeout seconds for glxinfo probes (default: 2)
  --json                                  Output results as JSON
  --list                                  Output compact list (one entry per line)
  -h, --help                              Show this help message and exit
EOF
}

# Parse args
while (( "$#" )); do
  case "$1" in
    --method)
      METHOD="${2:-}"
      EXPLICIT_METHOD=true
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECS="${2:-}"
      shift 2
      ;;
    --json)
      OUTPUT_JSON=true
      shift
      ;;
    --list)
      OUTPUT_LIST=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Warning: unknown argument '$1' (ignored)"
      shift
      ;;
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
    echo "1) switcherooctl (kernel switcheroo / hybrid GPU clients)"
    echo "2) glxinfo (render offload / DRI_PRIME detection)"
    echo "3) lspci (PCI device list)"
    read -r -p "Enter choice [1/2/3]: " choice
    case "$choice" in
      1) METHOD="switcherooctl" ;;
      2) METHOD="glxinfo" ;;
      3) METHOD="lspci" ;;
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

# -------------------------
# Vendor detection helper
# -------------------------
detect_vendor_from_text() {
  local txt="$1"
  local vendor="Unknown"
  local ltxt
  ltxt="$(printf '%s' "$txt" | tr '[:upper:]' '[:lower:]')"
  if printf '%s' "$ltxt" | grep -Eiq '\bnvidia\b|\bgeforce\b|\brtx\b|\bga10\b|\bnvrm\b'; then
    vendor="NVIDIA"
  elif printf '%s' "$ltxt" | grep -Eiq '\bintel\b|\biris\b|\buhd\b|\btigerlake\b|\bi915\b'; then
    vendor="Intel"
  elif printf '%s' "$ltxt" | grep -Eiq '\bradeon\b|\bamdgpu\b|\bamd\b|\bati\b'; then
    vendor="AMD"
  fi
  printf '%s' "$vendor"
}

# -------------------------
# switcherooctl helpers (no suggested commands)
# -------------------------
scan_switcherooctl() {
  local out source_tag
  if command -v switcherooctl >/dev/null 2>&1; then
    out="$(switcherooctl list 2>&1 || switcherooctl status 2>&1 || true)"
    source_tag="switcherooctl_tool"
  elif [[ -r "/sys/kernel/debug/switcheroo/clients" ]]; then
    out="$(cat /sys/kernel/debug/switcheroo/clients 2>&1 || true)"
    source_tag="switcheroo_debugfs"
  else
    err "switcherooctl not available and /sys/kernel/debug/switcheroo/clients not readable"
    return 3
  fi

  detect_vendor_from_block() {
    local block="$1"
    local lblock
    lblock="$(printf '%s' "$block" | tr '[:upper:]' '[:lower:]')"
    if printf '%s' "$lblock" | grep -qi 'vk_loader_drivers_select=.*nvidia'; then
      printf 'NVIDIA' && return
    fi
    if printf '%s' "$lblock" | grep -qi 'vk_loader_drivers_select=.*intel'; then
      printf 'Intel' && return
    fi
    if printf '%s' "$lblock" | grep -qi '__nv_prime_render_offload\|__glx_vendor_library_name=nvidia\|nv_prime'; then
      printf 'NVIDIA' && return
    fi
    if printf '%s' "$lblock" | grep -qi '\bnvidia\b|\bgeforce\b|\brtx\b'; then
      printf 'NVIDIA' && return
    fi
    if printf '%s' "$lblock" | grep -qi '\bintel\b|\biris\b|\buhd\b|\btigerlake\b'; then
      printf 'Intel' && return
    fi
    if printf '%s' "$lblock" | grep -qi '\bradeon\b|\bamdgpu\b|\bamd\b'; then
      printf 'AMD' && return
    fi
    printf 'Unknown'
  }

  # Group lines into blocks per client
  local block line
  block=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(printf '%s' "$line" | sed -E 's/\r$//')"
    if printf '%s' "$line" | grep -Eq '^[[:space:]]*[0-9]+:|^[[:space:]]*Device:'; then
      if [[ -n "$block" ]]; then
        process_switcheroo_block "$block" "$source_tag"
      fi
      block="$line"$'\n'
    else
      block+="$line"$'\n'
    fi
  done <<<"$out"
  if [[ -n "$block" ]]; then
    process_switcheroo_block "$block" "$source_tag"
  fi

  return 0
}

process_switcheroo_block() {
  local block="$1" source_tag="$2"
  block="$(printf '%s' "$block" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  [[ -z "$block" ]] && return

  local name pci env short vendor esc_raw esc_short esc_pci esc_vendor entry

  name="$(printf '%s' "$block" | grep -m1 -i 'Name:' | sed -E 's/^[[:space:]]*Name:[[:space:]]*//I' || true)"
  pci="$(printf '%s' "$block" | grep -oEi '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]\.[0-9]' || true)"
  env="$(printf '%s' "$block" | grep -m1 -i 'Environment:' | sed -E 's/^[[:space:]]*Environment:[[:space:]]*//I' || true)"

  if [[ -n "$name" ]]; then
    short="$name"
  elif [[ -n "$pci" ]]; then
    short="$pci"
  else
    short="$(printf '%s' "$block" | head -n1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  fi

  vendor="$(detect_vendor_from_block "$block")"

  if [[ -n "${seen_gpus["$block"]:-}" ]]; then
    return
  fi
  seen_gpus["$block"]=1

  esc_raw="$(printf '%s' "$block" | sed 's/"/\\"/g' | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g')"
  esc_short="$(printf '%s' "$short" | sed 's/"/\\"/g')"
  esc_pci="$(printf '%s' "$pci" | sed 's/"/\\"/g')"
  esc_vendor="$(printf '%s' "$vendor" | sed 's/"/\\"/g')"

  entry="{\"method\":\"switcherooctl\",\"source\":\"${source_tag}\",\"short\":\"${esc_short}\",\"pci\":\"${esc_pci}\",\"vendor\":\"${esc_vendor}\",\"raw\":\"${esc_raw}\"}"
  append_result "$entry"

  if [[ "$OUTPUT_JSON" != true && "$OUTPUT_LIST" != true ]]; then
    printf 'switcheroo client: %s\n' "$short"
    [[ -n "$pci" ]] && printf '  PCI: %s\n' "$pci"
    printf '  Vendor guess: %s\n' "$vendor"
    printf '  Raw block:\n%s\n\n' "$block"
  fi
}

# -------------------------
# glxinfo scanning
# -------------------------
if [[ "$METHOD" == "glxinfo" ]]; then
  if ! command -v glxinfo >/dev/null 2>&1; then
    err "glxinfo not found."
    if [[ "$EXPLICIT_METHOD" == true ]]; then
      err "Error: --method glxinfo requested but glxinfo is not installed. Install mesa-utils / mesa-demos."
      exit 1
    else
      log "glxinfo not found; falling back to lspci"
      METHOD="lspci"
    fi
  fi
fi

if [[ "$METHOD" == "glxinfo" ]]; then
  if ! command -v timeout >/dev/null 2>&1; then
    err "Error: 'timeout' command not found. Install coreutils or use a system that provides timeout."
    exit 1
  fi

  log "Scanning GPUs using glxinfo (DRI_PRIME 0..15) with timeout ${TIMEOUT_SECS}s"

  for i in $(seq 0 15); do
    output="$(timeout "${TIMEOUT_SECS}s" env DRI_PRIME="$i" glxinfo 2>&1 || true)"
    if [[ -z "$output" ]]; then
      continue
    fi

    device_line="$(printf '%s\n' "$output" | grep -m1 -E 'OpenGL renderer string|Device:' || true)"
    if [[ -n "$device_line" ]]; then
      gpu_name="$(printf '%s' "$device_line" | sed -E 's/.*(Device:|OpenGL renderer string:)[[:space:]]*//; s/^[[:space:]]+|[[:space:]]+$//g')"
      [[ -z "$gpu_name" ]] && continue
      if [[ -n "${seen_gpus["$gpu_name"]:-}" ]]; then
        continue
      fi
      seen_gpus["$gpu_name"]=1

      vendor="$(detect_vendor_from_text "$gpu_name")"

      esc_name="$(printf '%s' "$gpu_name" | sed 's/"/\\"/g')"
      esc_vendor="$(printf '%s' "$vendor" | sed 's/"/\\"/g')"

      entry="{\"method\":\"glxinfo\",\"dri_prime\":${i},\"vendor\":\"${esc_vendor}\",\"name\":\"${esc_name}\"}"
      append_result "$entry"

      if [[ "$OUTPUT_JSON" != true && "$OUTPUT_LIST" != true ]]; then
        printf 'DRI_PRIME=%s → %s GPU: %s\n\n' "$i" "$vendor" "$gpu_name"
      fi
    fi
  done
fi

# -------------------------
# lspci scanning (simple per-line style requested by user)
# -------------------------
if [[ "$METHOD" == "lspci" ]]; then
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
fi

# -------------------------
# switcherooctl scanning (if requested) with service start/stop using systemctl
# -------------------------
if [[ "$METHOD" == "switcherooctl" ]]; then
  log "Preparing switcherooctl scan"

  # Start the helper service (best-effort). Only run when method is switcherooctl.
  if command -v systemctl >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1; then
      # Try to start only if the unit exists (best-effort)
      if systemctl list-unit-files --type=service | grep -q '^switcheroo-control.service'; then
        if ! sudo systemctl start switcheroo-control.service 2>/dev/null; then
          err "Warning: failed to start switcheroo-control.service (sudo systemctl start returned non-zero). Continuing to attempt scan."
        fi
      else
        # Unit not found; skip start
        err "Note: switcheroo-control.service not found; skipping service start."
      fi
    else
      err "Warning: sudo not found; cannot start switcheroo-control.service automatically."
    fi
  else
    err "Warning: systemctl not found; cannot manage switcheroo-control.service automatically."
  fi

  log "Scanning GPUs using switcherooctl / /sys/kernel/debug/switcheroo/clients"
  if ! scan_switcherooctl; then
    err "switcherooctl scan failed or not available"
  fi

  # Stop the helper service (best-effort)
  if command -v systemctl >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
    if systemctl list-unit-files --type=service | grep -q '^switcheroo-control.service'; then
      if ! sudo systemctl stop switcheroo-control.service 2>/dev/null; then
        err "Warning: failed to stop switcheroo-control.service (sudo systemctl stop returned non-zero)."
      fi
    fi
  fi
fi

# Final output: if JSON requested, print aggregated JSON array
if [[ "$OUTPUT_JSON" == true ]]; then
  printf '[\n'
  first=true
  for r in "${results[@]}"; do
    if [[ "$first" == true ]]; then
      first=false
    else
      printf ',\n'
    fi
    printf '  %s' "$r"
  done
  printf '\n]\n'
fi

# If list requested and we collected JSON entries, print compact list
if [[ "$OUTPUT_LIST" == true && "${#results[@]}" -gt 0 ]]; then
  for r in "${results[@]}"; do
    name="$(printf '%s' "$r" | sed -E 's/.*"name":"([^"]+)".*/\1/;t; s/.*"short":"([^"]+)".*/\1/;t; s/.*"info":"([^"]+)".*/\1/')"
    printf '%s\n' "$name"
  done
fi

# If no explicit output mode and no results, notify
if [[ "$OUTPUT_JSON" != true && "$OUTPUT_LIST" != true && "${#results[@]}" -eq 0 ]]; then
  log "No GPU information discovered."
fi

exit 0
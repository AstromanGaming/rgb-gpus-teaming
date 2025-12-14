#!/usr/bin/env bash
set -euo pipefail

# manual-setup.sh
# Interactive helper to choose GPU launch mode and optionally run a command.
# Not an installer — it only reads/writes a small config and can execute a command.
#
# Usage:
#   ./manual-setup.sh                # interactive, per-user config
#   sudo ./manual-setup.sh           # interactive, system config under /opt (if desired)
#   ./manual-setup.sh --command "firefox"   # non-interactive: run command using saved or provided mode
#
# Options:
#   --command, -c "<cmd>"   Run <cmd> immediately (non-interactive).
#   --non-interactive       Do not prompt; use saved config (if any).
#   --dry-run               Show actions without writing files or running commands.
#   --verbose, -v           Print detailed logs.
#   --help, -h              Show this help and exit.

INSTALL_BASE="/opt/RGB-GPUs-Teaming.OP"
SYSTEM_CONFIG_DIR="$INSTALL_BASE/config"
SYSTEM_MEM_FILE="$SYSTEM_CONFIG_DIR/gpu_launcher_config"

USER_MEM_FILE="$HOME/.gpu_launcher_config"

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 || true)"

VERBOSE=false
DRY_RUN=false
NONINTERACTIVE=false
CMD=""

log() { [[ "$VERBOSE" == true ]] && printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }
err() { printf 'Error: %s\n' "$*" >&2; }

usage() {
  cat <<EOF
Usage:
  $0 [options]

Options:
  --command, -c "<cmd>"   Run <cmd> immediately (non-interactive).
  --non-interactive       Do not prompt; use saved config (if any).
  --verbose, -v           Print detailed logs.
  --dry-run               Show actions without writing files or running commands.
  --help, -h              Show this help and exit.

Behavior:
  - When run as a normal user, config is read/written at: $USER_MEM_FILE
  - When run as root, config is read/written at: $SYSTEM_MEM_FILE
  - This script is NOT an installer; it only manages the small launcher config and can run commands.
EOF
}

read_line() { read -r -p "$1" __tmp; printf '%s' "$__tmp"; }

# Parse args
while (( "$#" )); do
  case "$1" in
    --command|-c)
      if [[ -z "${2:-}" ]]; then err "--command requires an argument"; exit 2; fi
      CMD="$2"; NONINTERACTIVE=true; shift 2 ;;
    --non-interactive) NONINTERACTIVE=true; shift ;;
    --verbose|-v) VERBOSE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) err "Unknown argument: $1"; shift ;;
  esac
done

# Decide which mem file to use
if [[ "$(id -u)" -eq 0 ]]; then
  MEM_FILE="$SYSTEM_MEM_FILE"
  log "Running as root; using system config: $MEM_FILE"
else
  MEM_FILE="$USER_MEM_FILE"
  log "Running as user; using user config: $MEM_FILE"
fi

# Ensure system config dir exists when writing system config (unless dry-run)
if [[ "$(id -u)" -eq 0 && "$DRY_RUN" == false ]]; then
  mkdir -p "$SYSTEM_CONFIG_DIR"
  chmod 0755 "$SYSTEM_CONFIG_DIR"
  log "Ensured system config dir: $SYSTEM_CONFIG_DIR"
fi

# Load previous configuration if present
GPU_MODE=""
DRI_PRIME=""
if [[ -f "$MEM_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$MEM_FILE"
  log "Loaded existing config: GPU_MODE=${GPU_MODE:-<none>} DRI_PRIME=${DRI_PRIME:-<none>}"
else
  log "No existing config at $MEM_FILE"
fi

# If non-interactive and no saved config and no command, fail
if [[ "$NONINTERACTIVE" == true && -z "${GPU_MODE:-}" && -z "$CMD" ]]; then
  err "No saved GPU configuration found; run interactively first to create one."
  exit 3
fi

# Interactive configuration (skipped when NONINTERACTIVE true and CMD provided)
if [[ "$NONINTERACTIVE" != true && -z "$CMD" ]]; then
  echo
  echo "Select GPU launch mode (press Enter to reuse saved configuration):"
  echo "1) Intel / AMD / NVIDIA (DRI_PRIME)"
  echo "2) NVIDIA (Render Offload)"
  mode="$(read_line "Choice (1 or 2): ")"

  if [[ -z "$mode" ]]; then
    if [[ -n "${GPU_MODE:-}" ]]; then
      log "Reusing saved configuration: GPU_MODE=$GPU_MODE"
      echo "Reusing saved configuration: ${GPU_MODE:-<none>}"
    else
      echo "No saved configuration; please choose an option."
      mode="$(read_line "Choice (1 or 2): ")"
    fi
  fi

  if [[ -n "$mode" ]]; then
    case "$mode" in
      1)
        dri_value="$(read_line "Enter DRI_PRIME value (e.g., 0,1,2): ")"
        if [[ ! "$dri_value" =~ ^[0-9]+$ ]]; then err "DRI_PRIME must be a non-negative integer"; exit 1; fi
        DRI_PRIME="$dri_value"
        GPU_MODE="DRI_PRIME"
        printf 'DRI_PRIME mode enabled with DRI_PRIME=%s\n' "$DRI_PRIME"
        if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
          echo "Warning: DRI_PRIME may be unreliable with NVIDIA under Wayland."
        fi
        ;;
      2)
        GPU_MODE="NVIDIA_RENDER_OFFLOAD"
        unset DRI_PRIME
        printf 'NVIDIA Render Offload mode selected\n'
        ;;
      *)
        err "Invalid choice"; exit 1
        ;;
    esac

    # Persist config (respect dry-run)
    if [[ "$DRY_RUN" == true ]]; then
      log "[DRY-RUN] Would write config to $MEM_FILE: GPU_MODE=$GPU_MODE DRI_PRIME=${DRI_PRIME:-<empty>}"
      echo "Dry-run: config not written."
    else
      {
        printf 'GPU_MODE="%s"\n' "$GPU_MODE"
        if [[ -n "${DRI_PRIME:-}" ]]; then
          printf 'DRI_PRIME="%s"\n' "$DRI_PRIME"
        else
          printf 'DRI_PRIME=""\n'
        fi
      } > "$MEM_FILE"
      # If written to system location, ensure real user can read it
      if [[ "$(id -u)" -eq 0 && -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
        chown "$REAL_USER":"$REAL_USER" "$MEM_FILE" 2>/dev/null || true
      fi
      chmod 0644 "$MEM_FILE" 2>/dev/null || true
      log "Wrote config to $MEM_FILE"
      echo "Configuration saved to $MEM_FILE"
    fi
  fi
fi

# Determine command to run
if [[ -n "$CMD" ]]; then
  user_cmd="$CMD"
elif [[ "$NONINTERACTIVE" == true ]]; then
  err "Non-interactive mode requested but no command provided; exiting."
  exit 4
else
  read -r -e -p "Command to run (or press Enter to exit): " user_cmd
  if [[ -z "${user_cmd// /}" ]]; then
    log "No command entered; exiting."
    exit 0
  fi
fi

echo
echo "Executing command with GPU mode: ${GPU_MODE:-<none>}"
echo

# Execute the command in a subshell with the appropriate environment
run_cmd() {
  local cmd="$1"
  if [[ "${GPU_MODE:-}" == "NVIDIA_RENDER_OFFLOAD" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      log "[DRY-RUN] Would run with: __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia $cmd"
      echo "[DRY-RUN] $cmd"
    else
      env __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia bash -lc "$cmd"
    fi
  else
    if [[ -n "${DRI_PRIME:-}" ]]; then
      if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] Would run with: DRI_PRIME=$DRI_PRIME $cmd"
        echo "[DRY-RUN] $cmd"
      else
        env DRI_PRIME="$DRI_PRIME" bash -lc "$cmd"
      fi
    else
      if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] Would run: $cmd"
        echo "[DRY-RUN] $cmd"
      else
        bash -lc "$cmd"
      fi
    fi
  fi
}

# If command was provided via --command and not verbose, run in background (like a launcher)
if [[ -n "$CMD" && "$VERBOSE" == false && "$DRY_RUN" == false ]]; then
  run_cmd "$user_cmd" &
  printf 'Started command in background (PID %s)\n' "$!"
else
  run_cmd "$user_cmd"
fi

log "Done"
exit 0

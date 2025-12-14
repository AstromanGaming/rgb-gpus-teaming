#!/usr/bin/env bash
set -euo pipefail

# update-rgb-gpus-teaming.sh
#
# Usage:
#   sudo ./update-rgb-gpus-teaming.sh [--all-ways-egpu] [--silent] [--help]

INSTALL_BASE="/opt/RGB-GPUs-Teaming.OP"
INSTALL_SCRIPT="$INSTALL_BASE/install-rgb-gpus-teaming.sh"
UNINSTALL_SCRIPT="$INSTALL_BASE/reinstall-rgb-gpus-teaming.sh"
GIT_DIR="$INSTALL_BASE/.git"

ALL_WAYS_EGPU=false
SILENT=false
VERBOSE=true

# Save original args so we can re-exec with sudo preserving them
ORIG_ARGS=( "$@" )

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --all-ways-egpu    Pass this flag to reinstall/install scripts to include the all-ways-egpu addon.
  --silent           Run in silent mode (minimize prompts/output).
  -h, --help         Show this help message and exit.
EOF
}

# Parse args
while (( "$#" )); do
  case "$1" in
    --all-ways-egpu) ALL_WAYS_EGPU=true; shift ;;
    --silent) SILENT=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Warning: unknown argument %q (ignored)\n' "$1" >&2; shift ;;
  esac
done

# If silent requested, disable verbose logging
if [[ "$SILENT" == true ]]; then
  VERBOSE=false
fi

log() { [[ "$VERBOSE" == true ]] && printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }
info() { [[ "$SILENT" == true ]] && return 0; printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

printf 'Update/reinstall for system install at %s\n' "$INSTALL_BASE"
log "Options: all-ways-egpu=$ALL_WAYS_EGPU, silent=$SILENT, verbose=$VERBOSE"

if [[ ! -d "$INSTALL_BASE" ]]; then
  printf 'Error: system install directory not found: %s\n' "$INSTALL_BASE" >&2
  exit 1
fi

# Ensure running as root (re-run with sudo if not)
if [[ "$(id -u)" -ne 0 ]]; then
  info 'This script requires root. Re-running with sudo...'
  exec sudo "$0" "${ORIG_ARGS[@]}"
fi

# If this is a git repo, pull latest changes
if command -v git >/dev/null 2>&1 && [[ -d "$GIT_DIR" ]]; then
  info "Pulling latest changes from Git in $INSTALL_BASE..."
  if ! git -C "$INSTALL_BASE" pull --ff-only; then
    printf 'Error: git pull failed. Aborting.\n' >&2
    exit 1
  fi
else
  info "Warning: $INSTALL_BASE is not a Git repository or git is not installed. Skipping git pull."
fi

# Build flags to pass to reinstall/install scripts
script_flags=()
[[ "$ALL_WAYS_EGPU" == true ]] && script_flags+=(--all-ways-egpu)
[[ "$SILENT" == true ]] && script_flags+=(--silent)

# Helper to run a script (already root) with logging and diagnostics
run_script() {
  local script_path="$1"; shift
  local args=( "$@" )

  if [[ ! -f "$script_path" ]]; then
    printf 'Warning: script not found: %s\n' "$script_path" >&2
    return 2
  fi

  printf 'Running: %s' "$script_path"
  for a in "${args[@]}"; do printf ' %q' "$a"; done
  printf '\n'

  # Run with bash -x to aid debugging; stream stdout+stderr to the console
  if bash -x "$script_path" "${args[@]}"; then
    log "Script succeeded: $script_path"
    return 0
  else
    local rc=$?
    printf 'Script failed with exit code %d.\n' "$rc" >&2
    return $rc
  fi
}

# Run reinstall script if present (tolerate non-zero exit)
if [[ -f "$UNINSTALL_SCRIPT" ]]; then
  info 'Running reinstall script (replaces uninstall)...'
  if ! run_script "$UNINSTALL_SCRIPT" "${script_flags[@]}"; then
    printf 'Warning: reinstall script returned non-zero; continuing to reinstall.\n' >&2
  fi
else
  info "Warning: Reinstall script not found: $UNINSTALL_SCRIPT"
fi

# Run install script (fail if it errors)
if [[ -f "$INSTALL_SCRIPT" ]]; then
  info 'Running install script...'
  if ! run_script "$INSTALL_SCRIPT" "${script_flags[@]}"; then
    printf 'Error: install script failed.\n' >&2
    exit 1
  fi
else
  printf 'Error: Install script not found: %s\n' "$INSTALL_SCRIPT" >&2
  exit 1
fi

printf 'Update and reinstall complete for %s.\n' "$INSTALL_BASE"

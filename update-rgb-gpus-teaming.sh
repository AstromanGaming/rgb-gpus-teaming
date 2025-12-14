#!/usr/bin/env bash
set -euo pipefail

# update-rgb-gpus-teaming.sh
#
# Usage:
#   sudo ./update-rgb-gpus-teaming.sh [--all-ways-egpu] [--help]
#
# Notes:
#  - This script updates a system install under /opt/RGB-GPUs-Teaming.OP.
#  - Child scripts are executed with INSTALL_BASE as the working directory
#    to avoid accidental copying of the caller's current directory (e.g., $HOME).

INSTALL_BASE="/opt/RGB-GPUs-Teaming.OP"
INSTALL_SCRIPT="$INSTALL_BASE/install-rgb-gpus-teaming.sh"
UNINSTALL_SCRIPT="$INSTALL_BASE/reinstall-rgb-gpus-teaming.sh"
GIT_DIR="$INSTALL_BASE/.git"

ALL_WAYS_EGPU=false
VERBOSE=true   # verbose enabled by default

# Save original args so we can re-exec with sudo preserving them
ORIG_ARGS=( "$@" )

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --all-ways-egpu    Pass this flag to reinstall/install scripts to include the all-ways-egpu addon.
  -h, --help         Show this help message and exit.
EOF
}

# Parse args
while (( "$#" )); do
  case "$1" in
    --all-ways-egpu) ALL_WAYS_EGPU=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Warning: unknown argument %q (ignored)\n' "$1" >&2; shift ;;
  esac
done

log() { [[ "$VERBOSE" == true ]] && printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }
info() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

info "Update/reinstall for system install at $INSTALL_BASE"
log "Options: all-ways-egpu=$ALL_WAYS_EGPU"

if [[ ! -d "$INSTALL_BASE" ]]; then
  err "Error: system install directory not found: $INSTALL_BASE"
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
    err "Error: git pull failed. Aborting."
    exit 1
  fi
else
  info "Warning: $INSTALL_BASE is not a Git repository or git is not installed. Skipping git pull."
fi

# Build flags to pass to reinstall/install scripts
script_flags=()
[[ "$ALL_WAYS_EGPU" == true ]] && script_flags+=(--all-ways-egpu)

# Helper to run a script (already root) with logging and diagnostics
# Runs the child script with INSTALL_BASE as the working directory to avoid
# accidental copying of the caller's current directory (e.g. $HOME).
run_script() {
  local script_path="$1"; shift
  local args=( "$@" )

  if [[ ! -f "$script_path" ]]; then
    err "Warning: script not found: $script_path"
    return 2
  fi

  # Always print the command (verbose by default)
  printf 'Running: %s' "$script_path"
  for a in "${args[@]}"; do printf ' %q' "$a"; done
  printf '\n'

  # Save current directory and switch to INSTALL_BASE to avoid relative-path surprises.
  local saved_pwd
  saved_pwd="$PWD"
  if [[ -d "$INSTALL_BASE" ]]; then
    cd "$INSTALL_BASE"
  else
    # If INSTALL_BASE doesn't exist for some reason, run in the script's directory instead
    cd "$(dirname "$script_path")"
  fi

  # Run the script without xtrace to avoid leading +/++ lines in logs.
  # Stream stdout/stderr directly.
  if bash "$script_path" "${args[@]}"; then
    log "Script succeeded: $script_path"
    cd "$saved_pwd" || true
    return 0
  else
    local rc=$?
    err "Script failed with exit code $rc."
    cd "$saved_pwd" || true
    return $rc
  fi
}

# Run reinstall script if present (tolerate non-zero exit)
if [[ -f "$UNINSTALL_SCRIPT" ]]; then
  info 'Running reinstall script (replaces uninstall)...'
  if ! run_script "$UNINSTALL_SCRIPT" "${script_flags[@]}"; then
    err 'Warning: reinstall script returned non-zero; continuing to reinstall.'
  fi
else
  info "Warning: Reinstall script not found: $UNINSTALL_SCRIPT"
fi

# Run install script (fail if it errors)
if [[ -f "$INSTALL_SCRIPT" ]]; then
  info 'Running install script...'
  if ! run_script "$INSTALL_SCRIPT" "${script_flags[@]}"; then
    err 'Error: install script failed.'
    exit 1
  fi
else
  err "Error: Install script not found: $INSTALL_SCRIPT"
  exit 1
fi

info "Update and reinstall complete for $INSTALL_BASE"

#!/usr/bin/env bash
set -euo pipefail

# update-rgb-gpus-teaming.sh
# Pull latest changes and run uninstall/install scripts from /opt installation.
#
# Usage:
#   sudo ./update-rgb-gpus-teaming.sh [--all-ways-egpu] [--silent] [--dry-run] [--verbose] [--help]

INSTALL_BASE="/opt/RGB-GPUs-Teaming.OP"
INSTALL_SCRIPT="$INSTALL_BASE/install-rgb-gpus-teaming.sh"
UNINSTALL_SCRIPT="$INSTALL_BASE/uninstall-rgb-gpus-teaming.sh"
GIT_DIR="$INSTALL_BASE/.git"

ALL_WAYS_EGPU=false
SILENT=false
VERBOSE=false
DRY_RUN=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --all-ways-egpu    Pass this flag to uninstall/install scripts to include the all-ways-egpu addon.
  --silent           Run uninstall in silent mode (minimize prompts/output).
  --dry-run          Show what would be done without making changes.
  --verbose          Print more detailed progress messages.
  -h, --help         Show this help message and exit.
EOF
}

# Parse args
while (( "$#" )); do
  case "$1" in
    --all-ways-egpu) ALL_WAYS_EGPU=true; shift ;;
    --silent) SILENT=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Warning: unknown argument '$1' (ignored)"; shift ;;
  esac
done

log() { [[ "$VERBOSE" == true ]] && printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }

echo "Update/reinstall for system install at $INSTALL_BASE"
log "Options: all-ways-egpu=$ALL_WAYS_EGPU, silent=$SILENT, verbose=$VERBOSE, dry-run=$DRY_RUN"

if [[ ! -d "$INSTALL_BASE" ]]; then
  echo "Error: system install directory not found: $INSTALL_BASE" >&2
  exit 1
fi

# Ensure running as root (re-run with sudo if not)
if [[ "$(id -u)" -ne 0 && "$DRY_RUN" != true ]]; then
  echo "This script requires root. Re-running with sudo..."
  exec sudo "$0" "$@"
fi

# If this is a git repo, pull latest changes
if [[ -d "$GIT_DIR" ]]; then
  echo "Pulling latest changes from Git in $INSTALL_BASE..."
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] git -C \"$INSTALL_BASE\" pull --ff-only"
  else
    if ! git -C "$INSTALL_BASE" pull --ff-only; then
      echo "Error: git pull failed. Aborting." >&2
      exit 1
    fi
  fi
else
  echo "Warning: $INSTALL_BASE is not a Git repository. Skipping git pull."
fi

# Build flags to pass to uninstall/install scripts
script_flags=()
$ALL_WAYS_EGPU && script_flags+=(--all-ways-egpu)
$SILENT && script_flags+=(--silent)
$DRY_RUN && script_flags+=(--dry-run)

# Helper to run a script (already root) with logging and better diagnostics
run_script() {
  local script_path="$1"; shift
  local args=( "$@" )
  local tmplog

  if [[ ! -f "$script_path" ]]; then
    echo "Warning: script not found: $script_path"
    return 2
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Would run: $script_path ${args[*]}"
    return 0
  fi

  tmplog="$(mktemp /tmp/rgb-install.XXXXXX.log)"
  chmod 600 "$tmplog"
  echo "Running: $script_path ${args[*]} (logging to $tmplog)"
  # Run with bash -x to aid debugging; capture stdout+stderr
  if bash -x "$script_path" "${args[@]}" >"$tmplog" 2>&1; then
    log "Script succeeded: $script_path"
    rm -f "$tmplog"
    return 0
  else
    local rc=$?
    echo "Script failed with exit code $rc. Last 200 lines of log:" >&2
    tail -n 200 "$tmplog" >&2
    echo "Full log saved at: $tmplog" >&2
    return $rc
  fi
}

# Run uninstall script if present (tolerate non-zero exit)
if [[ -f "$UNINSTALL_SCRIPT" ]]; then
  echo "Running uninstall script..."
  if ! run_script "$UNINSTALL_SCRIPT" "${script_flags[@]}"; then
    echo "Warning: uninstall script returned non-zero; continuing to reinstall." >&2
  fi
else
  echo "Warning: Uninstall script not found: $UNINSTALL_SCRIPT"
fi

# Run install script (fail if it errors)
if [[ -f "$INSTALL_SCRIPT" ]]; then
  echo "Running install script..."
  if ! run_script "$INSTALL_SCRIPT" "${script_flags[@]}"; then
    echo "Error: install script failed." >&2
    exit 1
  fi
else
  echo "Error: Install script not found: $INSTALL_SCRIPT" >&2
  exit 1
fi

echo "Update and reinstall complete for $INSTALL_BASE."

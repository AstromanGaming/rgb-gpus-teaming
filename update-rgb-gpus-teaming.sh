#!/usr/bin/env bash
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$REAL_USER" | cut -d: -f6)"
INSTALL_DIR="$HOME_DIR/RGB-GPUs-Teaming.OP"
INSTALL_SCRIPT="$INSTALL_DIR/install-rgb-gpus-teaming.sh"
UNINSTALL_SCRIPT="$INSTALL_DIR/uninstall-rgb-gpus-teaming.sh"

ALL_WAYS_EGPU=false
SILENT=false
VERBOSE=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --all-ways-egpu    Pass this flag to uninstall/install scripts to include the all-ways-egpu addon.
  --silent           Run uninstall in silent mode (minimize prompts/output).
  --verbose          Print more detailed progress messages.
  -h, --help         Show this help message and exit.

Examples:
  $(basename "$0") --all-ways-egpu
  $(basename "$0") --silent --verbose
EOF
}

# Parse args
for arg in "$@"; do
    case "$arg" in
        --all-ways-egpu) ALL_WAYS_EGPU=true ;;
        --silent) SILENT=true ;;
        --verbose) VERBOSE=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Warning: unknown argument '$arg' (ignored)" ;;
    esac
done

log() { [[ "$VERBOSE" == true ]] && printf '%s\n' "$*"; }
echo "Starting update-reinstall (user: $REAL_USER, dir: $INSTALL_DIR)"
log "Options: all-ways-egpu=$ALL_WAYS_EGPU, silent=$SILENT, verbose=$VERBOSE"

if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Error: $INSTALL_DIR does not exist. Please clone the repository first."
    exit 1
fi

if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo "Pulling latest changes from Git..."
    if ! git -C "$INSTALL_DIR" pull --ff-only; then
        echo "Error: git pull failed. Aborting."
        exit 1
    fi
else
    echo "Warning: $INSTALL_DIR is not a Git repository. Skipping git pull."
fi

# Build flags to pass to uninstall/install scripts
script_flags=()
$ALL_WAYS_EGPU && script_flags+=(--all-ways-egpu)
$SILENT && script_flags+=(--silent)

# Run uninstall script if present
if [[ -x "$UNINSTALL_SCRIPT" ]]; then
    echo "Running uninstall script..."
    if ! bash -e "$UNINSTALL_SCRIPT" "${script_flags[@]}"; then
        echo "Warning: uninstall script returned a non-zero status; continuing to reinstall."
    fi
else
    echo "Warning: Uninstall script not found or not executable: $UNINSTALL_SCRIPT"
fi

# Run install script
if [[ -x "$INSTALL_SCRIPT" ]]; then
    echo "Running install script..."
    if ! bash -e "$INSTALL_SCRIPT" "${script_flags[@]}"; then
        echo "Error: install script failed."
        exit 1
    fi
else
    echo "Error: Install script not found or not executable: $INSTALL_SCRIPT"
    exit 1
fi

echo "Update and reinstall complete."

#!/usr/bin/env bash
set -euo pipefail

# reinstall-rgb-gpus-teaming.sh
#
# Usage: sudo ./reinstall-rgb-gpus-teaming.sh
#
# Notes:
#  - This script removes the GNOME extension directory, the Nautilus script,
#    and a set of .desktop files under /usr/share/applications.
#  - It requires root to perform removals; if not run as root it will re-exec with sudo.

EXTENSION_UUID="rgb-gpus-teaming@astromangaming"
EXTENSION_SYS="/usr/share/gnome-shell/extensions/$EXTENSION_UUID"
NAUTILUS_SCRIPT="/usr/share/nautilus/scripts/Launch with RGB GPUs Teaming"
DESKTOP_DIR="/usr/share/applications"

# Defaults
VERBOSE=true

ORIG_ARGS=( "$@" )

# Parse args: no options supported; treat any argument as an error
if (( "$#" )); then
  printf 'Error: this script does not accept arguments.\n' >&2
  exit 2
fi

# Logging helpers
log() { [[ "$VERBOSE" == true ]] && printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }
info() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

# Ensure running as root (re-run with sudo if not)
if [[ "$(id -u)" -ne 0 ]]; then
  err "This script requires root to remove system files. Re-running with sudo..."
  exec sudo "$0" "${ORIG_ARGS[@]}"
fi

info ''
info '# reinstall-rgb-gpus-teaming.sh'
info ''

run_rm() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    rm -rf -- "$path"
    log "Removed: $path"
    return 0
  else
    log "Not found (skipping): $path"
    return 0
  fi
}

info "Removing GNOME extension and system desktop entries..."

# Remove GNOME extension directory
run_rm "$EXTENSION_SYS"

# Remove Nautilus script
run_rm "$NAUTILUS_SCRIPT"

# Remove known .desktop files (best-effort)
declare -a desktop_files=(
  "advisor.desktop"
  "gnome-setup.desktop"
  "manual-setup.desktop"
  "all-ways-egpu-auto-setup.desktop"
)

for f in "${desktop_files[@]}"; do
  run_rm "$DESKTOP_DIR/$f"
done

# Attempt to disable the extension via gnome-extensions if available
if command -v gnome-extensions >/dev/null 2>&1; then
  # ignore errors
  gnome-extensions disable "$EXTENSION_UUID" 2>/dev/null || true
  log "Attempted to disable extension: $EXTENSION_UUID"
fi

info "Removal complete. Only GNOME extension, Nautilus script and .desktop files were targeted."

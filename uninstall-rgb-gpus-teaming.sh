#!/usr/bin/env bash
set -euo pipefail

# uninstall-rgb-gpus-teaming.sh
# Conservative system-wide uninstaller for RGB-GPUs-Teaming.OP
#
# Usage:
#   sudo ./uninstall-rgb-gpus-teaming.sh [--silent] [--dry-run] [--verbose] [--remove-root] [--help]
#
# Behavior:
# - If install-manifest.txt exists, remove items listed there (reverse order).
# - Otherwise remove only a safe, explicit list of known installed artifacts.
# - By default the top-level /opt/RGB-GPUs-Teaming.OP directory is preserved.
# - Use --remove-root to remove the top-level directory (dangerous).

OPT_BASE="/opt/RGB-GPUs-Teaming.OP"
MANIFEST="$OPT_BASE/install-manifest.txt"
EXTENSION_UUID="rgb-gpus-teaming@astromangaming"
EXTENSION_SYS="/usr/share/gnome-shell/extensions/$EXTENSION_UUID"
NAUTILUS_SCRIPT="/usr/share/nautilus/scripts/Launch with RGB GPUs Teaming"
DESKTOP_DIR="/usr/share/applications"

DRY_RUN=false
VERBOSE=false
SILENT=false
REMOVE_ROOT=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --dry-run       Show actions without making changes.
  --verbose       Print detailed progress messages.
  --silent        Suppress final informational messages.
  --remove-root   Also remove the OPT_BASE directory itself (use with caution).
  -h, --help      Show this help message and exit.
EOF
}

while (( "$#" )); do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --silent) SILENT=true; shift ;;
    --remove-root) REMOVE_ROOT=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Warning: unknown argument '$1' (ignored)"; shift ;;
  esac
done

log() { [[ "$VERBOSE" == true ]] && printf '%s\n' "$*"; }
err() { printf 'Error: %s\n' "$*" >&2; }

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script must be run as root. Re-run with sudo." >&2
  exit 2
fi

run_rm() {
  local path="$1"
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Would remove: $path"
    log "[DRY-RUN] Would remove: $path"
  else
    if [[ -e "$path" ]]; then
      rm -rf -- "$path"
      log "Removed: $path"
    else
      log "Not found (skipping): $path"
    fi
  fi
}

echo "Starting conservative uninstall of RGB-GPUs-Teaming from $OPT_BASE"
log "Options: dry-run=$DRY_RUN verbose=$VERBOSE remove-root=$REMOVE_ROOT"

# If manifest exists, use it (most reliable)
if [[ -f "$MANIFEST" ]]; then
  log "Found manifest: $MANIFEST"
  mapfile -t items < "$MANIFEST"
  for ((i=${#items[@]}-1; i>=0; i--)); do
    item="${items[i]}"
    # Protect OPT_BASE unless --remove-root specified
    if [[ "$item" == "$OPT_BASE" || "$item" == "$OPT_BASE/" ]]; then
      if [[ "$REMOVE_ROOT" == true ]]; then
        run_rm "$item"
      else
        log "Preserving top-level directory: $OPT_BASE (use --remove-root to remove it)"
        # remove contents but keep directory if desired
        if [[ "$DRY_RUN" == true ]]; then
          echo "[DRY-RUN] Would remove contents of: $OPT_BASE (preserve directory)"
        else
          if [[ -d "$OPT_BASE" ]]; then
            find "$OPT_BASE" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
            log "Removed contents of: $OPT_BASE (directory preserved)"
          fi
        fi
      fi
    else
      run_rm "$item"
    fi
  done

else
  log "No manifest found; using conservative explicit artifact list."

  # Conservative explicit list of files/dirs to remove (safe defaults)
  declare -a opt_items=(
    "$OPT_BASE/gnome-launcher.sh"
    "$OPT_BASE/gnome-setup.sh"
    "$OPT_BASE/manual-setup.sh"
    "$OPT_BASE/advisor.sh"
    "$OPT_BASE/advisor-addon.sh"
    "$OPT_BASE/all-ways-egpu-auto-setup.sh"
    "$OPT_BASE/install-rgb-gpus-teaming.sh"
    "$OPT_BASE/update-rgb-gpus-teaming.sh"
    "$OPT_BASE/uninstall-rgb-gpus-teaming.sh"
    "$OPT_BASE/README.md"
    "$OPT_BASE/LICENSE"
    "$OPT_BASE/logo.png"
    "$OPT_BASE/logo2.png"
    "$OPT_BASE/nautilus-scripts"
    "$OPT_BASE/gnome-extension"
    "$OPT_BASE/.git"
    "$OPT_BASE/.github"
    "$DESKTOP_DIR/advisor.desktop"
    "$DESKTOP_DIR/gnome-setup.desktop"
    "$DESKTOP_DIR/manual-setup.desktop"
    "$DESKTOP_DIR/all-ways-egpu-auto-setup.desktop"
  )

  for p in "${opt_items[@]}"; do
    run_rm "$p"
  done

  # Nautilus script (explicit path)
  run_rm "$NAUTILUS_SCRIPT"

  # System GNOME extension folder
  run_rm "$EXTENSION_SYS"
fi

# Attempt to disable extension system-wide (best-effort)
if command -v gnome-extensions &> /dev/null; then
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Would attempt to disable extension: $EXTENSION_UUID"
    log "[DRY-RUN] Would attempt to disable extension: $EXTENSION_UUID"
  else
    log "Attempting to disable extension (best-effort)"
    gnome-extensions disable "$EXTENSION_UUID" 2>/dev/null || true
  fi
else
  log "gnome-extensions CLI not available; extension may remain enabled until user session reload."
fi

if [[ "$SILENT" != true ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    echo "Dry-run mode: no files were actually removed."
  else
    echo "Conservative uninstall complete."
    if [[ "$REMOVE_ROOT" == true ]]; then
      echo "Top-level directory $OPT_BASE was removed."
    else
      echo "Top-level directory $OPT_BASE was preserved."
    fi
    echo "If desktop entries still appear, run 'update-desktop-database' and/or log out and back in."
  fi
fi

#!/usr/bin/env bash
set -euo pipefail

OPT_BASE="/opt/RGB-GPUs-Teaming.OP"
MANIFEST="$OPT_BASE/install-manifest.txt"
EXTENSION_UUID="rgb-gpus-teaming@astromangaming"
EXTENSION_SYS="/usr/share/gnome-shell/extensions/$EXTENSION_UUID"
NAUTILUS_SCRIPT="/usr/share/nautilus/scripts/Launch with RGB GPUs Teaming"
DESKTOP_DIR="/usr/share/applications"

DRY_RUN=false
VERBOSE=false
REMOVE_ROOT=false
CONFIRM_REMOVE=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--verbose] [--remove-root --confirm-remove-root] [--help]

Options:
  --dry-run                 Show actions without making changes.
  --verbose                 Print detailed progress messages.
  --remove-root             Remove the top-level $OPT_BASE directory (dangerous).
  --confirm-remove-root     Required together with --remove-root to actually remove the top-level directory.
  -h, --help                Show this help and exit.
EOF
}

# Strict argument parsing: accept only known long options; reject typos like -dry-run
while (( "$#" )); do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --remove-root) REMOVE_ROOT=true; shift ;;
    --confirm-remove-root) CONFIRM_REMOVE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "Error: unknown option '$1'"; usage; exit 2 ;;
    *) echo "Error: unexpected positional argument '$1'"; usage; exit 2 ;;
  esac
done

log() { [[ "$VERBOSE" == true ]] && printf '%s\n' "$*"; }

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script must be run as root. Re-run with sudo." >&2
  exit 2
fi

# Safety: require explicit confirmation to remove the top-level directory
if [[ "$REMOVE_ROOT" == true && "$CONFIRM_REMOVE" != true ]]; then
  echo "Refusing to remove $OPT_BASE: pass both --remove-root and --confirm-remove-root to proceed." >&2
  exit 3
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

echo "Uninstall: target $OPT_BASE (remove-root=$REMOVE_ROOT confirm-remove=$CONFIRM_REMOVE)"
log "Options: dry-run=$DRY_RUN verbose=$VERBOSE remove-root=$REMOVE_ROOT"

# If manifest exists, use it (reverse order). Preserve OPT_BASE unless explicitly requested.
if [[ -f "$MANIFEST" ]]; then
  log "Using manifest: $MANIFEST"
  mapfile -t items < "$MANIFEST"
  for ((i=${#items[@]}-1; i>=0; i--)); do
    item="${items[i]}"
    item_norm="${item%/}"
    if [[ "$item_norm" == "$OPT_BASE" ]]; then
      if [[ "$REMOVE_ROOT" == true ]]; then
        run_rm "$item"
      else
        log "Preserving top-level directory: $OPT_BASE (use --remove-root --confirm-remove-root to remove it)"
      fi
    else
      run_rm "$item"
    fi
  done

else
  log "No manifest found; removing only a conservative explicit list of known artifacts."

  # Conservative explicit list (only items the installer creates).
  # Include the four OPT_BASE .desktop files you mentioned explicitly.
  declare -a items=(
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
    "$OPT_BASE/advisor.desktop"
    "$OPT_BASE/gnome-setup.desktop"
    "$OPT_BASE/manual-setup.desktop"
    "$OPT_BASE/all-ways-egpu-auto-setup.desktop"
  )

  for p in "${items[@]}"; do
    run_rm "$p"
  done

  # Remove desktop files from system location (if present)
  run_rm "$DESKTOP_DIR/advisor.desktop"
  run_rm "$DESKTOP_DIR/gnome-setup.desktop"
  run_rm "$DESKTOP_DIR/manual-setup.desktop"
  run_rm "$DESKTOP_DIR/all-ways-egpu-auto-setup.desktop"

  # Nautilus script and system GNOME extension folder
  run_rm "$NAUTILUS_SCRIPT"
  run_rm "$EXTENSION_SYS"

  # Remove top-level directory only if explicitly requested (and confirmed)
  if [[ "$REMOVE_ROOT" == true ]]; then
    run_rm "$OPT_BASE"
  else
    log "Top-level directory preserved: $OPT_BASE (use --remove-root --confirm-remove-root to remove it)"
  fi
fi

# Best-effort: disable system extension
if command -v gnome-extensions &> /dev/null; then
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Would attempt to disable extension: $EXTENSION_UUID"
  else
    gnome-extensions disable "$EXTENSION_UUID" 2>/dev/null || true
    log "Attempted to disable extension: $EXTENSION_UUID"
  fi
fi

echo "Uninstall complete. Top-level directory preserved: $([[ "$REMOVE_ROOT" == true ]] && echo "no" || echo "yes")"

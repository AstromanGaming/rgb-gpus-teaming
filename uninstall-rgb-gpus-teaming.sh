#!/usr/bin/env bash
set -euo pipefail

# uninstall-rgb-gpus-teaming.sh
# System-wide uninstaller that dynamically detects .desktop files referencing /opt/RGB-GPUs-Teaming.OP
#
# Usage:
#   sudo ./uninstall-rgb-gpus-teaming.sh [--silent] [--dry-run] [--verbose] [--silent] [--help]
#
# Notes:
# - Prefers /opt/RGB-GPUs-Teaming.OP/install-manifest.txt when present.
# - Otherwise finds .desktop files that reference /opt/RGB-GPUs-Teaming.OP in Exec or TryExec.
# - Requires root.

OPT_BASE="/opt/RGB-GPUs-Teaming.OP"
MANIFEST="$OPT_BASE/install-manifest.txt"
EXTENSION_UUID="rgb-gpus-teaming@astromangaming"
EXTENSION_SYS="/usr/share/gnome-shell/extensions/$EXTENSION_UUID"
NAUTILUS_SCRIPT="/usr/share/nautilus/scripts/Launch with RGB GPUs Teaming"

DRY_RUN=false
VERBOSE=false
SILENT=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --silent     Suppress final informational messages.
  --dry-run    Show actions without making changes.
  --verbose    Print detailed progress messages.
  -h, --help   Show this help message and exit.

This script performs a system-wide uninstall of RGB-GPUs-Teaming installed under /opt.
EOF
}

while (( "$#" )); do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --silent) SILENT=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Warning: unknown argument '$1' (ignored)"; shift ;;
  esac
done

log() { [[ "$VERBOSE" == true ]] && printf '%s\n' "$*"; }

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
      rm -rf "$path"
      log "Removed: $path"
    else
      log "Not found (skipping): $path"
    fi
  fi
}

echo "Starting system-wide uninstall of RGB-GPUs-Teaming from $OPT_BASE"

# If manifest exists, use it (most reliable)
if [[ -f "$MANIFEST" ]]; then
  log "Found manifest: $MANIFEST"
  mapfile -t items < "$MANIFEST"
  for ((i=${#items[@]}-1; i>=0; i--)); do
    run_rm "${items[i]}"
  done
else
  log "No manifest found; performing dynamic detection of installed files."

  # 1) Remove the /opt install directory
  run_rm "$OPT_BASE"

  # 2) Find .desktop files that reference the /opt install in Exec or TryExec
  desktop_matches=()
  while IFS= read -r -d $'\0' file; do
    desktop_matches+=("$file")
  done < <(grep -IlZ --binary-files=without-match -E '/opt/RGB-GPUs-Teaming.OP' /usr/share/applications/*.desktop 2>/dev/null || true)

  # Also check TryExec lines explicitly (some desktop files may use TryExec with absolute path)
  while IFS= read -r -d $'\0' file; do
    # avoid duplicates
    case " ${desktop_matches[*]} " in
      *" $file "*) ;;
      *) desktop_matches+=("$file") ;;
    esac
  done < <(grep -IlZ --binary-files=without-match -E '^TryExec=.*(/opt/RGB-GPUs-Teaming.OP|/opt/RGB-GPUs-Teaming.OP/)' /usr/share/applications/*.desktop 2>/dev/null || true)

  # If no matches found by content, fall back to common filenames
  if [[ ${#desktop_matches[@]} -eq 0 ]]; then
    log "No .desktop files referencing /opt found; falling back to common filenames."
    fallback=(
      /usr/share/applications/advisor.desktop
      /usr/share/applications/gnome-setup.desktop
      /usr/share/applications/manual-setup.desktop
      /usr/share/applications/all-ways-egpu-auto-setup.desktop
    )
    for f in "${fallback[@]}"; do
      if [[ -f "$f" ]]; then
        desktop_matches+=("$f")
      fi
    done
  fi

  # Remove matched desktop files
  if [[ ${#desktop_matches[@]} -gt 0 ]]; then
    for f in "${desktop_matches[@]}"; do
      run_rm "$f"
    done
  else
    log "No desktop files to remove."
  fi

  # 3) Remove Nautilus script if it matches the project
  if [[ -f "$NAUTILUS_SCRIPT" ]]; then
    run_rm "$NAUTILUS_SCRIPT"
  else
    # try to find any nautilus scripts that mention the project path
    while IFS= read -r -d $'\0' ns; do
      run_rm "$ns"
    done < <(grep -IlZ --binary-files=without-match -E '/opt/RGB-GPUs-Teaming.OP' /usr/share/nautilus/scripts/* 2>/dev/null || true)
  fi

  # 4) Remove system GNOME extension folder
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
    echo "System-wide uninstall complete."
    echo "If desktop entries still appear, run 'update-desktop-database' and/or log out and back in."
  fi
fi

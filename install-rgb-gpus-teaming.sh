#!/usr/bin/env bash
set -euo pipefail

# install-rgb-gpus-teaming.sh
# System-wide installer: copies project to /opt and installs desktop files,
# Nautilus scripts, and GNOME extension system-wide.
#
# Usage: sudo ./install-rgb-gpus-teaming.sh [--all-ways-egpu] [--dry-run] [--verbose] [--help]

SCRIPT_NAME="$(basename "$0")"
SRC_DIR="$(pwd)"
DEST_BASE="/opt/RGB-GPUs-Teaming.OP"
DEST_DESKTOP_DIR="/usr/share/applications"
DEST_NAUTILUS_DIR="/usr/share/nautilus/scripts"
DEST_EXTENSIONS_DIR="/usr/share/gnome-shell/extensions"
EXTENSION_UUID="rgb-gpus-teaming@astromangaming"
EXTENSION_SRC="$SRC_DIR/gnome-extension/$EXTENSION_UUID"
EXTENSION_DEST="$DEST_EXTENSIONS_DIR/$EXTENSION_UUID"
MANIFEST_FILE="$DEST_BASE/install-manifest.txt"
README_TXT="$DEST_BASE/README.txt"

ALL_WAYS_EGPU=false
VERBOSE=false
DRY_RUN=false

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  --all-ways-egpu    Install the all-ways-egpu desktop launcher as well.
  --dry-run          Show what would be done without making changes.
  --verbose          Print detailed progress messages.
  -h, --help         Show this help message and exit.

Notes:
  - This script must be run as root (it will re-run with sudo if needed).
  - It copies the project to $DEST_BASE and installs system-wide desktop files.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --all-ways-egpu) ALL_WAYS_EGPU=true ;;
    --verbose) VERBOSE=true ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Warning: unknown argument '$arg' (ignored)" ;;
  esac
done

log() { [[ "$VERBOSE" == true ]] && printf '%s\n' "$*"; }

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This installer requires root. Re-running with sudo..."
  exec sudo "$0" "$@"
fi

if [[ ! -d "$SRC_DIR" ]]; then
  echo "Error: source directory not found: $SRC_DIR" >&2
  exit 2
fi

echo "Preparing system-wide install to $DEST_BASE"
log "Options: all-ways-egpu=$ALL_WAYS_EGPU, verbose=$VERBOSE, dry-run=$DRY_RUN"

if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY-RUN] Would remove and copy project to $DEST_BASE"
else
  rm -rf "$DEST_BASE"
  mkdir -p "$DEST_BASE"
  cp -a "$SRC_DIR/." "$DEST_BASE/"
  log "Copied project to $DEST_BASE"
fi

# Create manifest
manifest_write() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Would write manifest to $MANIFEST_FILE"
    return
  fi
  mkdir -p "$(dirname "$MANIFEST_FILE")"
  : > "$MANIFEST_FILE"
  echo "$DEST_BASE" >> "$MANIFEST_FILE"
}

# Create README.txt in /opt (plain text copy of README.md if present)
if [[ -f "$SRC_DIR/README.md" ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Would create $README_TXT from README.md"
  else
    # Simple conversion: strip HTML tags used in README header and keep markdown
    sed 's/<[^>]*>//g' "$SRC_DIR/README.md" > "$README_TXT" || cp -f "$SRC_DIR/README.md" "$README_TXT"
    chmod 644 "$README_TXT"
    echo "$README_TXT" >> "$MANIFEST_FILE"
  fi
fi

# Helper to rewrite Exec lines to absolute /opt paths
rewrite_exec_cmd() {
  local src_exec="$1"
  local cmd="${src_exec#Exec=}"
  cmd="${cmd//\$HOME/$DEST_BASE}"
  cmd="${cmd//\~/$DEST_BASE}"
  cmd="${cmd//$SRC_DIR/$DEST_BASE}"
  cmd="${cmd//RGB-GPUs-Teaming.OP/$DEST_BASE}"
  printf '%s' "$cmd"
}

shopt -s nullglob
desktop_files=("$DEST_BASE"/*.desktop)
if (( ${#desktop_files[@]} )); then
  echo "Installing .desktop launchers to $DEST_DESKTOP_DIR..."
  for src in "${desktop_files[@]}"; do
    base="$(basename "$src")"
    if [[ "$ALL_WAYS_EGPU" != true && "$base" == "all-ways-egpu-auto-setup.desktop" ]]; then
      log "Skipping $base (all-ways-egpu not requested)"
      continue
    fi
    exec_line="$(grep -m1 -E '^Exec=' "$src" || true)"
    exec_cmd=""
    if [[ -n "$exec_line" ]]; then
      exec_cmd="$(rewrite_exec_cmd "$exec_line")"
    fi
    dest="$DEST_DESKTOP_DIR/$base"
    if [[ "$DRY_RUN" == true ]]; then
      echo "[DRY-RUN] Would install $dest (Exec: ${exec_cmd:-<none>})"
    else
      cp -f "$src" "$dest"
      chmod 644 "$dest"
      if [[ -n "$exec_cmd" ]]; then
        if command -v desktop-file-edit >/dev/null 2>&1; then
          desktop-file-edit --set-key=Exec --set-value="$exec_cmd" "$dest" || true
          desktop-file-edit --set-key=TryExec --set-value="$(printf '%s' "$exec_cmd" | awk '{print $1}')" "$dest" || true
        else
          sed -i -E "s|^Exec=.*|Exec=${exec_cmd}|" "$dest"
          if grep -qE '^TryExec=' "$dest"; then
            sed -i -E "s|^TryExec=.*|TryExec=$(printf '%s' "$exec_cmd" | awk '{print $1}')|" "$dest"
          else
            printf 'TryExec=%s\n' "$(printf '%s' "$exec_cmd" | awk '{print $1}')" >> "$dest"
          fi
        fi
      fi
      echo "$dest" >> "$MANIFEST_FILE"
      log "Installed $dest"
    fi
  done
else
  echo "No .desktop files found in project."
fi

# Nautilus scripts
nautilus_src_dir="$DEST_BASE/nautilus-scripts"
if [[ -d "$nautilus_src_dir" ]]; then
  echo "Installing Nautilus scripts to $DEST_NAUTILUS_DIR..."
  mkdir -p "$DEST_NAUTILUS_DIR"
  for s in "$nautilus_src_dir"/*; do
    dest="$DEST_NAUTILUS_DIR/$(basename "$s")"
    if [[ "$DRY_RUN" == true ]]; then
      echo "[DRY-RUN] Would install Nautilus script $dest"
    else
      cp -f "$s" "$dest"
      chmod 755 "$dest"
      echo "$dest" >> "$MANIFEST_FILE"
      log "Installed Nautilus script $dest"
    fi
  done
else
  echo "No Nautilus scripts found in project."
fi

# GNOME extension
if [[ -d "$EXTENSION_SRC" ]]; then
  echo "Installing GNOME extension to $EXTENSION_DEST..."
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Would copy extension to $EXTENSION_DEST"
  else
    rm -rf "$EXTENSION_DEST"
    cp -a "$EXTENSION_SRC" "$EXTENSION_DEST"
    chmod -R 755 "$EXTENSION_DEST"
    echo "$EXTENSION_DEST" >> "$MANIFEST_FILE"
    log "Copied extension to $EXTENSION_DEST"
  fi

  if command -v gnome-extensions >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == true ]]; then
      echo "[DRY-RUN] Would attempt to enable $EXTENSION_UUID (may require user session)"
    else
      if gnome-extensions enable "$EXTENSION_UUID" 2>/dev/null; then
        echo "GNOME extension enabled (system-wide)."
      else
        echo "Note: enabling system-wide extension may require a user session. Enable it in the user's session if needed."
      fi
    fi
  else
    echo "gnome-extensions CLI not available; extension copied but not enabled."
  fi
else
  echo "GNOME extension source not found at $EXTENSION_SRC"
fi

shopt -u nullglob

# Write manifest if not dry-run
if [[ "$DRY_RUN" == false ]]; then
  manifest_write
  chmod 644 "$MANIFEST_FILE" || true
  echo "Install manifest written to $MANIFEST_FILE"
fi

echo "System-wide installation to /opt complete."
echo "Desktop files installed to $DEST_DESKTOP_DIR"
echo "Project files installed to $DEST_BASE"
echo "If the extension does not appear, enable it in the user's GNOME session or run:"
echo "  gnome-extensions enable $EXTENSION_UUID"

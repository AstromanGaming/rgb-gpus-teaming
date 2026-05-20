#!/usr/bin/env bash

# install-rgb-gpus-teaming.sh
#
# Usage: sudo ./install-rgb-gpus-teaming.sh [options]
#
# Options:
#   --all-ways-egpu            Install the "all-ways-egpu" launcher.
#   -v, --vulkan               Install Vulkan experimental desktop files.
#   -l, --lite                 Do NOT install .desktop files, DBUS services or GNOME extension (server mode).
#   -h, --help                 Show this help and exit.
# ------------------------------------------------------------

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SRC_DIR="$(pwd)"
DEST_BASE="/opt/rgb-gpus-teaming"
DEST_DESKTOP_DIR="/usr/share/applications"
DEST_EXTENSIONS_DIR="/usr/share/gnome-shell/extensions"

# Defaults
ALL_WAYS_EGPU=false
VULKAN_INSTALL=false
LITE_MODE=false
VERBOSE=true

project_basename="$(basename "$SRC_DIR")"

log() { [[ "$VERBOSE" == true ]] && printf '%s\n' "$*"; }

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  --all-ways-egpu            Install the "all-ways-egpu" launcher.
  -v, --vulkan               Install Vulkan experimental desktop files.
  -l, --lite                 Do NOT install .desktop files, DBUS services or GNOME extension (server mode).
  -h, --help                 Show this help and exit.
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all-ways-egpu) ALL_WAYS_EGPU=true; shift ;;
    -v|--vulkan) VULKAN_INSTALL=true; shift ;;
    -l|--lite) LITE_MODE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Warning: unknown argument '$1' (ignored)"; shift ;;
  esac
done

# Ensure root
if [[ "$(id -u)" -ne 0 ]]; then
  echo "This installer requires root. Re-running with sudo..."
  exec /usr/bin/sudo "$0" "$@"
fi

# Safety checks for DEST_BASE
if [[ -z "$DEST_BASE" ]]; then
  echo "Error: DEST_BASE is empty. Aborting." >&2
  exit 1
fi
if [[ "$DEST_BASE" == "/" || "$DEST_BASE" == "." ]]; then
  echo "Error: DEST_BASE looks unsafe: $DEST_BASE" >&2
  exit 1
fi

real_src="$(realpath -s "$SRC_DIR")"
real_dest_parent="$(realpath -s "$(dirname "$DEST_BASE")")"

log "Options : all-ways-egpu=$ALL_WAYS_EGPU, vulkan=$VULKAN_INSTALL, lite=$LITE_MODE"
log "Source = $real_src  →  Destination = $DEST_BASE"

# Helper to rewrite Exec= lines
rewrite_exec_cmd() {
  local src_exec="$1"
  local cmd="${src_exec#Exec=}"
  local escaped_src
  escaped_src=$(printf '%s' "$SRC_DIR" | sed 's|/|\\/|g')
  cmd=$(printf '%s' "$cmd" | sed -E "s|$escaped_src|$DEST_BASE|g")
  cmd=${cmd//\$HOME/$DEST_BASE}
  cmd=${cmd//\~/$DEST_BASE}
  cmd=$(printf '%s' "$cmd" | sed -E 's|([^:])/+|\1/|g')
  cmd="$(printf '%s' "$cmd" | sed -E 's/[[:space:]]+$//')"
  printf '%s' "$cmd"
}

# Copy project to DEST_BASE
if [[ "$real_src" != "$DEST_BASE" ]]; then
  if [[ -d "$DEST_BASE" ]]; then
    log "Removing existing destination $DEST_BASE"
    rm -rf -- "$DEST_BASE"
  fi
  mkdir -p "$DEST_BASE"

  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude='node_modules' "$SRC_DIR"/ "$DEST_BASE"/
    log "Rsync finished: $SRC_DIR → $DEST_BASE"
  else
    cp -a "$SRC_DIR"/. "$DEST_BASE"/
    log "Copied project to $DEST_BASE (cp -a used)"
  fi
else
  log "Source equals destination; skipping copy."
fi

# Install .desktop files (unless LITE)
desktop_files=("$DEST_BASE"/*.desktop)
if (( ${#desktop_files[@]} )); then
  if [[ "$LITE_MODE" == false ]]; then
    log "Installing .desktop launchers to $DEST_DESKTOP_DIR..."
    for src in "${desktop_files[@]}"; do
      [ -e "$src" ] || continue
      base="$(basename "$src")"
      if [[ "$ALL_WAYS_EGPU" != true && "$base" == "all-ways-egpu-auto-setup.desktop" ]]; then
        log "Skipping $base (all-ways-egpu not requested)"; continue
      fi
      if [[ "$VULKAN_INSTALL" != true && "$base" == *-vulkan.desktop ]]; then
        log "Skipping $base (vulkan desktop – VULKAN_INSTALL not set)"; continue
      fi
      exec_line="$(grep -m1 -E '^Exec=' "$src" || true)"
      exec_cmd=""
      if [[ -n "$exec_line" ]]; then
        exec_cmd="$(rewrite_exec_cmd "$exec_line")"
      fi
      dest="$DEST_DESKTOP_DIR/$base"
      cp -f "$src" "$dest"
      chmod 644 "$dest"
      if [[ -n "$exec_cmd" ]]; then
        try_exec="${exec_cmd%% *}"
        if command -v desktop-file-edit >/dev/null 2>&1; then
          desktop-file-edit --set-key=Exec --set-value="$exec_cmd" "$dest" || true
          desktop-file-edit --set-key=TryExec --set-value="$try_exec" "$dest" || true
        else
          sed -i -E "s|^Exec=.*|Exec=${exec_cmd}|" "$dest"
          if grep -qE '^TryExec=' "$dest"; then
            sed -i -E "s|^TryExec=.*|TryExec=${try_exec}|" "$dest"
          else
            printf '\nTryExec=%s\n' "$try_exec" >> "$dest"
          fi
        fi
      fi
      log "Installed $dest"
    done
  else
    log "Skipping desktop installation (LITE mode)."
  fi
else
  log "No .desktop files found in project."
fi

# GNOME extension install (unless LITE)
EXTENSION_UUID="rgb-gpus-teaming@astromangaming"
EXTENSION_SRC="$SRC_DIR/gnome-extension/$EXTENSION_UUID"
EXTENSION_DEST="$DEST_EXTENSIONS_DIR/$EXTENSION_UUID"
if [[ -d "$EXTENSION_SRC" ]]; then
  if [[ "$LITE_MODE" == false ]]; then
    echo "Installing GNOME extension to $EXTENSION_DEST ..."
    rm -rf "$EXTENSION_DEST"
    cp -a "$EXTENSION_SRC" "$EXTENSION_DEST"
    chmod -R 755 "$EXTENSION_DEST"
    log "Copied extension to $EXTENSION_DEST"
    if command -v gnome-extensions >/dev/null 2>&1; then
      if gnome-extensions enable "$EXTENSION_UUID" 2>/dev/null; then
        echo "GNOME extension enabled (system-wide)."
      else
        echo "Note: enabling system-wide extension may require a user session."
      fi
    else
      echo "gnome-extensions CLI not available – extension copied only."
    fi
  else
    log "Skipping GNOME extension installation (LITE mode)."
  fi
else
  log "GNOME extension source not found at $EXTENSION_SRC"
fi

# Install DBUS services (unless LITE)
install_dbus() {
  if [[ "$LITE_MODE" == true ]]; then
    log "DBUS installation skipped (LITE mode)."
    return 0
  fi
  dbus_src="$SRC_DIR/dbus"
  if [[ ! -d "$dbus_src" ]]; then
    log "Directory $dbus_src not found – DBUS installation skipped."
    return 0
  fi
  dest="/usr/share/dbus-1/services"
  mkdir -p "$dest"
  chmod 755 "$dest"
  echo "Installing GDBUS services from $dbus_src → $dest …"
  for src in "$dbus_src"/*; do
    [ -e "$src" ] || continue
    dst="$dest/$(basename "$src")"
    cp -a "$src" "$dst"
    chmod 755 "$dst"
    log "Copied $src → $dst"
  done
}
install_dbus

# ---------------------------
# Remove the source directory (user requested)
# ---------------------------
# Safety: ensure we are not about to delete root or other critical paths
real_src="$(realpath -s "$SRC_DIR")"
if [[ -z "$real_src" || "$real_src" == "/" || "$real_src" == "" ]]; then
  echo "Refusing to remove unsafe path: $real_src" >&2
  exit 1
fi

# Change working directory to avoid deleting current working dir
log "Changing working directory to /tmp before removing source directory."
cd /tmp || true

log "Removing source directory: $real_src"
rm -rf -- "$real_src"
log "Source directory removed: $real_src"

# Final messages
log "System-wide installation complete."

echo "Source directory removed: $real_src"
echo "Desktop files installed to $DEST_DESKTOP_DIR"
echo "Project files installed to $DEST_BASE"

if [[ -d "$SRC_DIR/dbus" ]]; then
  echo "DBUS services installed in /usr/share/dbus-1/services/"
fi
if [[ -d "$EXTENSION_SRC" ]]; then
  echo "GNOME extension is present at $EXTENSION_DEST"
fi

echo "If the GNOME extension does not appear, enable it in your user session:"
echo "  gnome-extensions enable $EXTENSION_UUID"

exit 0
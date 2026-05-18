#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# install-rgb-gpus-teaming.sh
#
# Usage: sudo ./install-rgb-gpus-teaming.sh [options]
#
# Options:
#   --all-ways-egpu            Install the “all‑ways‑egpu” launcher.
#   -v, --vulkan               Install all Vulkan experimental desktop files.
#   -h, --help                 Show this help and exit.
#
# ------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"
SRC_DIR="$(pwd)"
DEST_BASE="/opt/rgb-gpus-teaming"
DEST_DESKTOP_DIR="/usr/share/applications"
DEST_EXTENSIONS_DIR="/usr/share/gnome-shell/extensions"

# ---------------------------------------------------------------------------
# Default values – can be overridden by command line options
# ---------------------------------------------------------------------------
ALL_WAYS_EGPU=false          # install the “all‑ways‑egpu” launcher
VULKAN_INSTALL=false         # copy Vulkan experimental related desktop
VERBOSE=true                 # set to false to silence log messages

log() { [[ "$VERBOSE" == true ]] && printf '%s\n' "$*"; }

# ---------------------------------------------------------------------------
# Help output
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  --all-ways-egpu            Install the “all‑ways‑egpu” launcher.
  -v, --vulkan               Install all Vulkan experimental desktop files.
  -h, --help                 Show this help and exit.
EOF
}

# ---------------------------------------------------------------------------
# Parse command‑line arguments
# ---------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --all-ways-egpu) ALL_WAYS_EGPU=true ;;
    -v|--vulkan) VULKAN_INSTALL=true ;;   # optional flag – affects .desktop handling
    -h|--help) usage; exit 0 ;;
    *) echo "Warning: unknown argument '$arg' (ignored)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Must run as root, source directory must exist …
# ---------------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
  echo "This installer requires root. Re‑running with sudo..."
  exec sudo "$0" "$@"
fi

if [[ ! -d "$SRC_DIR" ]]; then
  echo "Error: source directory not found: $SRC_DIR" >&2
  exit 2
fi

# Build absolute paths for the safety check used later
real_src="$(realpath -s "$SRC_DIR")"
real_dest_parent="$(realpath -s "$(dirname "$DEST_BASE")")"

log "Options : all‑ways‑egpu=$ALL_WAYS_EGPU, vulkan=$VULKAN_INSTALL"
log "Source = $real_src  →  Destination = $DEST_BASE"

# ---------------------------------------------------------------------------
# Copy the whole project to DEST_BASE (deep copy)
# ---------------------------------------------------------------------------
SKIP_COPY=false
if [[ -z "$real_dest_parent" || "$real_src" != "$DEST_BASE" ]]; then
  # destination does not exist or is different → remove any old tree and rsync/cp it
  rm -rf "$DEST_BASE"
  mkdir -p "$DEST_BASE"

  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude='node_modules' "$SRC_DIR/" "$DEST_BASE/"
    log "Rsync finished: $SRC_DIR → $DEST_BASE"
  else
    cp -a "$SRC_DIR/." "$DEST_BASE/"
    log "Copied project to $DEST_BASE (cp‑a used)"
  fi
else
  log "Source = destination → skip copy."
fi

# ---------------------------------------------------------------------------
# Helper: rewrite Exec= lines in .desktop files with absolute /opt paths
# ---------------------------------------------------------------------------
rewrite_exec_cmd() {
  local src_exec="$1"
  local cmd="${src_exec#Exec=}"
  # replace $SRC_DIR → DEST_BASE (escaped)
  cmd="$(printf '%s' "$cmd" | sed -E "s|$(printf '%s' "$SRC_DIR" | sed 's|/|\\/|g')|$DEST_BASE|g")"
  # replace $HOME/$HOME → DEST_BASE
  cmd="${cmd//\$HOME/$DEST_BASE}"
  cmd="${cmd//\~/$DEST_BASE}"
  # collapse duplicate DEST_BASE substrings and multiple slashes
  cmd="$(printf '%s' "$cmd" | sed -E 's|([^:])/+|\1/|g')"
  printf '%s' "$cmd"
}

# ---------------------------------------------------------------------------
# Install .desktop files (only those that are not skipped by flags)
# ---------------------------------------------------------------------------
desktop_files=("$DEST_BASE"/*.desktop)

if (( ${#desktop_files[@]} )); then
  log "Installing .desktop launchers to $DEST_DESKTOP_DIR..."

  for src in "${desktop_files[@]}"; do
    base="$(basename "$src")"

    # Skip the “all‑ways‑egpu” launcher if it is not requested
    if [[ "$ALL_WAYS_EGPU" != true && "$base" == "all-ways-egpu-auto-setup.desktop" ]]; then
      log "Skipping $base (all‑ways‑egpu not requested)"
      continue
    fi

    # Skip any desktop that contains "-vulkan.desktop" when the vulkan flag is off
    if [[ "$VULKAN_INSTALL" != true && "${base#*.}" == "desktop" \
          && "$(basename "$src" | sed 's|.desktop||')" == *"-vulkan"* ]]; then
      log "Skipping $base (vulkans desktop – VULKAN_INSTALL not set)"
      continue
    fi

    # Normal handling: copy to /usr/share/applications/
    exec_line="$(grep -m1 -E '^Exec=' "$src" || true)"
    exec_cmd=""
    if [[ -n "$exec_line" ]]; then
      exec_cmd="$(rewrite_exec_cmd "$exec_line")"
    fi

    dest="$DEST_DESKTOP_DIR/$base"
    cp -f "$src" "$dest"
    chmod 644 "$dest"

    # Update Exec= and TryExec= if needed
    if [[ -n "$exec_cmd" ]]; then
      if command -v desktop-file-edit >/dev/null 2>&1; then
        desktop-file-edit --set-key=Exec --set-value="$exec_cmd" "$dest" || true
        desktop-file-edit --set-key=TryExec \
          --set-value="$(printf '%s' "$exec_cmd" | awk '{print $1}')" "$dest" || true
      else
        sed -i -E "s|^Exec=.*|Exec=${exec_cmd}|" "$dest"
        if grep -qE '^TryExec=' "$dest"; then
          sed -i -E "s|^TryExec=.*|TryExec=$(printf '%s' "$exec_cmd" | awk '{print $1}')|" "$dest"
        else
          printf 'TryExec=%s\n' "$(printf '%s' "$exec_cmd" | awk '{print $1}')" >> "$dest"
        fi
      fi
    fi

    log "Installed $dest"
  done
else
  echo "No .desktop files found in project."
fi

# ---------------------------------------------------------------------------
# Install GNOME extension (system‑wide)
# ---------------------------------------------------------------------------
EXTENSION_UUID="rgb-gpus-teaming@astromangaming"
EXTENSION_SRC="$SRC_DIR/gnome-extension/$EXTENSION_UUID"
EXTENSION_DEST="$DEST_EXTENSIONS_DIR/$EXTENSION_UUID"

if [[ -d "$EXTENSION_SRC" ]]; then
  echo "Installing GNOME extension to $EXTENSION_DEST..."
  rm -rf "$EXTENSION_DEST"
  cp -a "$EXTENSION_SRC" "$EXTENSION_DEST"
  chmod -R 755 "$EXTENSION_DEST"

  log "Copied extension to $EXTENSION_DEST"

  if command -v gnome-extensions >/dev/null 2>&1; then
    if gnome-extensions enable "$EXTENSION_UUID" 2>/dev/null; then
      echo "GNOME extension enabled (system‑wide)."
    else
      echo "Note: enabling system‑wide extension may require a user session."
    fi
  else
    echo "gnome-extensions CLI not available – extension copied only."
  fi
else
  echo "GNOME extension source not found at $EXTENSION_SRC"
fi

# ---------------------------------------------------------------------------
# Install GDBUS services (system‑wide)
# ---------------------------------------------------------------------------
install_dbus() {
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
    [ -e "${dest}/$(basename "$src")" ] && continue

    rel="${src#$SRC_DIR/}"
    dst="$(dirname "$dest")/$(basename "$rel")"
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
    chmod 755 "$dst"
    log "Copied $src → $dst"
  done
}
install_dbus

# ---------------------------------------------------------------------------
# Remove any local copy from users’ home directories (if present)
# ---------------------------------------------------------------------------
remove_user_src_dir() {
  local project_basename="$(basename "$SRC_DIR")"

  # Determine which user(s) should have their copies removed
  local target_user=""
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
    target_user="${SUDO_USER}"
  fi

  for uid in $(awk -v h="${target_user}${user_home}:" 'BEGIN{getent passwd $1 | getline $0; split($0,a:); if(a[7]~"/home/$(basename "$SCRIPT_NAME")" && a[7]!="-") print $1}' /etc/passwd) ; do
    user_home="$(awk -v u=$uid '{print $6}' /etc/passwd)"
    candidate="$user_home/$project_basename"
    if [[ -e "$candidate" ]] && ( [[ -d "$candidate" ]] || ls -A "$candidate" >/dev/null 2>&1 ); then
      rm -rf -- "$candidate"
    fi
  done

  log "Removed local copies where found."
}
remove_user_src_dir

# ---------------------------------------------------------------------------
# Final messages
# ---------------------------------------------------------------------------
log "System‑wide installation complete."

echo "Local copies of the project (~$project_basename) removed where found."
echo "Desktop files installed to $DEST_DESKTOP_DIR"
echo "Project files installed to $DEST_BASE"

if [[ -d "$SRC_DIR/dbus" ]]; then
  echo "DBUS services installed in /usr/share/dbus-1/services/"
fi

if [[ -d "$EXTENSION_DEST" && -f "$EXTENSION_DEST/manifest.json" ]]; then
  echo "GNOME extension is present at $EXTENSION_DEST"
fi

echo "If the GNOME extension does not appear, enable it in your user session:"
echo "  gnome-extensions enable $EXTENSION_UUID"

exit 0
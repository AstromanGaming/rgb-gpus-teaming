#!/usr/bin/env bash
set -euo pipefail

# install-rgb-gpus-teaming.sh
#
# Usage: sudo ./install-rgb-gpus-teaming.sh [--all-ways-egpu] [--help]
#
# Note: This script performs a system-wide install under /opt. After the
# system-wide install completes, it will automatically remove any user-local
# copies of the project directory named "$(basename "$PWD")" found in users'
# home directories (/home/* and /root/*). It will never remove /opt/rgb-gpus-teaming
# or any path outside users' home directories.

SCRIPT_NAME="$(basename "$0")"
SRC_DIR="$(pwd)"
DEST_BASE="/opt/rgb-gpus-teaming"
DEST_DESKTOP_DIR="/usr/share/applications"
DEST_NAUTILUS_DIR="/usr/share/nautilus/scripts"
DEST_EXTENSIONS_DIR="/usr/share/gnome-shell/extensions"
EXTENSION_UUID="rgb-gpus-teaming@astromangaming"
EXTENSION_SRC="$SRC_DIR/gnome-extension/$EXTENSION_UUID"
EXTENSION_DEST="$DEST_EXTENSIONS_DIR/$EXTENSION_UUID"

ALL_WAYS_EGPU=false
VERBOSE=true

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  --all-ways-egpu    Install the all-ways-egpu desktop launcher as well.
  -h, --help         Show this help message and exit.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --all-ways-egpu) ALL_WAYS_EGPU=true ;;
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
log "Options: all-ways-egpu=$ALL_WAYS_EGPU"

# Resolve real paths to detect same-dir or nested installs
real_src="$(realpath -s "$SRC_DIR")"
real_dest_parent="$(realpath -s "$(dirname "$DEST_BASE")")"
real_dest="$(realpath -s "$DEST_BASE" 2>/dev/null || true)"

# Determine whether we are running from inside the destination
SKIP_COPY=false
if [[ -n "$real_dest" && "$real_src" == "$real_dest" ]]; then
  log "Source directory is the same as destination ($real_src == $real_dest). Skipping copy step."
  SKIP_COPY=true
elif [[ -n "$real_dest" && "$real_src" == "$real_dest_parent" ]]; then
  # unlikely but handle parent equality
  log "Source directory equals destination parent; proceeding carefully."
fi

if [[ "$SKIP_COPY" == true ]]; then
  # Do not remove or copy; assume files are already in place
  log "Skipping rm/cp because installer was invoked from inside $DEST_BASE."
  mkdir -p "$DEST_BASE"
else
  # Safe copy: remove old tree then copy
  rm -rf "$DEST_BASE"
  mkdir -p "$DEST_BASE"
  # Prefer rsync if available to avoid cp self-copy issues
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude='node_modules' "$SRC_DIR/" "$DEST_BASE/"
  else
    cp -a "$SRC_DIR/." "$DEST_BASE/"
  fi
  log "Copied project to $DEST_BASE"
fi

# Helper to rewrite Exec lines to absolute /opt paths
rewrite_exec_cmd() {
  local src_exec="$1"
  local cmd="${src_exec#Exec=}"

  # Replace explicit $SRC_DIR occurrences with DEST_BASE
  # Use printf+sed to avoid accidental shell expansion
  cmd="$(printf '%s' "$cmd" | sed -E "s|$(printf '%s' "$SRC_DIR" | sed 's|/|\\/|g')|$DEST_BASE|g")"

  # Replace $HOME and ~ with DEST_BASE
  cmd="${cmd//\$HOME/$DEST_BASE}"
  cmd="${cmd//\~/$DEST_BASE}"

  # Collapse duplicate DEST_BASE substrings and multiple slashes
  cmd="${cmd//${DEST_BASE}${DEST_BASE}/${DEST_BASE}}"
  cmd="$(printf '%s' "$cmd" | sed -E 's|([^:])/+|\1/|g')"

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
    log "Installed $dest"
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
    cp -f "$s" "$dest"
    chmod 755 "$dest"
    log "Installed Nautilus script $dest"
  done
else
  echo "No Nautilus scripts found in project."
fi

# GNOME extension
if [[ -d "$EXTENSION_SRC" ]]; then
  echo "Installing GNOME extension to $EXTENSION_DEST..."
  rm -rf "$EXTENSION_DEST"
  cp -a "$EXTENSION_SRC" "$EXTENSION_DEST"
  chmod -R 755 "$EXTENSION_DEST"
  log "Copied extension to $EXTENSION_DEST"

  if command -v gnome-extensions >/dev/null 2>&1; then
    if gnome-extensions enable "$EXTENSION_UUID" 2>/dev/null; then
      echo "GNOME extension enabled (system-wide)."
    else
      echo "Note: enabling system-wide extension may require a user session. Enable it in the user's session if needed."
    fi
  else
    echo "gnome-extensions CLI not available; extension copied but not enabled."
  fi
else
  echo "GNOME extension source not found at $EXTENSION_SRC"
fi

shopt -u nullglob

remove_user_src_dir() {
  local target_user=""

  # parse optional arg (username) - not used in automatic call
  for a in "$@"; do
    case "$a" in
      *) target_user="$a" ;;
    esac
  done

  local project_basename
  project_basename="$(basename "$SRC_DIR")"

  log "remove_user_src_dir: project basename = $project_basename"

  # helper: safe remove only under /home or /root and never DEST_BASE
  safe_rm_home() {
    local path="$1"
    [[ -z "$path" ]] && return 0
    local abs
    abs="$(readlink -f -- "$path" 2>/dev/null || true)"
    if [[ -z "$abs" ]]; then
      log "safe_rm_home: path not found: $path"
      return 0
    fi
    # never remove DEST_BASE or anything outside /home or /root
    if [[ -n "$(readlink -f -- "$DEST_BASE" 2>/dev/null || true)" && "$abs" == "$(readlink -f -- "$DEST_BASE" 2>/dev/null || true)"* ]]; then
      log "Skipping removal of DEST_BASE or paths under it: $abs"
      return 0
    fi
    case "$abs" in
      /home/*|/root/*)
        rm -rf -- "$abs" && log "Removed: $abs"
        ;;
      *)
        log "Skipping removal outside home: $abs"
        ;;
    esac
  }

  # build list of users to process
  local users=()
  if [[ -n "$target_user" ]]; then
    users=("$target_user")
  else
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
      users+=("$SUDO_USER")
    fi
    while IFS=: read -r uname _ uid _ home _; do
      if [[ -n "$home" && -d "$home" && "$uname" != "nobody" ]] && (( uid >= 1000 )); then
        case " ${users[*]} " in
          *" $uname "*) ;;
          *) users+=("$uname") ;;
        esac
      fi
    done < /etc/passwd
  fi

  if (( ${#users[@]} == 0 )); then
    log "remove_user_src_dir: aucun utilisateur cible trouvé."
    return 0
  fi

  for u in "${users[@]}"; do
    user_home="$(getent passwd "$u" | cut -d: -f6 || true)"
    if [[ -z "$user_home" || ! -d "$user_home" ]]; then
      log "remove_user_src_dir: utilisateur $u home introuvable, skip."
      continue
    fi

    local candidate="$user_home/$project_basename"
    if [[ -e "$candidate" ]]; then
      # only remove if it looks like the project (best-effort checks)
      if [[ -d "$candidate" ]] && ( [[ -e "$candidate/README.md" ]] || [[ -e "$candidate/.git" ]] || [[ -e "$candidate/nautilus-scripts" ]] || ls -A "$candidate" >/dev/null 2>&1 ); then
        log "remove_user_src_dir: removing $candidate for user $u"
        safe_rm_home "$candidate"
      else
        log "remove_user_src_dir: found $candidate but it doesn't look like the project; skipping."
      fi
    else
      log "remove_user_src_dir: $candidate not present for $u"
    fi
  done
}

# ---------------------------------------------------------------------------
# Automatic call: Delete user-local copies from the SRC_DIR folder
# (executed automatically after system installation)
# ---------------------------------------------------------------------------
remove_user_src_dir
# ---------------------------------------------------------------------------

echo "System-wide installation to /opt complete."
echo "User-local copies of the project (~/$(basename "$SRC_DIR")) have been removed where found."
echo "Desktop files installed to $DEST_DESKTOP_DIR"
echo "Project files installed to $DEST_BASE"
echo "If the extension does not appear, enable it in the user's GNOME session or run:"
echo "  gnome-extensions enable $EXTENSION_UUID"

exit 0


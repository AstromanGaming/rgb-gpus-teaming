#!/usr/bin/env bash
set -euo pipefail

# uninstall-rgb-gpus-teaming.sh
#
# Usage:
#   sudo ./uninstall-rgb-gpus-teaming.sh [--confirm] [--help]
#
# Notes:
#  - By default the script runs in safe (simulation) mode.
#  - Pass --confirm to perform actual removals.

OPT_BASE="/opt/rgb-gpus-teaming"
MANIFEST="$OPT_BASE/install-manifest.txt"
EXTENSION_UUID="rgb-gpus-teaming@astromangaming"
EXTENSION_SYS="/usr/share/gnome-shell/extensions/$EXTENSION_UUID"
NAUTILUS_SCRIPT="/usr/share/nautilus/scripts/Launch with RGB GPUs Teaming"
DESKTOP_DIR="/usr/share/applications"

# Defaults
DRY_RUN=true
VERBOSE=true
CONFIRM=false

# Save original args so we can re-exec with sudo preserving them
ORIG_ARGS=( "$@" )

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --confirm                Actually perform removals.
  -h, --help               Show this help and exit.
EOF
}

# Strict parsing: reject unknown options (except --confirm)
while (( "$#" )); do
  case "$1" in
    --confirm) CONFIRM=true; DRY_RUN=false; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "Error: unknown option '$1'"; usage; exit 2 ;;
    *) echo "Error: unexpected positional argument '$1'"; usage; exit 2 ;;
  esac
done

# Logging helpers (no --silent support)
log() { [[ "$VERBOSE" == true ]] && printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }
info() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

# Canonicalization and containment check
# Sets OPT_BASE_CANON once and returns canonical path in CANON_PATH.
# Returns 0 if candidate canonicalizes and is inside OPT_BASE, else 1.
canonicalize_and_check() {
  local candidate="$1"

  # Compute canonical OPT_BASE once
  if [[ -z "${OPT_BASE_CANON+x}" ]]; then
    if command -v readlink >/dev/null 2>&1; then
      OPT_BASE_CANON="$(readlink -f -- "$OPT_BASE" 2>/dev/null || true)"
    fi
    if [[ -z "${OPT_BASE_CANON:-}" ]]; then
      if command -v python3 >/dev/null 2>&1; then
        OPT_BASE_CANON="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$OPT_BASE" 2>/dev/null || true)"
      fi
    fi
    OPT_BASE_CANON="${OPT_BASE_CANON:-$OPT_BASE}"
  fi

  # Make candidate absolute if relative
  if [[ "$candidate" != /* ]]; then
    candidate="$OPT_BASE/$candidate"
  fi

  # Canonicalize candidate
  if command -v readlink >/dev/null 2>&1; then
    CANON_PATH="$(readlink -f -- "$candidate" 2>/dev/null || true)"
  else
    if command -v python3 >/dev/null 2>&1; then
      CANON_PATH="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$candidate" 2>/dev/null || true)"
    else
      CANON_PATH="$candidate"
    fi
  fi
  CANON_PATH="${CANON_PATH:-$candidate}"

  # Ensure containment: CANON_PATH must be OPT_BASE_CANON or under it
  case "$CANON_PATH" in
    "$OPT_BASE_CANON" | "$OPT_BASE_CANON"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# If not root, re-exec with sudo unless running simulation (DRY_RUN)
if [[ "$(id -u)" -ne 0 ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    err "Warning: running in simulation mode as non-root; some actions may require root"
  else
    err "This script must be run as root to perform removals. Re-running with sudo..."
    exec sudo "$0" "${ORIG_ARGS[@]}"
  fi
fi

# Header
info ''
info '# uninstall-rgb-gpus-teaming.sh'
info "# Target: $OPT_BASE"
info "# Mode: $([[ "$DRY_RUN" == true ]] && echo "Simulation (no removals)" || echo "Confirmed (destructive)")"
info ''

run_rm() {
  local path="$1"
  if [[ "$DRY_RUN" == true ]]; then
    info "[SIMULATION] Would remove: $path"
    log "[SIMULATION] Would remove: $path"
    return 0
  fi

  if [[ -e "$path" || -L "$path" ]]; then
    rm -rf -- "$path"
    log "Removed: $path"
    return 0
  else
    log "Not found (skipping): $path"
    return 0
  fi
}

info "Uninstall starting. Target: $OPT_BASE"
log "Options: confirm=$CONFIRM verbose=$VERBOSE"

# If manifest exists, remove listed items (reverse order). Top-level removed only when --confirm passed.
if [[ -f "$MANIFEST" ]]; then
  log "Using manifest: $MANIFEST"
  mapfile -t raw_items < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$MANIFEST")

  for ((i=${#raw_items[@]}-1; i>=0; i--)); do
    item="${raw_items[i]}"
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -z "$item" ]] && continue

    if ! canonicalize_and_check "$item"; then
      log "Skipping unsafe or out-of-tree path (not under $OPT_BASE): $item"
      continue
    fi
    item_norm="${CANON_PATH%/}"

    # If item is the top-level OPT_BASE, only remove when CONFIRM is true
    if [[ "$item_norm" == "${OPT_BASE%/}" ]]; then
      if [[ "$CONFIRM" == true ]]; then
        run_rm "$item_norm"
      else
        log "Top-level directory preserved (pass --confirm to remove): $OPT_BASE"
      fi
    else
      run_rm "$item_norm"
    fi
  done
else
  log "No manifest found; removing a conservative explicit list."

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
    if canonicalize_and_check "$p"; then
      run_rm "${CANON_PATH%/}"
    else
      log "Skipping unsafe or out-of-tree path (not under $OPT_BASE): $p"
    fi
  done

  # System-level items (outside OPT_BASE) — removed only when --confirm passed
  if [[ "$CONFIRM" == true ]]; then
    run_rm "$DESKTOP_DIR/advisor.desktop"
    run_rm "$DESKTOP_DIR/gnome-setup.desktop"
    run_rm "$DESKTOP_DIR/manual-setup.desktop"
    run_rm "$DESKTOP_DIR/all-ways-egpu-auto-setup.desktop"
    run_rm "$NAUTILUS_SCRIPT"
    run_rm "$EXTENSION_SYS"
  else
    log "System-level items preserved (pass --confirm to remove): desktop entries, nautilus script, extension"
  fi

  # Remove top-level OPT_BASE only when --confirm passed
  if [[ "$CONFIRM" == true ]]; then
    if canonicalize_and_check "$OPT_BASE"; then
      run_rm "${CANON_PATH%/}"
    else
      err "Refusing to remove $OPT_BASE: canonicalization failed or not contained."
      exit 4
    fi
  else
    log "Top-level directory preserved (pass --confirm to remove): $OPT_BASE"
  fi
fi

# Best-effort: disable system extension (only when confirmed)
if command -v gnome-extensions >/dev/null 2>&1; then
  if [[ "$CONFIRM" == true ]]; then
    gnome-extensions disable "$EXTENSION_UUID" 2>/dev/null || true
    log "Attempted to disable extension: $EXTENSION_UUID"
  else
    log "Skipping extension disable (pass --confirm to disable): $EXTENSION_UUID"
  fi
fi

info "Uninstall finished. Top-level directory removed: $([[ "$CONFIRM" == true ]] && echo "yes" || echo "no")"

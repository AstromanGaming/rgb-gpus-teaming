#!/usr/bin/env bash
set -euo pipefail

# uninstall-rgb-gpus-teaming.sh
#
# Usage: sudo ./remove-rgb-gpus-teaming.sh [--confirm] [-h|--help]

OPT_BASE="/opt/rgb-gpus-teaming"

EXTENSION_UUID="rgb-gpus-teaming@astromangaming"
DBUS_UUID="ca.astromangaming.RGB-GPUs-Teaming"
EXTENSION_SYS="/usr/share/gnome-shell/extensions/$EXTENSION_UUID"
DBUS_SYS="/usr/share/dbus-1/services/$DBUS_UUID"

DESKTOP_DIR="/usr/share/applications"

# Defaults
DRY_RUN=true
VERBOSE=true
CONFIRM=false

ORIG_ARGS=( "$@" )

usage() {
cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --confirm                Actually perform removals.
  -h, --help               Show this help and exit.
EOF
}

while (( "$#" )); do
case "$1" in
--confirm) CONFIRM=true; DRY_RUN=false; shift ;;
-h|--help) usage; exit 0 ;;
--) echo "Error: unknown option '$1'"; usage; exit 2 ;;
*)   echo "Error: unexpected positional argument '$1'"; usage; exit 2 ;;
esac
done

log() { [[ "$VERBOSE" == true ]] && printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }
info() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

canonicalize_and_check() {
local candidate="$1"
if [[ -z "${OPT_BASE_CANON+x}" ]]; then
    if command -v readlink >/dev/null 2>&1; then
        OPT_BASE_CANON="$(readlink -f -- "$OPT_BASE" 2>/dev/null || true)"
    elif command -v python3 >/dev/null 2>&1; then
        OPT_BASE_CANON="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$OPT_BASE" 2>/dev/null || true)"
    fi
    OPT_BASE_CANON="${OPT_BASE_CANON:-$OPT_BASE}"
fi

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

case "$CANON_PATH" in
"$OPT_BASE_CANON" | "$OPT_BASE_CANON"/*) return 0 ;;
*) return 1 ;;
esac
}

if [[ "$(id -u)" -ne 0 ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        err "Warning: running in simulation mode as non‑root; some actions may require root"
    else
        err "This script must be run as root to perform removals. Re‑running with sudo..."
        exec sudo "${0}" "${ORIG_ARGS[@]}"
    fi
fi

# Header
info ''
info "# uninstall-rgb-gpus-teaming.sh"
info "# Target: $OPT_BASE"
info "# Mode: $( [[ \"$DRY_RUN\" == true ]] && echo "Simulation (no removals)" || echo "Confirmed (destructive)")"
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
else
    log "Not found (skipping): $path"
fi
return 0
}

info "Uninstall starting. Target: $OPT_BASE"
log "Options: confirm=$CONFIRM verbose=$VERBOSE"

# ----------------------------------------------------------------------
#   DYNAMIC removal – **everything** inside OPT_BASE except the top‑level dir
# ----------------------------------------------------------------------
info "Performing a fully automatic clean‑up."

mapfile -t files_to_remove < <(
    find "$OPT_BASE" -mindepth 1 -type f | sort
)

for p in "${files_to_remove[@]}"; do
    if canonicalize_and_check "$p"; then
        run_rm "${CANON_PATH%/}"
    else
        info "Skipping unsafe or out‑of‑tree path (not under $OPT_BASE): $p"
    fi
done

# ----------------------------------------------------------------------
#   System‑level items – removed only when --confirm
# ----------------------------------------------------------------------

declare -a desktop_files=(
    "advisor.desktop"
    "gnome-setup.desktop"
    "manual-setup.desktop"
    "all-ways-egpu-auto-setup.desktop"
    "gnome-setup-vulkan.desktop"
    "advisor-vulkan.desktop"
    "manual-setup-vulkan.desktop"
)

if [[ "$CONFIRM" == true ]]; then
    run_rm "$EXTENSION_SYS"
    run_rm "$DBUS_SYS"

    for f in "${desktop_files[@]}"; do
        run_rm "$DESKTOP_DIR/$f"
    done
fi

# ----------------------------------------------------------------------
#   Best‑effort: disable system extension (uses EXTENSION_UUID only)
# ----------------------------------------------------------------------
if command -v gnome-extensions >/dev/null 2>&1; then
    if [[ "$CONFIRM" == true ]]; then
        gnome-extensions disable "$EXTENSION_UUID" 2>/dev/null || true
        log "Attempted to disable extension: $EXTENSION_UUID"
    else
        info "Skipping extension disable (pass --confirm to disable): $EXTENSION_UUID"
    fi
fi

# ----------------------------------------------------------------------
#   Top‑level OPT_BASE – removed only when confirmed
# ----------------------------------------------------------------------
if [[ "$CONFIRM" == true ]]; then
    if canonicalize_and_check "$OPT_BASE"; then
        run_rm "${CANON_PATH%/}"
    else
        err "Refusing to remove $OPT_BASE: canonicalization failed or not contained."
        exit 4
    fi
else
    info "Top‑level directory preserved (pass --confirm to remove): $OPT_BASE"
fi

info "Uninstall finished. Top‑level directory removed: $( [[ \"$CONFIRM\" == true ]] && echo \"yes\" || echo \"no\")"
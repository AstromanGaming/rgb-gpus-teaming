#!/bin/bash
set -euo pipefail

# all-ways-egpu-auto-setup.sh
# Interactive menu to build/apply final all-ways-egpu answers for a system install.
# Expects system install at /opt/rgb-gpus-teaming

INSTALL_BASE="/opt/rgb-gpus-teaming"
CONF_DIR="/usr/share/all-ways-egpu"
CONFIG_DIR="$INSTALL_BASE/config"
MEM_FILE="$CONFIG_DIR/gpu_all-ways-egpu_config"
FINAL_FILE="$CONFIG_DIR/gpu_all-ways-egpu_final"

# Determine the real (non-root) user reliably
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
HOME_DIR="$(getent passwd "$REAL_USER" | cut -d: -f6 || true)"

# Helper: read a yes/no answer, accept y/Y/1 as yes, empty or n/N as no
read_yesno() {
    local prompt="$1"
    local ans
    while true; do
        read -r -p "$prompt" ans
        case "$ans" in
            [yY]|1) return 0 ;;
            [nN]|'') return 1 ;;
            *) echo "Please answer y (yes) or n (no). Typing 1 is accepted as yes." ;;
        esac
    done
}

# Ensure running as root for system-wide writes; re-exec with sudo if not
if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script requires root. Re-running with sudo..."
    exec sudo -- "$0" "$@"
fi

# Basic checks
if [[ -z "$REAL_USER" || -z "$HOME_DIR" ]]; then
    printf '%s\n' "Warning: could not determine real user or home directory; defaulting to root." >&2
    REAL_USER="root"
    HOME_DIR="/root"
fi

if [[ ! -d "$INSTALL_BASE" ]]; then
    printf '%s\n' "Error: expected installation not found: $INSTALL_BASE" >&2
    exit 1
fi

# Ensure config dir exists
mkdir -p "$CONFIG_DIR"
chmod 0755 "$CONFIG_DIR"

# Embedded advisor: generates MEM_FILE
generate_memfile_inline() {
    local cfg="$MEM_FILE"
    local EXTENDED_PERMS=0644

    # Check lspci availability
    if ! command -v lspci >/dev/null 2>&1; then
        printf '%s\n' "Error: lspci is not installed. Install pciutils (e.g., apt install pciutils)." >&2
        return 1
    fi

    # Create/empty the config file
    : > "$cfg"
    chmod "$EXTENDED_PERMS" "$cfg"

    # Helper to safely append a quoted key="value" line to the config file
    write_config() {
        local key="$1"
        local val="$2"
        val="${val//\\/\\\\}"
        val="${val//\"/\\\"}"
        printf '%s="%s"\n' "$key" "$val" >> "$cfg"
    }

    # Use the old/plain lspci parsing logic (the "oid" config)
    local i=1 j=1
    while IFS= read -r line; do
        [[ -z "${line// /}" ]] && continue
        if printf '%s\n' "$line" | grep -Eq "VGA|3D"; then
            gpu_name="$(printf '%s' "$line" | sed -E 's/^[^[:space:]]+[[:space:]]+[^:]+:[[:space:]]*//')"
            gpu_name="$(printf '%s' "$gpu_name" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
            write_config "GPU_${i}_name" "$gpu_name"
            printf 'Detected GPU_%s: %s\n' "$i" "$gpu_name"
            ((i++))
        fi
    done < <(lspci || true)

    while IFS= read -r line; do
        [[ -z "${line// /}" ]] && continue
        if printf '%s\n' "$line" | grep -Eq "Audio"; then
            audio_name="$(printf '%s' "$line" | sed -E 's/^[^[:space:]]+[[:space:]]+[^:]+:[[:space:]]*//')"
            audio_name="$(printf '%s' "$audio_name" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
            write_config "AUDIO_${j}_name" "$audio_name"
            printf 'Detected AUDIO_%s: %s\n' "$j" "$audio_name"
            ((j++))
        fi
    done < <(lspci || true)

    # If no devices found, warn and remove empty config
    if [[ $i -eq 1 && $j -eq 1 ]]; then
        printf '%s\n' "Warning: no VGA/3D or Audio devices detected by lspci." >&2
        printf '%s\n' "Check that lspci returns output and that you have permission to run it." >&2
        rm -f "$cfg" || true
        return 1
    fi

    # Set ownership to REAL_USER if valid and not root
    if [[ "$REAL_USER" != "root" && -n "$(getent passwd "$REAL_USER")" ]]; then
        chown "$REAL_USER":"$REAL_USER" "$cfg"
    else
        printf 'TRACE: skipping chown for memfile, REAL_USER=%s\n' "$REAL_USER" >&2
    fi
    chmod "$EXTENDED_PERMS" "$cfg"

    printf 'Initial configuration written to %s\n' "$cfg"
    return 0
}

# Regenerate MEM_FILE using the embedded advisor only
generate_memfile_inline || true

# If MEM_FILE still missing or empty, warn and continue (menu will check)
if [[ ! -s "$MEM_FILE" ]]; then
    printf '%s\n' "Warning: $MEM_FILE not found or empty after scanning. The interactive menu requires this file." >&2
fi

# Interactive menu
while true; do
    clear
    echo "===== Configuration Menu ====="
    echo "1) Use existing memory"
    echo "2) Configure eGPU"
    echo "3) Embedded advisor output"
    echo "4) Exit"
    read -r -p "Enter choice [1/2/3/4]: " choice

    case "$choice" in
        1)
            if [[ ! -s "$FINAL_FILE" ]]; then
                echo "No memory file found or it's empty. Please run configure eGPU first."
                read -r -p "Press Enter to return to menu..."
                continue
            fi
            echo "Using existing final configuration from $FINAL_FILE"
            ;;
        2)
            echo "Configure eGPU interactively..."
            if [[ ! -s "$MEM_FILE" ]]; then
                echo "Output file is missing. Please run embedded advisor output first."
                read -r -p "Press Enter to return to menu..."
                continue
            fi
            source "$MEM_FILE"
            : > "$FINAL_FILE"

            # --- GPUs ---
            i=1
            while true; do
                name_var="GPU_${i}_name"
                name="${!name_var:-}"
                [[ -z "$name" ]] && break

                echo "GPU_$i: $name"
                if read_yesno "Is this the eGPU? [y/N] "; then
                    printf 'GPU_%d_name="%s"\nGPU_%d_value="y"\n\n' "$i" "$name" "$i" >> "$FINAL_FILE"
                else
                    printf 'GPU_%d_name="%s"\nGPU_%d_value="n"\n\n' "$i" "$name" "$i" >> "$FINAL_FILE"
                fi
                ((i++))
            done

            # --- Audio devices ---
            j=1
            while true; do
                aname_var="AUDIO_${j}_name"
                aname="${!aname_var:-}"
                [[ -z "$aname" ]] && break

                echo "AUDIO_$j: $aname"
                if read_yesno "Is this the eGPU audio device? [y/N] "; then
                    printf 'AUDIO_%d_name="%s"\nAUDIO_%d_value="y"\n\n' "$j" "$aname" "$j" >> "$FINAL_FILE"
                else
                    printf 'AUDIO_%d_name="%s"\nAUDIO_%d_value="n"\n\n' "$j" "$aname" "$j" >> "$FINAL_FILE"
                fi
                ((j++))
            done

            if [[ ! -s "$FINAL_FILE" ]]; then
                echo "No eGPU configured. Final file not created."
                rm -f "$FINAL_FILE"
                read -r -p "Press Enter to return to menu..."
                continue
            fi

            # Ensure final file owned by real user
            if [[ "$REAL_USER" != "root" && -n "$(getent passwd "$REAL_USER")" ]]; then
                chown "$REAL_USER":"$REAL_USER" "$FINAL_FILE"
            fi
            chmod 0644 "$FINAL_FILE"

            echo "Updated eGPU configuration saved in $FINAL_FILE"
            ;;
        3)
            echo "Regenerating scanner output now..."
            # regenerate using embedded advisor (no sudo)
            generate_memfile_inline || {
                echo "Embedded advisor failed. See messages above."
            }
            read -r -p "Done. Press Enter to return to menu..."
            continue
            ;;
        4)
            echo "Exiting..."
            break
            ;;
        *)
            echo "Invalid choice."
            read -r -p "Press Enter to return to menu..."
            continue
            ;;
    esac

    if [[ -s "$FINAL_FILE" ]] && grep -qE '^(GPU|AUDIO)_[0-9]+_value=' "$FINAL_FILE"; then
        source "$FINAL_FILE"

        # Build egpu_answers: one line per device (GPU then AUDIO), y or n
        egpu_answers=""
        i=1
        while true; do
            val_var="GPU_${i}_value"
            val="${!val_var:-}"
            [[ -z "$val" ]] && break
            egpu_answers+="${val:-n}"$'\n'
            ((i++))
        done

        j=1
        while true; do
            aval_var="AUDIO_${j}_value"
            aval="${!aval_var:-}"
            [[ -z "$aval" ]] && break
            egpu_answers+="${aval:-n}"$'\n'
            ((j++))
        done

        # Build internal_answers: 'y' for each internal device (those marked 'n')
        internal_answers=""
        i=1
        while true; do
            val_var="GPU_${i}_value"
            val="${!val_var:-}"
            [[ -z "$val" ]] && break
            if [[ "$val" == "n" ]]; then
                internal_answers+="y"$'\n'
            fi
            ((i++))
        done

        j=1
        while true; do
            aval_var="AUDIO_${j}_value"
            aval="${!aval_var:-}"
            [[ -z "$aval" ]] && break
            if [[ "$aval" == "n" ]]; then
                internal_answers+="y"$'\n'
            fi
            ((j++))
        done

        # Final three answers (one per line). Adjust if you want different defaults.
        finale_answers=$'n\ny\ny\n'

        echo
        echo "Summary of actions to apply:"
        egpu_count=$(printf '%s' "$egpu_answers" | sed '/^$/d' | wc -l)
        internal_count=$(printf '%s' "$internal_answers" | sed '/^$/d' | wc -l)
        echo " - eGPU answers (total lines): $egpu_count"
        echo " - internal answers (total lines): $internal_count"
        echo " - final answers: 3"
        echo

        if ! read_yesno "Confirm applying this configuration now? [y/N] "; then
            echo "Application cancelled by user. Returning to menu."
            read -r -p "Press Enter to return to menu..."
            continue
        fi

        echo "Applying answers to all-ways-egpu setup..."

        # Clean whitespace
        clean_egpu="$(printf '%s' "$egpu_answers" | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//')"
        clean_internal="$(printf '%s' "$internal_answers" | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//')"
        clean_finale="$(printf '%s' "$finale_answers" | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//')"

        # Build and pipe exact input to the setup command (no sudo: already root)
        {
            if ls "$CONF_DIR" 2>/dev/null | grep -qE "^(0|1|egpu-bus-ids|max-retry|user-bus-ids)$"; then
                printf 'y\n'
            fi

            printf '%s\n' "$clean_egpu"
            printf '%s\n' "$clean_internal"
            printf '%s\n' "$clean_finale"
        } | all-ways-egpu setup

        # Follow-up commands as root (no sudo)
        all-ways-egpu set-boot-vga egpu || true
        all-ways-egpu set-compositor-primary egpu || true

        sleep 3
        read -r -p "Configuration done. Press Enter to return to menu..."
    else
        echo "Final file missing or invalid. Not running setup."
        read -r -p "Press Enter to return to menu..."
        continue
    fi
done

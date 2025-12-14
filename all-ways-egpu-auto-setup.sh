#!/bin/bash
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$REAL_USER" | cut -d: -f6)"

MEM_FILE="$HOME_DIR/.gpu_all-ways-egpu_config"
FINAL_FILE="$HOME_DIR/.gpu_all-ways-egpu_final"
CONF_DIR="/usr/share/all-ways-egpu"

# Helper: read a yes/no answer, accept y/Y/1 as yes, empty or n/N as no
read_yesno() {
    local prompt="$1"
    local ans
    while true; do
        read -r -p "$prompt" ans
        case "$ans" in
            [yY]|1) return 0 ;;
            [nN]|'') return 1 ;;
            *) echo "Répondre par y (oui) ou n (non). Tape 1 est accepté comme oui." ;;
        esac
    done
}

if [[ ! -s "$MEM_FILE" ]]; then
    echo "Error: $MEM_FILE not found or empty. advisor-addon.sh must generate it."
    read -r -p "Done. Press Enter to return to menu..."
    exit 1
fi

# Regenerate memory file if script exists and is executable
if [[ -x "$HOME_DIR/RGB-GPUs-Teaming.OP/advisor-addon.sh" ]]; then
    sudo -u "$REAL_USER" "$HOME_DIR/RGB-GPUs-Teaming.OP/advisor-addon.sh"
fi

while true; do
    clear
    echo "===== Configuration Menu ====="
    echo "1) Use existing final memory"
    echo "2) Configure GPUs & Audio interactively (create/update)"
    echo "3) Exit"
    read -r -p "Enter choice [1/2/3]: " choice

    case "$choice" in
        1)
            if [[ ! -s "$FINAL_FILE" ]]; then
                echo "No final memory file found or it's empty. Please run configuration first."
                read -r -p "Press Enter to return to menu..."
                continue
            fi
            echo "Using existing final configuration from $FINAL_FILE"
            ;;
        2)
            echo "Configuring GPUs and Audio interactively..."
            # shellcheck disable=SC1090
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
                echo "No GPUs/Audio configured. Final file not created."
                rm -f "$FINAL_FILE"
                read -r -p "Press Enter to return to menu..."
                continue
            fi

            echo "Updated final configuration saved in $FINAL_FILE"
            ;;
        3)
            echo "Exiting..."
            break
            ;;
        *)
            echo "Invalid choice."
            read -r -p "Press Enter to return to menu..."
            continue
            ;;
    esac

    if [[ -s "$FINAL_FILE" ]] && grep -qE '^(GPU|AUDIO)_[0-9]_value=' "$FINAL_FILE"; then
        # shellcheck disable=SC1090
        source "$FINAL_FILE"

        # Build egpu_answers: one line per device (GPU then AUDIO), y or n
        egpu_answers=""
        i=1
        while true; do
            val_var="GPU_${i}_value"
            val="${!val_var:-}"
            [[ -z "$val" ]] && break
            if [[ "$val" == "y" ]]; then
                egpu_answers+="y"$'\n'
            else
                egpu_answers+="n"$'\n'
            fi
            ((i++))
        done

        j=1
        while true; do
            aval_var="AUDIO_${j}_value"
            aval="${!aval_var:-}"
            [[ -z "$aval" ]] && break
            if [[ "$aval" == "y" ]]; then
                egpu_answers+="y"$'\n'
            else
                egpu_answers+="n"$'\n'
            fi
            ((j++))
        done

        # Build internal_answers: only 'y' lines for internal devices (no 'n' lines)
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

        echo "=== DEBUG egpu_answers ==="
        printf '%s' "$egpu_answers"
        echo "=== DEBUG internal_answers ==="
        printf '%s' "$internal_answers"
        echo "=== DEBUG finale_answers ==="
        printf '%s' "$finale_answers"

        echo
        echo "Résumé des actions à appliquer :"
        # Count devices
        egpu_count=$(printf '%s' "$egpu_answers" | sed '/^$/d' | wc -l)
        internal_count=$(printf '%s' "$internal_answers" | sed '/^$/d' | wc -l)
        echo " - Réponses eGPU (total lines): $egpu_count"
        echo " - Réponses internes (total lines): $internal_count"
        echo " - Réponses finales: 3"
        echo
        echo "Affichage des blocs (vérifie l'alignement) :"
        echo ">>> eGPU answers <<<"
        printf '%s' "$egpu_answers"
        echo ">>> internal answers <<<"
        printf '%s' "$internal_answers"
        echo ">>> final answers <<<"
        printf '%s' "$finale_answers"
        echo

        if ! read_yesno "Confirmer l'application de cette configuration maintenant ? [y/N] "; then
            echo "Application annulée par l'utilisateur. Retour au menu."
            read -r -p "Press Enter to return to menu..."
            continue
        fi

        echo "Feeding answers into all-ways-egpu setup..."

        # Clean leading/trailing whitespace from blocks (defensive)
        clean_egpu="$(printf '%s' "$egpu_answers" | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//')"
        clean_internal="$(printf '%s' "$internal_answers" | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//')"
        clean_finale="$(printf '%s' "$finale_answers" | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//')"

        # Build and pipe exact input to the setup command (no heredoc indentation issues)
        {
            if ls "$CONF_DIR" | grep -qE "^(0|1|egpu-bus-ids|max-retry|user-bus-ids)$"; then
                # answer overwrite prompt
                printf 'y\n'
            fi

            # send egpu answers (preserve one line per device)
            printf '%s\n' "$clean_egpu"

            # send internal answers (only lines present)
            printf '%s\n' "$clean_internal"

            # send final three answers
            printf '%s\n' "$clean_finale"
        } | sudo all-ways-egpu setup

        sudo all-ways-egpu set-boot-vga egpu || true
        sudo all-ways-egpu set-compositor-primary egpu || true

        sleep 3
        read -r -p "Configuration done. Press Enter to return to menu..."
    else
        echo "Final file missing or invalid. Not running setup."
        read -r -p "Press Enter to return to menu..."
        continue
    fi
done

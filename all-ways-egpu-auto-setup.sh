#!/bin/bash

REAL_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$REAL_USER" | cut -d: -f6)"

MEM_FILE="$HOME_DIR/.gpu_all-ways-egpu_config"
FINAL_FILE="$HOME_DIR/.gpu_all-ways-egpu_final"
CONF_DIR="/usr/share/all-ways-egpu"

if [[ ! -s "$MEM_FILE" ]]; then
    echo "Error: $MEM_FILE not found or empty. advisor-addon.sh must generate it."
    read -p "Done. Press Enter to return to menu..."
    exit 1
fi

sudo -u "$REAL_USER" $HOME_DIR/RGB-GPUs-Teaming.OP/advisor-addon.sh

while true; do
    clear
    echo "===== Configuration Menu ====="
    echo "1) Use existing final memory"
    echo "2) Configure GPUs & Audio interactively (create/update)"
    echo "3) Exit"
    read -p "Enter choice [1/2/3]: " choice

    case "$choice" in
        1)
            if [[ ! -s "$FINAL_FILE" ]]; then
                echo "No final memory file found or it's empty. Please run configuration first."
                read -p "Press Enter to return to menu..."
                continue
            fi
            echo "Using existing final configuration from $FINAL_FILE"
            ;;
        2)
            echo "Configuring GPUs and Audio interactively..."
            source "$MEM_FILE"
            : > "$FINAL_FILE"

            # --- GPUs ---
            i=1
            while true; do
                eval name=\$GPU_${i}_name
                [[ -z "$name" ]] && break

                echo "GPU_$i: $name"
                read -p "Is this the eGPU? [y/N] " answer

                if [[ "$answer" =~ ^[yY]$ ]]; then
                    echo "GPU_${i}_name=\"$name\"" >> "$FINAL_FILE"
                    echo "GPU_${i}_value=\"y\"" >> "$FINAL_FILE"
                else
                    echo "GPU_${i}_name=\"$name\"" >> "$FINAL_FILE"
                    echo "GPU_${i}_value=\"n\"" >> "$FINAL_FILE"
                fi
                echo >> "$FINAL_FILE"
                ((i++))
            done

            # --- Audio devices ---
            j=1
            while true; do
                eval aname=\$AUDIO_${j}_name
                [[ -z "$aname" ]] && break

                echo "AUDIO_$j: $aname"
                read -p "Is this the eGPU audio device? [y/N] " ans

                if [[ "$ans" =~ ^[yY]$ ]]; then
                    echo "AUDIO_${j}_name=\"$aname\"" >> "$FINAL_FILE"
                    echo "AUDIO_${j}_value=\"y\"" >> "$FINAL_FILE"
                else
                    echo "AUDIO_${j}_name=\"$aname\"" >> "$FINAL_FILE"
                    echo "AUDIO_${j}_value=\"n\"" >> "$FINAL_FILE"
                fi
                echo >> "$FINAL_FILE"
                ((j++))
            done

            if [[ ! -s "$FINAL_FILE" ]]; then
                echo "No GPUs/Audio configured. Final file not created."
                rm -f "$FINAL_FILE"
                read -p "Press Enter to return to menu..."
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
            read -p "Press Enter to return to menu..."
            continue
            ;;
    esac

    if [[ -s "$FINAL_FILE" ]] && grep -qE '^(GPU|AUDIO)_[0-9]_value=' "$FINAL_FILE"; then
        source "$FINAL_FILE"

        egpu_answers=""
        i=1
        while true; do
            eval val=\$GPU_${i}_value
            [[ -z "${val:-}" ]] && break
            [[ "$val" == "y" ]] && egpu_answers+="y"$'\n' || egpu_answers+="n"$'\n'
            ((i++))
        done

        j=1
        while true; do
            eval aval=\$AUDIO_${j}_value
            [[ -z "${aval:-}" ]] && break
            [[ "$aval" == "y" ]] && egpu_answers+="y"$'\n' || egpu_answers+="n"$'\n'
            ((j++))
        done

	internal_answers=""
	i=1
	while true; do
	    eval val=\$GPU_${i}_value
	    [[ -z "${val:-}" ]] && break
	    if [[ "$val" == "n" ]]; then
	        internal_answers+="y"$'\n'
	    fi
	    ((i++))
	done

	j=1
	while true; do
	    eval aval=\$AUDIO_${j}_value
	    [[ -z "${aval:-}" ]] && break
	    if [[ "$aval" == "n" ]]; then
	        internal_answers+="y"$'\n'
	    fi
	    ((j++))
	done

        #echo "=== DEBUG egpu_answers ==="
        #printf '%s\n' "$egpu_answers"
        #echo "=== DEBUG internal_answers ==="
        #printf '%s\n' "$internal_answers"

        echo "Feeding answers into all-ways-egpu setup..."

    if ls "$CONF_DIR" | grep -qE "^(0|1|egpu-bus-ids|max-retry|user-bus-ids)$"; then
            echo "Existing all-ways-egpu configuration detected: skipping overwrite"
            sudo all-ways-egpu setup <<EOF
	y
	$egpu_answers $internal_answers
	n
	y
	y
	EOF
        else
            echo "No existing all-ways-egpu configuration detected: sending overwrite confirmation"
            sudo all-ways-egpu setup <<EOF
	$egpu_answers $internal_answers
	n
	y
	y
	EOF
        fi

        sudo all-ways-egpu set-boot-vga egpu
        sudo all-ways-egpu set-compositor-primary egpu

        sleep 3
        read -p "Configuration done. Press Enter to return to menu..."
    else
        echo "Final file missing or invalid. Not running setup."
        read -p "Press Enter to return to menu..."
        continue
    fi
done

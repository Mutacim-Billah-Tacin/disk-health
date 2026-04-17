#!/bin/bash

# --- 0. Color Definitions ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- 1. Automatic Dependency Installation ---
install_smartmontools() {
    if [ -f /etc/debian_version ]; then
        sudo apt-get update && sudo apt-get install -y smartmontools
    elif [ -f /etc/arch-release ]; then
        # Using pacman for your Arch-based setup
        sudo pacman -Sy --noconfirm smartmontools
    elif [ -f /etc/fedora-release ]; then
        sudo dnf install -y smartmontools
    else
        echo -e "${RED}Error: Package manager not supported. Install smartmontools manually.${NC}"
        exit 1
    fi
}
if ! command -v smartctl &> /dev/null; then install_smartmontools; fi

# --- 2. Root Check ---
[[ "$EUID" -ne 0 ]] && exec sudo "$0" "$@"

# --- 3. Drive Selection ---
# Check if a drive was passed as an argument
if [ -n "$1" ] && [ -b "$1" ]; then
    DRIVE="$1"
else
    echo -e "\n--- [ Select a Drive to Check ] ---"
    # Filtering loop and zram devices
    mapfile -t DRIVES < <(lsblk -dno NAME,SIZE,MODEL | grep -vE "loop|zram")
    for i in "${!DRIVES[@]}"; do 
        echo -e "[$i] /dev/${DRIVES[$i]}"
    done
    echo -ne "\nEnter number: "
    read -r CHOICE
    
    # Validation for user input
    if [[ ! "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -ge "${#DRIVES[@]}" ]; then
        echo -e "${RED}Invalid selection.${NC}"
        exit 1
    fi
    
    PICKED_DRIVE=$(echo "${DRIVES[$CHOICE]}" | awk '{print $1}')
    DRIVE="/dev/$PICKED_DRIVE"
fi

# --- 4. Data Collection ---
STATUS=$(smartctl -H "$DRIVE" | grep -iE "test result|overall-health" | awk -F': ' '{print $2}' | xargs)
TEMP=$(smartctl -A "$DRIVE" | grep -iE "Temperature" | awk '{print $10}' | head -n 1)
# ID 5 = Reallocated Sectors, 197 = Pending, 198 = Uncorrectable
CRITICAL=$(smartctl -A "$DRIVE" | grep -E "^\s*(5|197|198) " | awk '{sum+=$10} END {print sum+0}')
# ID 1 = Raw Read Error Rate
READ_ERRS=$(smartctl -A "$DRIVE" | grep -E "^\s*(1) " | awk '{print $10}')

# --- 5. Summary Verdict ---
echo -e "\n===================================="
echo -e "       DRIVE HEALTH SUMMARY"
echo -e "===================================="
echo -e "Device:      $DRIVE"
[[ -n "$TEMP" ]] && echo -e "Temperature: $TEMP°C"

# Overall Status Verdict
if [[ "$STATUS" == "PASSED" || "$STATUS" == "OK" ]]; then
    echo -e "Condition:   ${GREEN}HEALTHY${NC}"
else
    echo -e "Condition:   ${RED}CRITICAL (Dying)${NC}"
    VERDICT="⚠️  This drive is failing. Copy your files to another disk immediately!"
fi

# Bad Sector Verdict
if [ "$CRITICAL" -gt 0 ]; then
    echo -e "Surface:     ${RED}$CRITICAL Bad Sectors Found${NC}"
    VERDICT="⚠️  The disk surface is damaged. Data loss is likely."
else
    echo -e "Surface:     ${GREEN}Perfect (No bad sectors)${NC}"
fi

# Read Error Verdict
if [ -n "$READ_ERRS" ] && [ "$READ_ERRS" -gt 10000 ]; then 
    echo -e "Performance: ${YELLOW}Noticeable Scars ($READ_ERRS errors)${NC}"
    [[ -z "$VERDICT" ]] && VERDICT="ℹ️  Drive has historical read errors but is currently stable."
elif [ -n "$READ_ERRS" ] && [ "$READ_ERRS" -gt 0 ]; then
    echo -e "Performance: ${GREEN}Minor Wear ($READ_ERRS errors)${NC}"
fi

# Final Recommendation
echo -e "\n[ RECOMMENDATION ]"
if [ -z "$VERDICT" ]; then
    echo -e "${GREEN}✅ Everything looks great. This drive is safe to use!${NC}"
else
    echo -e "$VERDICT"
fi
echo -e "====================================\n"

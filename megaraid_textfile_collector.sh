#!/bin/bash
# =============================================================================
# MegaRAID SMART Textfile Collector for prox-sbnd
# Writes Prometheus metrics to /var/lib/node_exporter/textfile_collector/
# Picked up automatically by node_exporter at port 9100
#
# Drives: 8x HGST HUS724020ALA640, Slots 0-7, DiskGroup 0
# Controller device: /dev/bus/0
#
# Run via cron every 5 minutes:
#   */5 * * * * root /usr/local/bin/megaraid_textfile_collector.sh
# =============================================================================

OUTFILE="/var/lib/node_exporter/textfile_collector/megaraid.prom"
TMPFILE="${OUTFILE}.tmp"
DEVICE="/dev/bus/0"      # your controller device
SLOTS=(0 1 2 3 4 5 6 7)  # adjust to match your slot count
ENCLOSURE=252             # find yours: megacli -PDList -aAll | grep "Enclosure Device ID" | head -1

# Write to tmp first, then atomic move to avoid node_exporter reading partial file
cat > "$TMPFILE" << 'HEADER'
# HELP megaraid_smart_healthy SMART overall health (1=healthy, 0=failed)
# TYPE megaraid_smart_healthy gauge
# HELP megaraid_reallocated_sectors Number of reallocated sectors
# TYPE megaraid_reallocated_sectors gauge
# HELP megaraid_reallocated_events Number of reallocated sector events
# TYPE megaraid_reallocated_events gauge
# HELP megaraid_current_pending_sectors Number of unstable sectors pending reallocation
# TYPE megaraid_current_pending_sectors gauge
# HELP megaraid_offline_uncorrectable Number of uncorrectable offline sectors
# TYPE megaraid_offline_uncorrectable gauge
# HELP megaraid_spin_retry_count Number of spin retry attempts
# TYPE megaraid_spin_retry_count gauge
# HELP megaraid_temperature_celsius Drive temperature in Celsius
# TYPE megaraid_temperature_celsius gauge
# HELP megaraid_media_errors MegaRAID controller media error count for drive
# TYPE megaraid_media_errors gauge
# HELP megaraid_other_errors MegaRAID controller other error count for drive
# TYPE megaraid_other_errors gauge
# HELP megaraid_predictive_failures MegaRAID controller predictive failure count
# TYPE megaraid_predictive_failures gauge
# HELP megaraid_firmware_state Drive firmware state (1=online, 0=not online)
# TYPE megaraid_firmware_state gauge
# HELP megaraid_collector_success Whether the collector ran successfully (1=ok, 0=error)
# TYPE megaraid_collector_success gauge
HEADER

COLLECTOR_SUCCESS=1

for SLOT in "${SLOTS[@]}"; do

    # --- MegaCLI data ---
    MEGACLI_OUT=$(megacli -PDInfo -PhysDrv "[$ENCLOSURE:$SLOT]" -aAll 2>/dev/null)

    if [ -z "$MEGACLI_OUT" ]; then
        echo "megaraid_collector_success{slot=\"$SLOT\"} 0" >> "$TMPFILE"
        COLLECTOR_SUCCESS=0
        continue
    fi

    MEDIA_ERRORS=$(echo "$MEGACLI_OUT" | grep "Media Error Count" | awk '{print $NF}')
    OTHER_ERRORS=$(echo "$MEGACLI_OUT" | grep "Other Error Count" | awk '{print $NF}')
    PREDICTIVE=$(echo "$MEGACLI_OUT" | grep "Predictive Failure Count" | awk '{print $NF}')
    FW_STATE=$(echo "$MEGACLI_OUT" | grep -c "Online, Spun Up")

    # --- SMART data via smartctl ---
    SMART_OUT=$(smartctl -a -d sat+megaraid,$SLOT $DEVICE 2>/dev/null)

    if [ -z "$SMART_OUT" ]; then
        echo "megaraid_collector_success{slot=\"$SLOT\"} 0" >> "$TMPFILE"
        COLLECTOR_SUCCESS=0
        continue
    fi

    # SMART overall health: PASSED=1, anything else=0
    SMART_HEALTH=$(echo "$SMART_OUT" | grep "SMART overall-health" | grep -c "PASSED")

    REALLOCATED=$(echo "$SMART_OUT" | awk '/Reallocated_Sector_Ct/{print $NF}')
    REALLOC_EVENTS=$(echo "$SMART_OUT" | awk '/Reallocated_Event_Count/{print $NF}')
    PENDING=$(echo "$SMART_OUT" | awk '/Current_Pending_Sector/{print $NF}')
    UNCORRECTABLE=$(echo "$SMART_OUT" | awk '/Offline_Uncorrectable/{print $NF}')
    SPIN_RETRY=$(echo "$SMART_OUT" | awk '/Spin_Retry_Count/{print $NF}')
    # Temperature line format: "194 Temperature_Celsius ... - 35 (Min/Max ...)"
    TEMP=$(echo "$SMART_OUT" | awk '/Temperature_Celsius/{print $10}')

    # Write metrics with slot label
    cat >> "$TMPFILE" << EOF
megaraid_smart_healthy{slot="$SLOT"} ${SMART_HEALTH:-0}
megaraid_reallocated_sectors{slot="$SLOT"} ${REALLOCATED:-0}
megaraid_reallocated_events{slot="$SLOT"} ${REALLOC_EVENTS:-0}
megaraid_current_pending_sectors{slot="$SLOT"} ${PENDING:-0}
megaraid_offline_uncorrectable{slot="$SLOT"} ${UNCORRECTABLE:-0}
megaraid_spin_retry_count{slot="$SLOT"} ${SPIN_RETRY:-0}
megaraid_temperature_celsius{slot="$SLOT"} ${TEMP:-0}
megaraid_media_errors{slot="$SLOT"} ${MEDIA_ERRORS:-0}
megaraid_other_errors{slot="$SLOT"} ${OTHER_ERRORS:-0}
megaraid_predictive_failures{slot="$SLOT"} ${PREDICTIVE:-0}
megaraid_firmware_state{slot="$SLOT"} ${FW_STATE:-0}
EOF

done

# Overall collector health
echo "megaraid_collector_success $COLLECTOR_SUCCESS" >> "$TMPFILE"

# Atomic move so node_exporter never reads a partial file
mv "$TMPFILE" "$OUTFILE"

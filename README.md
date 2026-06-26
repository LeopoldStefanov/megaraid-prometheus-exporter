# MegaRAID Prometheus Exporter

A lightweight Prometheus textfile collector for physical drives behind a MegaRAID (LSI/Broadcom) RAID controller. Exposes per-slot SMART data and controller health metrics that `smartctl_exporter` cannot access.

---

## The Problem

`smartctl_exporter` auto-discovers standard Linux block devices (`/dev/sda`, `/dev/sdb`, etc.) and queries their SMART data directly. However, when drives are managed by a hardware RAID controller, Linux only sees the logical RAID device — the individual physical disks are hidden behind the controller.

```
Without this exporter:
  Linux sees: /dev/sda (logical RAID volume)
  smartctl_exporter: ✅ sees /dev/sda, ❌ cannot see 8 physical drives behind it

With this exporter:
  megacli queries controller firmware per slot: ✅ slot 0, slot 1 ... slot N
  smartctl -d sat+megaraid,N queries each drive directly: ✅ full SMART data
```

---

## How It Works

The script runs as a cron job every 5 minutes. It:

1. Uses `megacli` to query the controller for each physical drive slot — firmware state, media errors, predictive failures
2. Uses `smartctl -d sat+megaraid,N` to query SMART attributes directly from each drive
3. Writes all metrics in Prometheus text format to a `.prom` file
4. `node_exporter` reads that file via its `--collector.textfile.directory` flag and serves the metrics at port 9100

```
megaraid_textfile_collector.sh (cron, every 5 min)
        │
        ▼
/var/lib/node_exporter/textfile_collector/megaraid.prom
        │
        ▼  (node_exporter reads on every scrape)
Prometheus ──► Grafana ──► Alerts
```

The `.prom` file is completely overwritten on every run — it never grows. It is a current-state snapshot only.

---

## Metrics Exposed

| Metric | Type | Description |
|--------|------|-------------|
| `megaraid_smart_healthy` | gauge | SMART overall health (1=healthy, 0=failed) |
| `megaraid_reallocated_sectors` | gauge | Number of reallocated sectors |
| `megaraid_reallocated_events` | gauge | Number of reallocated sector events |
| `megaraid_current_pending_sectors` | gauge | Unstable sectors pending reallocation |
| `megaraid_offline_uncorrectable` | gauge | Uncorrectable offline sectors |
| `megaraid_spin_retry_count` | gauge | Spin retry attempts |
| `megaraid_temperature_celsius` | gauge | Drive temperature in °C |
| `megaraid_media_errors` | gauge | Controller-reported media error count |
| `megaraid_other_errors` | gauge | Controller-reported other error count |
| `megaraid_predictive_failures` | gauge | Controller-reported predictive failures |
| `megaraid_firmware_state` | gauge | Drive online state (1=online, 0=offline) |
| `megaraid_collector_success` | gauge | Whether the collector ran successfully |

All metrics include a `slot` label (e.g. `slot="0"`) identifying the physical drive slot.

---

## Requirements

- `megacli` installed on the host (`apt install megacli` or from Broadcom)
- `smartmontools` installed (`apt install smartmontools`)
- `node_exporter` running with `--collector.textfile.directory` flag
- Root access (required for megacli and smartctl)

---

## Installation

### 1. Find your enclosure ID

MegaRAID controllers use an enclosure ID that varies by system. Find yours:

```bash
megacli -PDList -aAll | grep "Enclosure Device ID" | head -1
```

Note the ID — you'll need it in the next step.

### 2. Deploy the script

```bash
# Copy script to the host
cp megaraid_textfile_collector.sh /usr/local/bin/
chmod +x /usr/local/bin/megaraid_textfile_collector.sh
```

### 3. Configure the script

Edit the script and set your values:

```bash
DEVICE="/dev/bus/0"           # your controller device
SLOTS=(0 1 2 3 4 5 6 7)      # your slot numbers
ENCLOSURE=252                 # your enclosure ID from step 1
```

### 4. Create the textfile collector directory

```bash
mkdir -p /var/lib/node_exporter/textfile_collector
```

### 5. Configure node_exporter

Add the textfile collector flag to your node_exporter service:

```ini
ExecStart=/usr/local/bin/node_exporter \
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector \
  --web.listen-address=:9100
```

Then reload:

```bash
systemctl daemon-reload && systemctl restart node_exporter
```

### 6. Run once to verify

```bash
/usr/local/bin/megaraid_textfile_collector.sh
cat /var/lib/node_exporter/textfile_collector/megaraid.prom
```

You should see metrics for each slot. Verify node_exporter is serving them:

```bash
curl http://localhost:9100/metrics | grep megaraid
```

### 7. Set up cron

```bash
echo "*/5 * * * * root /usr/local/bin/megaraid_textfile_collector.sh" > /etc/cron.d/megaraid-collector
```

---

## Example Grafana Alert Rules

```yaml
# Alert when any drive goes offline
- uid: "megaraid_drive_offline"
  title: "MegaRAID - Drive Offline"
  for: "1m"
  labels:
    severity: critical
  data:
    - refId: "A"
      model:
        expr: 'megaraid_firmware_state == 0'
  condition: "A"

# Alert on reallocated sectors (early degradation warning)
- uid: "megaraid_reallocated_sectors"
  title: "MegaRAID - Reallocated Sectors Detected"
  for: "5m"
  labels:
    severity: warning
  data:
    - refId: "A"
      model:
        expr: 'megaraid_reallocated_sectors > 0'
  condition: "A"

# Alert if collector stops working
- uid: "megaraid_collector_down"
  title: "MegaRAID - Collector Script Failed"
  for: "10m"
  labels:
    severity: warning
  data:
    - refId: "A"
      model:
        expr: 'megaraid_collector_success == 0'
  condition: "A"
```

---

## Troubleshooting

**Metrics file is empty or missing:**
Run the script manually and check for errors:
```bash
bash -x /usr/local/bin/megaraid_textfile_collector.sh
```

**firmware_state shows 0 for all drives despite drives being online:**
Check the exact output of megacli on your system:
```bash
megacli -PDInfo -PhysDrv "[ENCLOSURE:0]" -aAll | grep -i "firmware\|state\|online"
```
The grep pattern in the script may need adjusting for your firmware version.

**megacli reports "Device not found":**
Your enclosure ID is likely wrong. Re-run step 1 of the installation.

**node_exporter not serving megaraid metrics:**
Confirm the textfile directory flag is set and the .prom file exists:
```bash
ls -la /var/lib/node_exporter/textfile_collector/
systemctl cat node_exporter | grep textfile
```

---

## Tested On

- MegaRAID SAS controller (Broadcom/LSI)
- Proxmox VE 8.x (Debian Bookworm)
- node_exporter 1.7+
- megacli 8.07.14

---

## Related

- [proxmox-monitoring-stack](https://github.com/YOUR_USERNAME/proxmox-monitoring-stack) — full Proxmox monitoring setup this exporter is part of

---

## Author

Leopold Stefanov

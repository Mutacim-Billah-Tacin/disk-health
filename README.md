# 🛠️ Disk Health Monitor (disk.sh)

A lightweight Bash utility to quickly assess the physical health of your drives using SMART data. This script is designed for users who want a "human-readable" verdict on their hardware status without sifting through complex technical tables.

## ✨ Features
- **Automatic Dependency Check**: Detects and installs `smartmontools` on Arch, Debian/Ubuntu, and Fedora-based systems.
- **Smart Drive Selection**: Lists physical drives (SSD/HDD) while filtering out noise like loop devices and zram.
- **Human-Readable Verdicts**:
    - **Healthy**: Drive is operating within normal parameters.
    - **Critical**: Drive is failing (SMART status "FAILED").
    - **Surface Check**: Monitors reallocated, pending, and uncorrectable sectors.
    - **Performance Scars**: Tracks historical read errors with a custom threshold (10,000 errors) to distinguish between aging drives and immediate failures.
- **Color-Coded Output**: Instant visual feedback on drive condition.
- **Non-Interactive Mode**: Pass a device path as an argument for automated scripts.

## 🚀 Installation & Usage
1. **Clone the repository**:
   ```bash
   git clone https://github.com/Mutacim-Billah-Tacin/disk-health.git
   cd disk-health
   ```

2. **Make the script executable**:
    ```bash
    chmod +x disk.sh
    ```

4. **Run the script**:
   ```bash
    ./disk.sh
   ```
   
   You’ll see a list of drives like:
   ```shell
    [0] /dev/sda
    [1] /dev/sdb
   ```
  
## 📊 What it checks
   | Metric        | Description                           |
| ------------- | ------------------------------------- |
| Health Status | SMART overall test result             |
| Temperature   | Current drive temp                    |
| Bad Sectors   | Reallocated + Pending + Uncorrectable |
| Read Errors   | Raw read error rate                   |

## 🧾 Output Example
```shell
====================================
       DRIVE HEALTH SUMMARY
====================================
Device:      /dev/sda
Temperature: 35°C
Condition:   HEALTHY
Surface:     Perfect (No bad sectors)
Performance: Minor Wear (12 errors)

[ RECOMMENDATION ]
✅ Everything looks great. This drive is safe to use!
====================================
```

## ⚠️ Warnings Explained
- CRITICAL (Dying) → Backup immediately
- Bad Sectors Found → Disk surface damage, risk of data loss
- High Read Errors → Drive aging, monitor closely

## ⚖️ License
This project is open-source. Feel free to modify and adapt it for your own workflow.

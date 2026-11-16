#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
#
# Script Purpose and Overview:
# This script configures Raspberry Pi OS Lite (64-bit, kernel 6.6, Debian 12 Bookworm) for high performance on
# Raspberry Pi 5 hardware. It optimizes memory management by disabling the default swap mechanism and installing
# ZRAM for in-memory compression. Key kernel parameters are tuned to enhance performance under memory pressure, 
# and the MG-LRU (Multi-Gen LRU) feature is enabled for more efficient page reclaiming, as recommended by the 
# Linux kernel documentation.

# Key Features and Optimizations:
# 1. Disable Default Swap:
#    - Turns off the default swap file both during runtime and boot to eliminate performance overhead from disk-based swapping.
#    - Removes any existing swap file to free up disk space.

# 2. Install and Configure ZRAM:
#    - Installs `zram-tools` to create a compressed in-memory swap, improving memory efficiency.
#    - Dynamically configures ZRAM based on available RAM (32% for 16GB, 50% for 8GB, 75% for 4GB, 100% for 2GB models) to match the system's resources.
#    - Utilizes fast LZ4 compression for optimal performance.

# 3. Adjust Kernel Swap and Memory Parameters:
#    - Applies custom kernel parameters in `/etc/sysctl.conf` to fine-tune memory handling and reduce disk I/O.
#    - Prioritizes in-memory operations to improve performance during heavy loads.

# 4. Enable MG-LRU (Multi-Gen LRU):
#    - Enables Multi-Gen LRU, which enhances the system's efficiency in reclaiming memory.
#    - Improves overall responsiveness and reduces performance drops during memory pressure, following best practices from the Linux kernel documentation.

# Disable Trixie's default swap manager before zram-tools takes ownership.
install -d -m 0755 /etc/rpi/swap.conf.d
cat >/etc/rpi/swap.conf.d/90-billspi.conf <<'EOF'
[Main]
Mechanism=none
EOF

# Stop writeback, then release zram0 and its backing loop before removing the file.
systemctl stop rpi-zram-writeback.timer rpi-zram-writeback.service
systemctl stop dev-zram0.swap systemd-zram-setup@zram0.service
systemctl stop rpi-setup-loop@var-swap.service rpi-resize-swap-file.service
rm -f /run/systemd/zram-generator.conf.d/20-rpi-swap-zram0-ctrl.conf
systemctl daemon-reload

# Remove the default swap backing file after its loop device has been released.
rm -f /var/swap


# Install zram-tools
apt-get update
apt-get install -y zram-tools

# Allow transient zram references to drain during normal module removal.
install -d -m 0755 /etc/modprobe.d
cat >/etc/modprobe.d/billspi-zram-removal.conf <<'EOF'
remove zram /usr/sbin/modprobe --ignore-remove --remove --wait=5000 zram
EOF
chmod 0644 /etc/modprobe.d/billspi-zram-removal.conf

# Get the total memory size in KB
TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)

# Determine PERCENT based on total RAM (in KB)
if [ $TOTAL_MEM_KB -ge 15000000 ]; then
    # 16GB RAM model
    PERCENT=32  
elif [ $TOTAL_MEM_KB -ge 7500000 ]; then
    # 8GB RAM model
    PERCENT=50
elif [ $TOTAL_MEM_KB -ge 3500000 ]; then
    # 4GB RAM model
    PERCENT=75
else
    # 2GB RAM model
    PERCENT=100
fi

# Get the number of CPU cores
CORES=$(nproc)

# Create a new /etc/default/zramswap file with the desired configuration
tee /etc/default/zramswap > /dev/null <<EOL
PERCENT=$PERCENT
CORES=$CORES
PRIORITY=100
ALGO=lz4
EOL

# Ensure zramswap starts on boot (idempotent)
systemctl enable zramswap.service >/dev/null || true

# Apply the updated /etc/default/zramswap settings immediately
# systemctl restart zramswap.service
if systemctl list-unit-files | grep -E '^zramswap\.service[[:space:]]' >/dev/null; then
  systemctl restart zramswap.service || true
else
  echo "zramswap.service not installed; skipping restart" >&2
fi

# Verify ZRAM service is running
systemctl is-active --quiet zramswap.service || echo "zramswap not active!" >&2
# Verify a ZRAM device is actually enabled as swap
grep -q '^/dev/zram' /proc/swaps || echo "No zram swap found!" >&2
zramctl; swapon --show

# Display the applied settings
ALG=$(sed -E 's/.*\[(.+)\].*/\1/' /sys/block/zram0/comp_algorithm 2>/dev/null || echo "lz4")
echo "ZRAM configuration applied: PERCENT=$PERCENT, CORES=$CORES, ALGO=$ALG"


# 1) Persisted kernel VM tunables via sysctl.d (modern + safe)
SYSCTL_D='/etc/sysctl.d/99-billspi-memory.conf'
install -D -m 0644 /dev/null "$SYSCTL_D"
cat >"$SYSCTL_D" <<'EOL'
vm.vfs_cache_pressure=500
vm.swappiness=100
vm.dirty_background_ratio=1
vm.dirty_ratio=50
vm.watermark_boost_factor=0
vm.watermark_scale_factor=125
vm.page-cluster=0
EOL

# Apply just our file now (quiet; ignore unknown keys)
sysctl -e -p "$SYSCTL_D" >/dev/null || true
# At boot, systemd-sysctl will re-apply everything in /etc/sysctl.d/*.conf.

# 2) Enable Multi-Gen LRU *now* (no reboot needed) and keep it across boots
if [[ -w /sys/kernel/mm/lru_gen/enabled ]]; then
    echo 7 > /sys/kernel/mm/lru_gen/enabled || true   # 1=enable, 2=debug, 4=mm_walk -> 7 enables all
    if [[ -w /sys/kernel/mm/lru_gen/min_ttl_ms ]]; then
        echo 1000 > /sys/kernel/mm/lru_gen/min_ttl_ms || true
    fi
else
    echo "MGLRU sysfs not present; kernel may not support it or it's compiled off." >&2
fi

# Persist MGLRU via systemd-tmpfiles (applies at each boot)
TMPFILES='/etc/tmpfiles.d/billspi-mglru.conf'
install -D -m 0644 /dev/null "$TMPFILES"
cat >"$TMPFILES" <<'EOL'
w /sys/kernel/mm/lru_gen/enabled    - - - - 7
w /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 1000
EOL

# Apply tmpfiles rules immediately (idempotent)
systemd-tmpfiles --create "$TMPFILES" || true

# Optional visibility
logger -t billspi "MGLRU enabled at runtime; persistence configured via tmpfiles."

touch /run/billspi/reboot-required
exit 0

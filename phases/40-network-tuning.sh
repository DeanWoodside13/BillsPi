#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

# Script Purpose and Overview:
# Optimizes Raspberry Pi OS Lite (64-bit, Bookworm) on Raspberry Pi 5 for headless, high-concurrency/server workloads:
# - File descriptor limits
# - TCP/IP & kernel networking tunings (BBR, buffers, backlog, ports, SACK on, MTU probing, UDP floors, default_qdisc=fq)
# - Ethernet offloads/queues/EEE via systemd oneshot (auto-picks fastest interface; tuned for RTL8156BG 2.5GbE)
# - Jumbo frames (OPT-IN via /etc/default/network_optimize); txqueuelen bump
# - IRQ balance & dnsmasq
# - PF_RING install & enable at boot
# - udev hooks: re-run tuning on NIC link-up + disable USB autosuspend for RTL8156/8156B/8156BG
#
# Assumptions:
# - This script runs ONCE during installation.
# - A REBOOT will occur after it completes.
# =============================================================================
# Customization quick knobs (what you can tune & where)
# =============================================================================
# MTU (Jumbo frames)  -> /etc/default/network_optimize
#   JUMBO_MTU=0|1     # default 0 (off). Set 1 to enable.
#   JUMBO_MTU_VALUE=9000
#
# RX interrupt coalescing (latency vs CPU) -> /usr/local/bin/network_optimize.sh
#   ethtool -C "$IFACE" rx-usecs 0|100     # default: 0 for <= 1G, 100 for >= 2.5G
#
# Flow control (pause frames) -> /usr/local/bin/network_optimize.sh
#   ethtool -A "$IFACE" rx on tx on        # change to 'tx off' if pause causes issues
#
# Offloads -> /usr/local/bin/network_optimize.sh
#   ethtool -K "$IFACE" gso on tso on gro on   # toggle as needed per NIC/driver
#
# RPS/RFS/XPS (multi-core scaling) -> /usr/local/bin/network_optimize.sh
#   rps_sock_flow_entries=32768
#   per-queue rps_flow_cnt=4096
#   CPU mask auto-derived from nproc (edit HEXMASK to pin specific CPUs)
#
# TX queue length (egress burst tolerance) -> /usr/local/bin/network_optimize.sh
#   ip link set "$IFACE" txqueuelen 4096
#
# Default qdisc & pacing -> /etc/sysctl.conf + /usr/local/bin/network_optimize.sh
#   net.core.default_qdisc=fq
#   tc qdisc replace dev "$IFACE" root fq   # switch to fq_codel if you prefer AQM
#
# TCP congestion control & related sysctls -> /etc/sysctl.conf
#   net.ipv4.tcp_congestion_control=bbr
#   net.core.netdev_max_backlog=10000
#   net.core.somaxconn=4096
#   net.ipv4.tcp_max_syn_backlog=4096
#   net.ipv4.tcp_sack=1
#   net.ipv4.tcp_mtu_probing=1
#
# File descriptor limits -> /etc/security/limits.conf
#   nofile soft/hard (defaults: 100000/100000)
#
# dnsmasq (local DNS cache) -> install block in script
#   Comment out or 'systemctl disable dnsmasq' if you already run another DNS.
#
# PF_RING -> repo/install block in script
#   Installs if available for bookworm_pi arm64; safe to remove if not needed.
#
# EEE (Energy Efficient Ethernet) -> /usr/local/bin/network_optimize.sh
#   ethtool --set-eee "$IFACE" eee off     # set 'on' to allow power-save
#
# Interface selection -> /usr/local/bin/network_optimize.sh
#   Auto-picks fastest UP NIC each boot/link-up; to pin, set IFACE=eth0 and
#   comment out the pick_iface() call.
#
# Optional IPv6 disable (OPT-IN via DISABLE_IPV6_FLAG in this script)
#   * Adds 'ipv6.disable=1' to /boot/firmware/cmdline.txt
#     so the KERNEL disables IPv6 on next boot (persistent).
#   * Installs /etc/sysctl.d/99-disable-ipv6.conf to disable IPv6 at runtime
#     and on future boots (sysctl safeguard).
#   * Requires a REBOOT to fully enforce the kernel flag; remains off until reverted.
#
# System-wide limits / ulimits
#   * Kernel-wide ceiling set elsewhere: fs.file-max=410000 (assumed present).
#   * Login shells (PAM): /etc/security/limits.conf includes nproc 65535/65535.
#     (nofile 100000/100000 is set earlier in this script.)
#   * Systemd-managed services (all services by default):
#       /etc/systemd/system.conf.d/90-rpi5-limits.conf
#       DefaultLimitNOFILE=100000
#       DefaultLimitNPROC=65535
#     Services pick these up on restart or after a reboot.
#
# TCP FIN timeout
#   * net.ipv4.tcp_fin_timeout=15 by default to free sockets faster for short-lived
#     connections (web/API/gRPC). For high-latency links with sporadic half-closes,
#     consider 20-30.
# =============================================================================

### FILE DESCRIPTOR LIMITS (keep limits.conf; no limits.d)
SOFT_LIMIT=100000
HARD_LIMIT=100000

# ========= Toggle(s) =========
# Set to 1 to disable IPv6; set to 0 to leave IPv6 as-is (no changes applied)
DISABLE_IPV6_FLAG=0

echo "Updating /etc/security/limits.conf for file descriptor limits..."
tee -a /etc/security/limits.conf >/dev/null <<EOF
# BEGIN rpi5 nofile
* soft nofile ${SOFT_LIMIT}
* hard nofile ${HARD_LIMIT}
# END rpi5 nofile
EOF

### CONSOLIDATED KERNEL & NETWORK TUNING (single sysctl.conf block)
echo "Appending consolidated sysctl tunings..."
tee -a /etc/sysctl.d/99-billspi-network.conf >/dev/null <<'EOF'
##### BEGIN rpi5 tuning #####
# File descriptors (system-wide)
fs.file-max = 410000

# Queue sizes and backlogs
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 10000        # bump for sustained multi-Gbps bursts
net.ipv4.tcp_max_syn_backlog = 4096

# Ephemeral port range
net.ipv4.ip_local_port_range = 1024 65535

# TCP memory & buffers
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_window_scaling = 1

# TCP features & behavior
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_sack = 1                     # enable SACK for better recovery at speed
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_mtu_probing = 1              # help avoid PMTU black holes with jumbo frames

# Default qdisc: fq enables TCP pacing (great with BBR)
net.core.default_qdisc = fq

# Conntrack
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 1200

# UDP floors for bursty workloads (optional but helpful)
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
##### END rpi5 tuning #####
EOF

# Conntrack sysctls exist only after its module is loaded, including on later boots.
install -d -m 0755 /etc/modules-load.d
printf '%s\n' nf_conntrack > /etc/modules-load.d/nf_conntrack.conf
modprobe nf_conntrack

# Optional immediate apply (safe even if you plan to reboot)
echo "Applying sysctl settings (optional pre-reboot)..."
sysctl -p /etc/sysctl.d/99-billspi-network.conf || true

### Ensure sch_fq is available on every boot (qdisc module for fq pacing)
echo "sch_fq" | tee /etc/modules-load.d/sch_fq.conf >/dev/null

### Create default config (users can opt-in to jumbo MTU here)
if [[ ! -f /etc/default/network_optimize ]]; then
    echo "Creating /etc/default/network_optimize with safe defaults..."
    tee /etc/default/network_optimize >/dev/null <<'EOF'
# Set to 1 to enable jumbo MTU on the selected interface
JUMBO_MTU=0
# MTU value used when JUMBO_MTU=1
JUMBO_MTU_VALUE=9000
EOF
fi

### ETHERNET / NETWORK DEVICE OPTIMIZATIONS (via systemd oneshot + udev)
# Ensure ethtool and tc are present (tc lives in iproute2)
if ! command -v ethtool &>/dev/null; then
    echo "Installing ethtool..."
    apt-get update
    apt-get install -y ethtool
fi
if ! command -v tc &>/dev/null; then
    echo "Installing iproute2 (tc)..."
    apt-get update
    apt-get install -y iproute2
fi

# Create the runtime apply script for NIC tuning (auto-picks the fastest UP interface)
echo "Creating /usr/local/bin/network_optimize.sh..."
tee /usr/local/bin/network_optimize.sh >/dev/null <<'EOF'
#!/bin/bash
set -euo pipefail

# give hotplug a moment to settle
udevadm settle --timeout=1 || sleep 0.2

# Load optional config
if [[ -f /etc/default/network_optimize ]]; then
    # shellcheck disable=SC1091
    . /etc/default/network_optimize
fi
JUMBO_MTU=${JUMBO_MTU:-0}
JUMBO_MTU_VALUE=${JUMBO_MTU_VALUE:-9000}

pick_iface() {
    local best="" best_mbps=0
    for path in /sys/class/net/*; do
        dev="${path##*/}"
        [[ "$dev" == "lo" ]] && continue
        # consider devices that are UP (carrier present)
        if ip link show "$dev" | grep -q "state UP"; then
            spd=$(ethtool "$dev" 2>/dev/null | awk -F': ' '/Speed:/{gsub(/[^0-9]/,"",$2); print $2}' || true)
            [[ -z "$spd" ]] && continue
            if (( spd > best_mbps )); then
                best_mbps=$spd
                best=$dev
            fi
        fi
    done
    # fallback if nothing is UP yet
    if [[ -z "$best" ]]; then
        for d in /sys/class/net/*; do
            b=$(basename "$d")
            [[ "$b" != "lo" ]] && echo "$b" && return 0
        done
    fi
    echo "$best"
}

IFACE="$(pick_iface)"
[[ -z "$IFACE" ]] && exit 0

# Use sch_fq on the active interface so BBR can pace accurately
modprobe sch_fq || true
tc qdisc replace dev "$IFACE" root fq || true

# --- Multi-core steering: RPS/RFS/XPS ---
CPUS="$(nproc)"
MASK=$(( (1 << CPUS) - 1 ))
HEXMASK=$(printf "%x" "$MASK")
# Global RFS entries (divide across RX queues)
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries || true
for q in /sys/class/net/"$IFACE"/queues/rx-*; do
    echo "$HEXMASK" > "$q"/rps_cpus 2>/dev/null || true
    echo 4096 > "$q"/rps_flow_cnt 2>/dev/null || true
done
# XPS for TX queues
for q in /sys/class/net/"$IFACE"/queues/tx-*; do
    echo "$HEXMASK" > "$q"/xps_cpus 2>/dev/null || true
done

# Disable Energy-Efficient Ethernet (EEE) if supported
/sbin/ethtool --set-eee "$IFACE" eee off || true

# Enable offloads (driver-dependent; RTL8156BG via r8152 supports GRO; TSO/GSO may vary)
/sbin/ethtool -K "$IFACE" gso on tso on gro on || true

# Interrupt moderation: 0us for <=1G (low latency), 100us for >=2.5G (throughput/CPU efficiency)
LINK_MBPS=$(ethtool "$IFACE" 2>/dev/null | awk -F': ' '/Speed:/{gsub(/[^0-9]/,"",$2); print $2}')
if [[ -n "$LINK_MBPS" ]] && (( LINK_MBPS >= 2500 )); then
    /sbin/ethtool -C "$IFACE" rx-usecs 100 || true
else
    /sbin/ethtool -C "$IFACE" rx-usecs 0 || true
fi

# RX/TX queue sizes (max supported by driver)
/sbin/ethtool -G "$IFACE" rx 4096 tx 4096 || true

# Flow control (pause frames)
/sbin/ethtool -A "$IFACE" rx on tx on || true

# Optional Jumbo MTU + bigger egress queue (ensure end-to-end MTU support)
if [[ "$JUMBO_MTU" == "1" ]]; then
    /sbin/ip link set dev "$IFACE" mtu "$JUMBO_MTU_VALUE" || true
fi
/sbin/ip link set dev "$IFACE" txqueuelen 4096 || true
EOF
chmod +x /usr/local/bin/network_optimize.sh

# Systemd oneshot service to apply NIC tuning at boot (and when udev triggers it)
echo "Creating /etc/systemd/system/network_optimize.service..."
tee /etc/systemd/system/network_optimize.service >/dev/null <<'EOF'
[Unit]
Description=Apply network optimizations for fastest NIC (e.g., RTL8156BG 2.5GbE) on Raspberry Pi 5
Wants=network.target
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/network_optimize.sh

[Install]
WantedBy=multi-user.target
EOF

# Enable only; starting now is redundant because you'll reboot
systemctl daemon-reload
systemctl enable network_optimize.service

### UDEV HOOKS
# 1) Re-run optimizer whenever a NIC link comes UP
echo "Installing udev rule to trigger optimization on link-up..."
tee /etc/udev/rules.d/99-network-optimize.rules >/dev/null <<'EOF'
# When any non-lo network interface reports operstate "up", ask systemd to run the optimizer
ACTION=="add",    SUBSYSTEM=="net", KERNEL!="lo", ATTR{operstate}=="up", TAG+="systemd", ENV{SYSTEMD_WANTS}+="network_optimize.service"
ACTION=="change", SUBSYSTEM=="net", KERNEL!="lo", ATTR{operstate}=="up", TAG+="systemd", ENV{SYSTEMD_WANTS}+="network_optimize.service"
EOF

# 2) Disable USB autosuspend for Realtek RTL8156/RTL8156B/RTL8156BG
echo "Installing udev rule to disable USB autosuspend for Realtek 2.5GbE..."
tee /etc/udev/rules.d/98-usb-rtl8156-nosuspend.rules >/dev/null <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="8156", TEST=="power/control", ATTR{power/control}="on"
EOF

# Reload udev rules now (and trigger once for current devices)
udevadm control --reload-rules
udevadm trigger --subsystem-match=usb
udevadm trigger --subsystem-match=net

### IRQ BALANCE & DNSMASQ
echo "Installing irqbalance..."
apt-get update
apt-get install -y irqbalance
systemctl daemon-reload
systemctl enable irqbalance

# Make dnsmasq optional to avoid stealing :53 unexpectedly
if [[ "${ENABLE_DNSMASQ:-0}" == "1" ]]; then
  echo "Enabling dnsmasq (ENABLE_DNSMASQ=1)..."
  apt-get install -y dnsmasq
  systemctl daemon-reload
  systemctl enable dnsmasq
else
  echo "dnsmasq disabled (ENABLE_DNSMASQ!=1)."
fi
# Do not start now; reboot will start them

# RCU callback offloading (rcu_nocbs):
# Offload RCU callbacks from all CPUs (0..N-1) to RCU kthreads to reduce jitter on
# latency-critical/isolated CPUs. Useful when doing CPU isolation/low-latency tuning
# (often alongside nohz_full and IRQ affinity). Not generally needed for typical servers.
# On Raspberry Pi OS Bookworm+, the kernel command line lives in /boot/firmware/cmdline.txt
# (the old /boot/cmdline.txt is a "moved" stub). nohz_full already implies rcu_nocbs.
# Docs: Linux kernel command line; RCU offload guidance.

# pick the right cmdline file
CMDLINE_FILE=""
if [ -f /boot/firmware/cmdline.txt ]; then
  CMDLINE_FILE=/boot/firmware/cmdline.txt
elif [ -f /boot/cmdline.txt ]; then
  CMDLINE_FILE=/boot/cmdline.txt
fi

if [ -n "$CMDLINE_FILE" ] && \
   grep -qx 'CONFIG_RCU_NOCB_CPU=y' "/boot/config-$(uname -r)" 2>/dev/null; then
  # optional one-time backup
  cp -n "$CMDLINE_FILE" "${CMDLINE_FILE}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

  LAST_CPU=$(( $(nproc --all) - 1 ))
  RCU_ARG="rcu_nocbs=0-${LAST_CPU}"

  if grep -q 'rcu_nocbs=' "$CMDLINE_FILE"; then
    # sed -ri "s/\brcu_nocbs=[^ ]*/$RCU_ARG/" "$CMDLINE_FILE"
    sed -ri "s/(^|[[:space:]])rcu_nocbs=[^[:space:]]*/\1$RCU_ARG/" "$CMDLINE_FILE"
  elif ! grep -qw "$RCU_ARG" "$CMDLINE_FILE"; then
    sed -i "s/$/ $RCU_ARG/" "$CMDLINE_FILE"
  fi
  echo "  -> Ensured $RCU_ARG is present in $CMDLINE_FILE"
elif [ -n "$CMDLINE_FILE" ]; then
  echo "Skipping rcu_nocbs: running kernel does not confirm CONFIG_RCU_NOCB_CPU=y."
else
  echo "  !! cmdline.txt not found" >&2
fi

### PF_RING
echo "Configuring ntop (PF_RING) repository..."

## Ensure tools needed for key setup
#apt-get update
#if ! command -v curl >/dev/null 2>&1; then
#    apt-get install -y curl
#fi
#if ! command -v gpg >/dev/null 2>&1; then
#    apt-get install -y gnupg
#fi

# Ensure tools needed for key setup
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Acquire::Retries=3 -o Dpkg::Use-Pty=0 \
          -o DPkg::Lock::Timeout=600 \
          -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

missing=()
command -v curl >/dev/null 2>&1 || missing+=(curl)
command -v gpg  >/dev/null 2>&1 || missing+=(gnupg)

if ((${#missing[@]})); then
  apt-get "${APT_OPTS[@]}" update
  apt-get "${APT_OPTS[@]}" install --no-install-recommends "${missing[@]}"
fi

# Detect arch and suite; ntop uses *_pi path on Raspberry Pi OS
. /etc/os-release
ARCH="$(dpkg --print-architecture)"        # e.g., arm64 or armhf
# Pi OS ARM64 identifies as Debian, but ntop publishes its Pi packages in *_pi.
SUITE="${VERSION_CODENAME:-bookworm}_pi"

## Install repo key into a dedicated keyring (no apt-key)
#install -d -m 0755 /usr/share/keyrings
#curl -fsSL https://packages.ntop.org/apt/ntop.key | gpg --dearmor -o /usr/share/keyrings/ntop.gpg
## Source list for ntop (restrict by arch; bind to our keyring)
#cat >/etc/apt/sources.list.d/ntop.list <<EOF
#deb [arch=${ARCH} signed-by=/usr/share/keyrings/ntop.gpg] https://packages.ntop.org/apt/${SUITE}/ ${ARCH}/
#deb [arch=all   signed-by=/usr/share/keyrings/ntop.gpg] https://packages.ntop.org/apt/${SUITE}/ all/
#EOF
#
## Optional: avoid ntop origin overriding base packages unintentionally
#cat >/etc/apt/preferences.d/ntop <<'EOF'
#Package: *
#Pin: origin packages.ntop.org
#Pin-Priority: 100
#EOF

# Install repo key into a dedicated keyring (no apt-key)
install -d -m 0755 /usr/share/keyrings
# Fetch ntop key; if it fails, skip PF_RING setup (avoid abort under set -e -o pipefail)
if curl -fsSL -- https://packages.ntop.org/apt/ntop.key | gpg --dearmor -o /usr/share/keyrings/ntop.gpg; then
  chmod 0644 /usr/share/keyrings/ntop.gpg
  # Source list for ntop (restrict by arch; bind to our keyring)
  cat >/etc/apt/sources.list.d/ntop.list <<EOF
deb [arch=${ARCH} signed-by=/usr/share/keyrings/ntop.gpg] https://packages.ntop.org/apt/${SUITE}/ ${ARCH}/
deb [arch=all   signed-by=/usr/share/keyrings/ntop.gpg] https://packages.ntop.org/apt/${SUITE}/ all/
EOF

  # Optional: avoid ntop origin overriding base packages unintentionally
  cat >/etc/apt/preferences.d/ntop <<'EOF'
Package: *
Pin: origin packages.ntop.org
Pin-Priority: 100
EOF
else
  echo "ntop key fetch failed; skipping PF_RING setup." >&2
fi

echo "Updating APT and checking for PF_RING packages..."
apt-get "${APT_OPTS[@]}" update

cand="$(apt-cache policy pfring | awk '/Candidate:/ {print $2}')"
if [[ -n "$cand" && "$cand" != "(none)" ]]; then
    echo "Checking for prebuilt PF_RING module for kernel $(uname -r)..."
    modpkg="pfring-modules-$(uname -r)"
    modcand="$(apt-cache policy "$modpkg" | awk '/Candidate:/ {print $2}')"

    if [[ -n "$modcand" && "$modcand" != "(none)" ]]; then
        echo "Found $modpkg ($modcand); installing binary module (no DKMS, no headers)."
        apt-get "${APT_OPTS[@]}" install --no-install-recommends pfring "$modpkg"
    else
        echo "No prebuilt module; installing DKMS path with headers."
## Speed up DKMS/make by using all cores during this install -- put into billspi-runner for global use
#        CORES="$(nproc)"
#        export MAKEFLAGS="-j${CORES}"
#        export DEB_BUILD_OPTIONS="parallel=${CORES}"
#        echo "Building DKMS with MAKEFLAGS=$MAKEFLAGS"

        apt-get "${APT_OPTS[@]}" install --no-install-recommends linux-headers-rpi-2712 pfring pfring-dkms || true

        # Sanity check: the build symlink should exist for the running kernel
        if [[ ! -e "/lib/modules/$(uname -r)/build" ]]; then
            echo "Warning: no headers for running kernel $(uname -r). DKMS may build after reboot into the new kernel."
        fi
    fi

#    # Speed up DKMS/make by using all cores during this install
#    CORES="$(nproc)"
#    export MAKEFLAGS="-j${CORES}"
#    export DEB_BUILD_OPTIONS="parallel=${CORES}"
#    echo "Building DKMS with MAKEFLAGS=$MAKEFLAGS"
#    
#    echo "Installing kernel headers and PF_RING (candidate: $cand)..."
#    apt-get "${APT_OPTS[@]}" install --no-install-recommends raspberrypi-kernel-headers pfring pfring-dkms || true
#
#
#    # Sanity check: the build symlink should exist for the running kernel
#    if [[ ! -e "/lib/modules/$(uname -r)/build" ]]; then
#        echo "Warning: no headers for running kernel $(uname -r). DKMS may build after reboot into the new kernel."
#    fi

    # old block for PF_RING
    #systemctl enable pf_ring || true
    #echo "Configuring hugepages for PF_RING..."
    #mkdir -p /etc/pf_ring
    #echo "node=0 hugepagenumber=512" | tee /etc/pf_ring/hugepages.conf >/dev/null

################## The above block (commented out) is replaced by this section
    # Hardened PF_RING setup (service-less): load module at boot + reserve hugepages
    # 2MB pages; 512 ~ 1 GiB. Override by exporting PFRING_NR_HUGEPAGES before running.
    PFRING_NR_HUGEPAGES="${PFRING_NR_HUGEPAGES:-512}"

    # Ensure pf_ring loads at boot
    install -d -m 0755 /etc/modules-load.d
    printf '%s\n' pf_ring > /etc/modules-load.d/pf_ring.conf

    # Try to load now if the module is available (harmless if not built yet) 
    if modinfo pf_ring >/dev/null 2>&1; then
        modprobe pf_ring || true
    else
        echo "pf_ring kernel module not available yet; will attempt to load on next boot."
    fi

    # Reserve HugeTLB pages persistently
    install -d -m 0755 /etc/sysctl.d
    cat >/etc/sysctl.d/99-pfring.conf <<EOF
# PF_RING: reserve HugeTLB pages (2MB each)
vm.nr_hugepages=${PFRING_NR_HUGEPAGES}
EOF

    # Apply hugepages now (ignore failures in constrained/unsupported environments)
    sysctl -q -p /etc/sysctl.d/99-pfring.conf || true

    # Remove legacy file used only by PF_RING init/service scripts to avoid confusion
    rm -f /etc/pf_ring/hugepages.conf

    unset MAKEFLAGS DEB_BUILD_OPTIONS
##################
else
    echo "PF_RING packages not available in ${SUITE} ${ARCH} repo right now; skipping PF_RING install."
    echo "You can build from source later if needed."
fi


# ===== Optional IPv6 disable (controlled by DISABLE_IPV6_FLAG) =====
if [[ "${DISABLE_IPV6_FLAG}" == "1" ]]; then
    echo "Disabling IPv6 (kernel cmdline + sysctl)..."

    if ! grep -qw 'ipv6.disable=1' "$CMDLINE_FILE"; then
        sed -i 's/$/ ipv6.disable=1/' "$CMDLINE_FILE"
        echo "  -> Added ipv6.disable=1 to $CMDLINE_FILE"
    fi    

  # Sysctl safeguard (also covers containers / late loads)
    tee /etc/sysctl.d/99-disable-ipv6.conf >/dev/null <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
# Loopback is optional; uncomment if you want it fully off:
# net.ipv6.conf.lo.disable_ipv6 = 1
EOF

    sysctl --system || true
    echo "IPv6 disabled. Reboot required for kernel parameter to take effect."
else
    echo "DISABLE_IPV6_FLAG=0 -> Leaving IPv6 as-is (no changes made)."
fi

# ===== System-wide limits for systemd-managed services =====
install -d -m 0755 /etc/systemd/system.conf.d
tee /etc/systemd/system.conf.d/90-rpi5-limits.conf >/dev/null <<'EOF'
[Manager]
# Per-process limits inherited by services unless overridden
DefaultLimitNOFILE=100000
DefaultLimitNPROC=65535
EOF

# Keep login-shell limits (already present) and add nproc there too
touch /etc/security/limits.conf
if ! grep -q 'BEGIN rpi5 nproc' /etc/security/limits.conf; then
    tee -a /etc/security/limits.conf >/dev/null <<'EOF'
# BEGIN rpi5 nproc
* soft nproc 65535
* hard nproc 65535
# END rpi5 nproc
EOF
fi
# Make systemd pick up defaults immediately (optional if a reboot follows)
# systemctl daemon-reexec || true

## For high-latency links with occasional half-closes:
## Increase FIN timeout (choose 20 or 30 seconds) to reduce premature closes.
#FIN_TIMEOUT=20   # set to 20 or 30; try 30 only if you truly see issues on very high-latency paths.
#SYSCTL_CONF="/etc/sysctl.conf"
## Replace existing line or append a canonical one
#if grep -Eq '^\s*net\.ipv4\.tcp_fin_timeout\s*=' "${SYSCTL_CONF}"; then
#  sed -i -E "s|^\s*net\.ipv4\.tcp_fin_timeout\s*=.*$|net.ipv4.tcp_fin_timeout = ${FIN_TIMEOUT}|" "${SYSCTL_CONF}"
#else
#  echo "net.ipv4.tcp_fin_timeout = ${FIN_TIMEOUT}" | tee -a "${SYSCTL_CONF}" >/dev/null
#fi
## Apply immediately (optional)
# sysctl -w net.ipv4.tcp_fin_timeout="${FIN_TIMEOUT}"
## Or reload the whole file:
## sysctl -p /etc/sysctl.conf

echo "All optimizations staged."

touch /run/billspi/reboot-required
exit 0

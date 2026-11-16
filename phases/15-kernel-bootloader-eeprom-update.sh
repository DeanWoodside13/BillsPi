#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")
PKGS=(raspi-firmware linux-image-rpi-2712 linux-image-rpi-v8 rpi-eeprom)
APT_OPTS+=(-o Acquire::Retries=3 -o DPkg::Lock::Timeout=60)

# Function to handle errors
error_exit() {
    # echo "Error occurred during $1, exiting..."
    echo "Error at line ${2:-$LINENO}: ${BASH_COMMAND:-unknown} (${1})" >&2
    exit 1
}

# Refresh APT lists, then cache (download-only) updates for raspberrypi-bootloader, rpi-eeprom, and raspberrypi-kernel with no recommends (no install yet)
echo "Refreshing package lists..."
apt-get "${APT_OPTS[@]}" update || error_exit "apt-get update"
echo "Downloading updates for: ${PKGS[*]} (no install)"
apt-get "${APT_OPTS[@]}" \
    --no-install-recommends \
    --download-only \
    install --only-upgrade "${PKGS[@]}" \
    || error_exit "prefetch (download-only) kernel/bootloader/eeprom packages"


# Disable network interfaces
# --- Bring network down (Pi OS: NetworkManager or dhcpcd) ---
# Detect active manager
if systemctl is-active --quiet NetworkManager; then
    PI_NET_MGR="nm"
elif systemctl is-active --quiet dhcpcd; then
    PI_NET_MGR="dhcpcd"
else
    PI_NET_MGR="none"
fi
echo "Disabling all non-loopback interfaces (manager: ${PI_NET_MGR})..."
# Record only interfaces currently UP (not lo) so we restore just those
NET_UP_DEVICES="$(ip -o link show up | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -v '^lo$' || true)"

# Ask the manager to stop managing networking, then drop links for good measure
case "$PI_NET_MGR" in
  nm)
    if command -v nmcli >/dev/null 2>&1; then
      nmcli networking off || true
    else
      systemctl stop NetworkManager || true
    fi
    ;;
  dhcpcd)
    systemctl stop dhcpcd || true
    systemctl stop wpa_supplicant 2>/dev/null || true
    ;;
  *)
    : # none
    ;;
esac
for dev in $NET_UP_DEVICES; do
  ip link set "$dev" down || true
done
echo "Network interfaces disabled."


# Apply cached (no-download) upgrades for raspberrypi-bootloader, rpi-eeprom, and raspberrypi-kernel with no recommends, then run rpi-eeprom-update -a to stage any available EEPROM update
echo "Applying cached updates for: ${PKGS[*]} (no downloads)"
apt-get "${APT_OPTS[@]}" \
    --no-install-recommends \
    --no-download \
    install --only-upgrade "${PKGS[@]}" \
    || error_exit "apply cached kernel/bootloader/eeprom packages"

if command -v rpi-eeprom-update >/dev/null 2>&1; then
    echo "Staging EEPROM update (if newer is available)..."
    rpi-eeprom-update -a || error_exit "rpi-eeprom-update -a (stage EEPROM update)"
else
    echo "Warning: rpi-eeprom-update not found; is rpi-eeprom installed?" >&2
fi


# Re-enable network interfaces
# --- Bring network back up (restore only what we took down) ---
echo "Re-enabling network interfaces..."
for dev in $NET_UP_DEVICES; do
    ip link set "$dev" up || true
done
case "$PI_NET_MGR" in
  nm)
    if command -v nmcli >/dev/null 2>&1; then
      nmcli networking on || true
    else
      systemctl restart NetworkManager || true
    fi
    ;;
  dhcpcd)
    systemctl start wpa_supplicant 2>/dev/null || true
    systemctl start dhcpcd || true
    ;;
  *)
    : # none
    ;;
esac
NET_UP_DEVICES=""
echo "Network interfaces re-enabled."

touch /run/billspi/reboot-required
exit 0

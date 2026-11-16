#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
#
# Script Purpose and Overview:
# This script disables unnecessary services and removes unneeded packages on Raspberry Pi OS Lite 
# (64-bit, kernel 6.6, Debian 12 Bookworm) to optimize system performance and reduce the attack surface.
# It ensures that services such as automatic updates, Bluetooth, WiFi, Avahi (mDNS), DHCP, and others 
# are properly disabled and not re-enabled upon reboot. Additionally, it purges related packages from the 
# system to further enhance security and resource efficiency.
#
# Key Features and Optimizations:
# 1. Disable Unnecessary Services:
#    - Disables services such as automatic updates (`apt-daily`, `apt-daily-upgrade`), Bluetooth, WiFi, DHCP, 
#      Avahi (mDNS), and NTP, reducing system load and potential vulnerabilities.
#
# 2. Masking Timers:
#    - Ensures that `apt-daily` and `apt-daily-upgrade` timers are masked, preventing them from being re-enabled 
#      during future package upgrades or system updates.
#
# 3. Conditional Service Disabling:
#    - Checks for the existence and active status of services before attempting to disable and stop them, 
#      ensuring smooth execution and preventing unnecessary error messages.
#
# 4. Purge Unnecessary Packages:
#    - Removes packages related to Bluetooth (`bluez`), WiFi (`wpasupplicant`), Avahi (`avahi-daemon`), 
#      DHCP (`dhcpcd`), NTP (`ntp`), SSH (`openssh-server`), cron (`cron`), and sound (`alsa-utils`) to minimize 
#      the system's attack surface and resource usage.
#
# 5. Package Removal Verification:
#    - Verifies the successful removal of unneeded packages by listing any that may have failed to be purged, 
#      giving the user clear feedback for further troubleshooting.
#
# 6. Automatic Cleanup:
#    - Performs an `autoremove` and `clean` to eliminate residual packages and free up system resources.
#
# 7. Flexibility for SSH and cron:
#    - Includes the option to disable SSH and cron services, though these are commented out by default to 
#      prevent the risk of losing remote access or important scheduled tasks.
#
# Usage:
# Run this script during the first boot or setup phase of Raspberry Pi OS Lite to optimize the system for 
# performance and security. Make sure to review the SSH and cron sections if they are needed for your setup.
#
# Function to verify and list any remaining packages after the removal process
#


# Disable and Mask Timers (to prevent them from re-enabling)
echo "Disabling and masking apt-daily and apt-daily-upgrade timers..."
# systemctl disable apt-daily.timer || true
# systemctl disable apt-daily-upgrade.timer || true
# systemctl stop apt-daily.timer || true
# systemctl stop apt-daily-upgrade.timer || true
# systemctl mask apt-daily.timer || true
# systemctl mask apt-daily-upgrade.timer || true

# **************************************************
# **** SET DISABLE_APT_TIMERS IN TOP SCRIPT (RUNNER)
# **************************************************
DISABLE_APT_TIMERS="${DISABLE_APT_TIMERS:-0}"
if [[ "$DISABLE_APT_TIMERS" == "1" ]]; then
    # disable both timers AND stop them if active
    systemctl disable --now apt-daily.timer apt-daily-upgrade.timer || true
    # mask both timers so they can't be started (manually or by deps)
    systemctl mask apt-daily.timer apt-daily-upgrade.timer || true
else
    echo "Keeping apt timers enabled to cooperate with unattended-upgrades."
fi

# Disable/mask a systemd unit by *name*, trying common suffixes.
# Accepts bare names ("wpa_supplicant") or fully qualified ("wpa_supplicant.service").
disable_unit() {
    local n="$1" stem u
    stem="$n"
    case "$stem" in
        *.service|*.socket|*.target|*.timer|*.path) stem="${stem%.*}" ;;
    esac
    echo "Disabling/masking $n (if present)..."
    for u in "$n" "$stem.service" "$stem.socket" "$stem.target" "$stem.timer" "$stem.path"; do
        systemctl disable --now "$u" 2>/dev/null || true
        systemctl mask "$u" 2>/dev/null || true
    done
}

# Disable Console Access Over Serial (if not used)
disable_unit "serial-getty@ttyAMA0.service"
disable_unit "serial-getty@ttyS0.service"
disable_unit "serial-getty@.service"

# Disable Bluetooth
disable_unit "hciuart"
disable_unit "bluetooth.service"

# Disable WiFi
disable_unit "wpa_supplicant"
disable_unit "wpa_supplicant.service"
disable_unit "wpa_supplicant@.service"
# optional belt-and-suspenders if you have a wlan0 instance enabled:
disable_unit "wpa_supplicant@wlan0.service"

# Disable and stop avahi-daemon
disable_unit "avahi-daemon.service"

## Disable DHCP client daemon (if using static IP)
# disable_unit "dhcpcd"

## Disable NTP (if not needed or using alternative time sync)
# disable_unit "systemd-timesyncd"

## Disable SSH (uncomment if SSH is not needed)
# disable_unit "ssh"

## Disable cron (uncomment if cron is not needed)
# disable_unit "cron"

# Disable sound support (alsa-utils)
disable_unit "alsa-utils"
disable_unit "alsa-restore.service"
disable_unit "alsa-state.service"
disable_unit "sound.target"

# Not required with 'sudo reboot' at end of script:
# systemctl daemon-reload || true

# Remove Unnecessary Packages to Minimize Attack Surface
echo "Removing unnecessary packages..."
# apt-get purge -y --auto-remove dhcpcd5 bluez wpasupplicant ntp openssh-server cron alsa-utils alsa-ucm-conf alsa-topology-conf libasound2 libasound2-data avahi-daemon || true
apt-get purge -y --auto-remove bluez wpasupplicant alsa-utils alsa-ucm-conf alsa-topology-conf libasound2 libasound2-data avahi-daemon || true

# More Secure Package Removal: Verify removed packages by listing them (if any are still present)
echo "Verifying package removal..."
echo "The following packages failed to be removed:"
# dpkg -l | awk '$1=="ii" && $2 ~ /^(dhcpcd5|bluez|wpasupplicant|ntp|openssh-server|cron|avahi-daemon|alsa-(utils|ucm-conf|topology-conf)|libasound2(-data)?)(:[^ ]+)?$/'
dpkg -l | awk '$1=="ii" && $2 ~ /^(bluez|wpasupplicant|avahi-daemon|alsa-(utils|ucm-conf|topology-conf)|libasound2(-data)?)(:[^ ]+)?$/'
echo "-- End of package list --"

# The below block was commented out, all removals/cleanup happen once in 70-cleanup.sh.  This is for performance gains.
## Clean up any residual packages
#echo "Cleaning up unused packages..."
#apt-get autoremove -y || true
#apt-get clean || true

echo "All requested services have been disabled, and unnecessary packages removed."

touch /run/billspi/reboot-required
exit 0

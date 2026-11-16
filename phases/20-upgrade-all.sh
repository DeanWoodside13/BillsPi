#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

# Noninteractive & safe defaults for unattended upgrades
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a                # auto-restart services when needed (no prompts)
export APT_LISTCHANGES_FRONTEND=none     # suppress apt-listchanges if present

# Common apt-get options
APT_OPTS=(
    -y
    -o Dpkg::Options::="--force-confdef"    # use maintainer defaults for new conffiles
    -o Dpkg::Options::="--force-confold"    # keep existing conffiles if changed
    -o Acquire::Retries=3
    -o Acquire::http::Timeout=30
    -o DPkg::Lock::Timeout=600       # give apt-daily some room
    -o APT::Color=0
    -o Dpkg::Progress-Fancy=0
)

# Function to handle errors
error_exit() {
    # echo "Error occurred during $1, exiting..."
    echo "Error at line ${2:-$LINENO}: ${BASH_COMMAND:-unknown} (${1})" >&2
    exit 1
}

# Upgrading all packages
echo "Refreshing package lists..."
apt-get "${APT_OPTS[@]}" update || error_exit "apt-get update"
echo "Upgrading all packages (may install/remove as needed)..."
apt-get "${APT_OPTS[@]}" full-upgrade || error_exit "apt-get full-upgrade"

# The below block was commented out, all removals/cleanup happen once in 70-cleanup.sh.  This is for performance gains.
#echo "Removing no-longer-needed packages..."
#apt-get "${APT_OPTS[@]}" autoremove --purge || error_exit "apt-get autoremove --purge"
#echo "Cleaning retrieved package files..."
#apt-get "${APT_OPTS[@]}" autoclean || error_exit "apt-get autoclean"
## Optional deep clean (final shrink)
#apt-get clean || true
#rm -rf /var/lib/apt/lists/* || true
#mkdir -p /var/lib/apt/lists/partial || true


touch /run/billspi/reboot-required
exit 0

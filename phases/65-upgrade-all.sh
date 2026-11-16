#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
IFS=$'\n\t'

# Noninteractive & safe defaults for unattended upgrades
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a                # auto-restart services when needed (no prompts)
export APT_LISTCHANGES_FRONTEND=none     # suppress apt-listchanges if present
export LC_ALL=C LANG=C                   # stable parsing regardless of locale

# Common apt-get options (WITH -y) for actions that can prompt
APT_OPTS_Y=(
    -y
    -o Dpkg::Options::="--force-confdef"    # use maintainer defaults for new conffiles
    -o Dpkg::Options::="--force-confold"    # keep existing conffiles if changed
    -o Acquire::Retries=3
    -o Acquire::http::Timeout=30
    -o DPkg::Lock::Timeout=600              # give apt-daily some room
    -o APT::Color=0
    -o Dpkg::Progress-Fancy=0
)

error_exit() {
    # echo "Error occurred during $1, exiting..." >&2
    echo "Error at line ${2:-$LINENO}: ${BASH_COMMAND:-unknown} (${1})" >&2
    exit 1
}

echo "Refreshing package lists..."
apt-get update || error_exit "apt-get update"

# Fast simulation to decide if anything needs upgrading (simulate what we will actually do)
summary="$(apt-get -s -o Debug::NoLocking=1 full-upgrade | awk '/upgraded,.*newly installed,.*to remove/ {line=$0} END{print line}')"
# e.g. "0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded."
if [[ -n "$summary" ]] && echo "$summary" | grep -Eq '([1-9][0-9]* upgraded|[1-9][0-9]* newly installed|[1-9][0-9]* to remove|[1-9][0-9]* not upgraded)'; then
    echo "Upgrades pending: $summary"
    echo "Upgrading all packages (may install/remove as needed)..."
    apt-get "${APT_OPTS_Y[@]}" full-upgrade || error_exit "apt-get full-upgrade"
# The below block was commented out, all removals/cleanup happen once in 70-cleanup.sh.  This is for performance gains.
#    echo "Removing no-longer-needed packages..."
#    apt-get "${APT_OPTS_Y[@]}" autoremove --purge || error_exit "apt-get autoremove --purge"
#    echo "Cleaning retrieved package files..."
#    apt-get "${APT_OPTS_Y[@]}" autoclean || error_exit "apt-get autoclean"
else
    echo "No packages need upgrading: ${summary:-"(summary unavailable)"}"
fi

# Surface reboot requirement if a kernel/glibc changed
install -d /var/lib/billspi /run/billspi
if [[ -f /var/run/reboot-required ]]; then
    cp -f /var/run/reboot-required /var/lib/billspi/reboot-required || true
    touch /run/billspi/reboot-required
fi

# Optional: mark completion (lets you skip this phase on reruns if desired)
touch /var/lib/billspi/after_full_upgrade

exit 0

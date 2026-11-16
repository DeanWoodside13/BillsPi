#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
#
# Script Purpose and Overview
# --------------------------
# Automates security patching and system updates on Raspberry Pi OS Lite (64-bit) for Raspberry Pi 5
# during initial setup. Installs and configures unattended security updates, sets deterministic
# twice-daily update/upgrade windows via systemd timers (not cron), and schedules a monthly full
# system upgrade. Designed for headless servers: noninteractive, idempotent, and logged.
#
# What this script does
# 1) Install unattended-upgrades (headless-safe)
#    - Runs `apt-get update` and installs `unattended-upgrades` with retries, dpkg lock timeout,
#      and noninteractive dpkg options (keep existing configs).
#
# 2) Enable periodic APT actions
#    - Writes /etc/apt/apt.conf.d/20auto-upgrades:
#        APT::Periodic::Update-Package-Lists "always";
#        APT::Periodic::Unattended-Upgrade "always";
#    - Disables APT's internal 30-minute jitter so schedules are deterministic:
#        /etc/apt/apt.conf.d/02billspi-periodic -> APT::Periodic::RandomSleep "0";
#
# 3) Daily unattended upgrades: Debian Security + whitelisted Raspberry Pi packages
#    - Enables the Debian-Security origin (50unattended-upgrades).
#    - Keeps Debian updates unrestricted by the Pi package whitelist.
#    - Uses /etc/apt/billspi-pi-unattended.conf for a second run in the same update window,
#      selecting Pi kernel, firmware and EEPROM packages (and their dependencies):
#         linux-image-rpi-2712/v8, raspi-firmware, raspberrypi-kernel,
#         raspberrypi-bootloader, rpi-eeprom
#      (Everything else from Pi repos is handled by the monthly full-upgrade.)
#
# 4) Use systemd timers (not cron) for cadence
#    - Enables standard timers: apt-daily.timer (lists) and apt-daily-upgrade.timer (upgrades).
#    - Optionally triggers a one-off unattended-upgrade run immediately.
#
# 5) Twice-daily fixed windows (deterministic)
#    - Adds systemd drop-ins that:
#        * Refresh/download package lists at 05:30 and 17:30 (apt-daily.timer).
#        * Apply security upgrades at 06:00 and 18:00 (apt-daily-upgrade.timer).
#      RandomizedDelaySec is disabled so these windows are predictable.
#
# 6) Monthly full system upgrade
#    - Installs a systemd service + timer to run `apt-get full-upgrade` on the 1st of each month at 02:00,
#      with a bounded timeout, mirror retries.
#    - Logs to /var/log/billspi-monthly-upgrade.log and orders after apt-daily services to reduce lock fights.
#    - OPTIONAL: a weekly timer (Sunday 02:00) is available in-file and can be enabled by uncommenting the
#      provided systemctl lines; it reuses the same service.
#
# 7) Logging & operational notes
#    - General script log: /var/log/auto-update-script.log
#    - Ensures /var/log/unattended-upgrades exists for unattended-upgrades logs.
#    - Uses `set -Eeuo pipefail` for fail-fast behavior; commands are idempotent where possible.
#
# 8) Reboot signaling (no automatic reboot)
#    - Touches /run/billspi/reboot-required for an external orchestrator to act on if desired.
#      The script itself does NOT reboot the system.
#
# Usage
# - Run once during image provisioning / first-boot setup as root on Raspberry Pi OS Lite (Bookworm or later).
# - After this runs, security updates occur twice daily; a full system upgrade runs monthly.
#
# Adjusting schedules
# - Edit the systemd timer drop-ins (OnCalendar=) for apt-daily/apt-daily-upgrade to change times.
# - Edit the monthly timer OnCalendar= if you want a different day/time.
#
# Quick verification
# - systemctl list-timers | grep -E 'apt-daily|apt-daily-upgrade|billspi-monthly'
# - grep -n 'Debian-Security' /etc/apt/apt.conf.d/50unattended-upgrades
# - tail -n 200 /var/log/unattended-upgrades/unattended-upgrades.log
# - tail -n 200 /var/log/billspi-monthly-upgrade.log
#

LOG_FILE="/var/log/auto-update-script.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') Starting automated update setup" >> "$LOG_FILE"

# Step 1: Automated Security Patching - Part 1 (Installing and Enabling Unattended-Upgrades)
echo "Starting automated security patching setup..."

# Install unattended-upgrades
if ! dpkg-query -W -f='${Status}\n' unattended-upgrades 2>/dev/null | grep -q 'install ok installed'; then
    echo "Installing unattended-upgrades..."

    # Sane APT defaults: retries, noninteractive dpkg, lock timeout, keep existing confs
    APT_OPTS=(-y -o Acquire::Retries=3 -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=600 \
              -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

    # Refresh package lists before installation
    apt-get "${APT_OPTS[@]}" update

    # Install the package (retries handled by Acquire::Retries)
    if ! apt-get "${APT_OPTS[@]}" install unattended-upgrades; then
        echo "Error: Failed to install unattended-upgrades." >&2
        [ -n "${LOG_FILE:-}" ] && echo "$(date '+%Y-%m-%d %H:%M:%S') Failed to install unattended-upgrades." >> "$LOG_FILE"
        exit 1
    fi
else
    echo "unattended-upgrades is already installed."
fi

# Modify the configuration for unattended-upgrades
echo "Configuring automatic security updates..."
# Restrict unattended-upgrades to Debian Security (Bookworm/RPi OS)
sed -i -E \
  -e 's#^([[:space:]]*)("origin=Debian,codename=\$\{distro_codename\},label=Debian";)#\1// \2#' \
  -e 's#^//\s*"origin=Debian,codename=\$\{distro_codename\},label=Debian-Security";#"origin=Debian,codename=${distro_codename},label=Debian-Security";#' \
  /etc/apt/apt.conf.d/50unattended-upgrades

# Use this version?  The above relies on a PCRE-style shorthand, with '\s' -- possibly bad idea?
#sed -i -E \
#  's#^//[[:space:]]*"origin=Debian,codename=\$\{distro_codename\},label=Debian-Security";#"origin=Debian,codename=${distro_codename},label=Debian-Security";#' \
#  /etc/apt/apt.conf.d/50unattended-upgrades


if [ $? -ne 0 ]; then
    echo "Error: Failed to modify /etc/apt/apt.conf.d/50unattended-upgrades." >&2
    echo "$(date '+%Y-%m-%d %H:%M:%S') Failed to modify 50unattended-upgrades." >> "$LOG_FILE"
    exit 1
fi



# Normal unattended run: Debian updates, without the Pi-specific whitelist.
cat >/etc/apt/apt.conf.d/51-billspi-unattended-upgrades.conf <<'EOF'
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};

// Shared settings for both Debian and Pi runs
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF

chmod 0644 /etc/apt/apt.conf.d/51-billspi-unattended-upgrades.conf

# Load this only for the Pi run; APT then also loads the normal shared configuration.
cat >/etc/apt/billspi-pi-unattended.conf <<'EOF'
Unattended-Upgrade::Origins-Pattern {
    "o=Raspberry Pi Foundation,n=${distro_codename}";
    "o=Raspbian,n=${distro_codename}";
};

// Pi kernel, firmware and EEPROM package roots, including current kernel meta-packages
Unattended-Upgrade::Package-Whitelist {
    "^linux-image-rpi-(2712|v8)$";
    "^raspi-firmware$";
    "^raspberrypi-kernel$";
    "^raspberrypi-bootloader$";
    "^rpi-eeprom$";
};

// Permit required dependencies outside the root-package whitelist.
Unattended-Upgrade::Package-Whitelist-Strict "false";
EOF

chmod 0644 /etc/apt/billspi-pi-unattended.conf



# Let the existing twice-daily timers control the update cadence.
echo "Enabling twice-daily updates..."
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOL'
APT::Periodic::Update-Package-Lists "always";
APT::Periodic::Unattended-Upgrade "always";
EOL
if [ $? -ne 0 ]; then
    echo "Error: Failed to configure /etc/apt/apt.conf.d/20auto-upgrades." >&2
    echo "$(date '+%Y-%m-%d %H:%M:%S') Failed to configure 20auto-upgrades." >> "$LOG_FILE"
    exit 1
fi

# Make apt's own scheduler deterministic (disable its internal 30m jitter)
cat >/etc/apt/apt.conf.d/02billspi-periodic <<'EOF'
APT::Periodic::RandomSleep "0";
APT::Periodic::AutocleanInterval "7";
EOF

# optional immediate run:
systemctl start unattended-upgrades.service || true

# Optional: kick a one-off security run now (harmless if nothing pending)
unattended-upgrade -d || true
APT_CONFIG=/etc/apt/billspi-pi-unattended.conf unattended-upgrade -d || true


# --- Twice-daily unattended upgrades at fixed times (Bookworm/RPi OS) ---
# Run apt list updates at 05:30 & 17:30, then install upgrades at 06:00 & 18:00.
# Create drop-in for apt-daily.timer (updates package lists / downloads)
install -d /etc/systemd/system/apt-daily.timer.d
cat >/etc/systemd/system/apt-daily.timer.d/override.conf <<'EOF'
[Timer]
# Clear vendor values, then set our own
OnCalendar=
OnCalendar=*-*-* 05:30:00
OnCalendar=*-*-* 17:30:00
RandomizedDelaySec=0
AccuracySec=1min
Persistent=true
EOF

# Create drop-in for apt-daily-upgrade.timer (performs unattended upgrades)
install -d /etc/systemd/system/apt-daily-upgrade.timer.d
cat >/etc/systemd/system/apt-daily-upgrade.timer.d/override.conf <<'EOF'
[Timer]
# Clear vendor values, then set our own
OnCalendar=
OnCalendar=*-*-* 06:00:00
OnCalendar=*-*-* 18:00:00
RandomizedDelaySec=0
AccuracySec=1min
Persistent=true
EOF

# Apply the Pi selection after the Debian run, under the existing upgrade timer.
install -d /etc/systemd/system/apt-daily-upgrade.service.d
cat >/etc/systemd/system/apt-daily-upgrade.service.d/billspi-pi.conf <<'EOF'
[Service]
ExecStartPost=/usr/bin/env APT_CONFIG=/etc/apt/billspi-pi-unattended.conf /usr/bin/unattended-upgrade
EOF

# Apply overrides and (re)start timers
systemctl daemon-reload
systemctl unmask apt-daily.timer apt-daily-upgrade.timer
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
systemctl restart apt-daily.timer apt-daily-upgrade.timer

# (Optional) Log for your script
if [ -n "${LOG_FILE:-}" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') Set apt timers: lists at 05:30/17:30; upgrades at 06:00/18:00 (no jitter)." >> "$LOG_FILE"
fi
# --- end twice-daily block ---


# --- billspi monthly full-upgrade via systemd (first of month @ 02:00) ---
# Create systemd service
cat >/etc/systemd/system/billspi-monthly-upgrade.service <<'EOF'
[Unit]
Description=Monthly full system upgrade (billspi)
Documentation=man:apt-get(8)
Wants=network.target
After=network.target apt-daily.service apt-daily-upgrade.service

[Service]
Type=oneshot
TimeoutStartSec=0
# Keep things noninteractive and resilient to transient issues/locks
Environment=DEBIAN_FRONTEND=noninteractive
# Run a bounded upgrade with retries and safe dpkg options; log is appended below
ExecStart=/usr/bin/timeout 1800 /bin/bash -lc '\
  apt-get -y -o Acquire::Retries=3 -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=600 update && \
  apt-get -y -o Acquire::Retries=3 -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=600 \
    -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    full-upgrade'

# Append logs to an easy-to-inspect file
StandardOutput=append:/var/log/billspi-monthly-upgrade.log
StandardError=append:/var/log/billspi-monthly-upgrade.log
ExecStartPost=/bin/bash -lc 'if [ -f /run/reboot-required.pkgs ]; then printf "%%s Reboot recommended by packages: " "$$(date +%%F) $$(date +%%T)" >> /var/log/billspi-monthly-upgrade.log; tr "\n" " " </run/reboot-required.pkgs >> /var/log/billspi-monthly-upgrade.log; echo >> /var/log/billspi-monthly-upgrade.log; fi'
EOF

# Create systemd timer (runs on the 1st of every month @ 02:00, with jitter)
cat >/etc/systemd/system/billspi-monthly-upgrade.timer <<'EOF'
[Unit]
Description=Run monthly full system upgrade (billspi)

[Timer]
OnCalendar=*-*-01 02:00:00
# Spread out runs across devices to avoid thundering herds
RandomizedDelaySec=45m
# If the machine was off at the scheduled time, run shortly after boot
Persistent=true
Unit=billspi-monthly-upgrade.service

[Install]
WantedBy=timers.target
EOF

# Permissions, reload units, and enable the timer
chmod 0644 /etc/systemd/system/billspi-monthly-upgrade.{service,timer}
systemctl daemon-reload
systemctl enable --now billspi-monthly-upgrade.timer || true

# (Optional) Log a note in your existing script log if $LOG_FILE is set
if [ -n "${LOG_FILE:-}" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') Enabled billspi-monthly-upgrade.timer (runs OnCalendar=*-*-01 02:00:00 with RandomizedDelaySec=45m)." >> "$LOG_FILE"
fi
# --- end monthly full-upgrade block ---

# --- OPTIONAL: billspi weekly full-upgrade timer (disabled by default) ---
# Reuse the same service; only the schedule changes to weekly (Sunday 02:00).
cat >/etc/systemd/system/billspi-weekly-upgrade.timer <<'EOF'
[Unit]
Description=Run weekly full system upgrade (billspi)

[Timer]
OnCalendar=Sun 02:00:00
# If the machine was off at the scheduled time, run shortly after boot
Persistent=true
Unit=billspi-monthly-upgrade.service

[Install]
WantedBy=timers.target
EOF

chmod 0644 /etc/systemd/system/billspi-weekly-upgrade.timer
systemctl daemon-reload

# Default posture: keep monthly enabled; ensure weekly is disabled.
systemctl disable --now billspi-weekly-upgrade.timer 2>/dev/null || true

# To SWITCH to weekly instead of monthly, uncomment the two lines below:
# systemctl disable --now billspi-monthly-upgrade.timer || true
# systemctl enable  --now billspi-weekly-upgrade.timer  || true
# --- end optional weekly block ---

# Verify logs will be created for unattended upgrades
if [ ! -d "/var/log/unattended-upgrades" ]; then
    mkdir /var/log/unattended-upgrades
    chmod 755 /var/log/unattended-upgrades
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create /var/log/unattended-upgrades directory." >&2
        echo "$(date '+%Y-%m-%d %H:%M:%S') Failed to create unattended-upgrades log directory." >> "$LOG_FILE"
        exit 1
    fi
fi

# Replace the four lines above with this pair (optional)
echo "Automated updates setup complete: Debian security + whitelisted Pi packages (twice daily), monthly full-upgrade enabled."
echo "$(date '+%Y-%m-%d %H:%M:%S') Setup complete: security (twice daily) + monthly full-upgrade." >> "$LOG_FILE"

# Leave this reboot marker, its for a top-running orchestrator service
touch /run/billspi/reboot-required
exit 0

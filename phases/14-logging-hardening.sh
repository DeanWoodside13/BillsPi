#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
# Pi OS Lite: Logging Hardening
# Purpose: Improve auditability and retention. Makes journald persistent with sane limits, logs sudo commands to a file,
#          adds logrotate rules, and (optionally) installs a daily Logwatch report to disk.
# Scope: Debian 12 / Raspberry Pi OS Lite. Root required. Idempotent.
#
# What this script does:
# - journald: Storage=persistent under /var/log/journal with size/time caps; restarts systemd-journald.
# - sudo: Adds /etc/sudoers.d/logfile (Defaults logfile="/var/log/sudo.log", !syslog) validated by visudo; creates logrotate rule.
# - logrotate: Ensures logrotate is installed and rotates /var/log/sudo.log weekly.
# - logwatch (optional): Installs logwatch, writes daily summary to /var/log/logwatch/logwatch.log via a systemd timer at 06:00,
#                        and rotates it daily.
#
# Controls:
# - ENABLE_LOGWATCH=1   Enable Logwatch install + timer; default 0 (disabled).
#
# Rollback:
# - Remove /etc/systemd/journald.conf.d/99-persistent.conf and restart systemd-journald.
# - Remove /etc/sudoers.d/logfile (use visudo), delete /etc/logrotate.d/sudo, and remove /var/log/sudo.log if desired.
# - Disable logwatch: systemctl disable --now logwatch-daily.timer; remove /etc/systemd/system/logwatch-daily.* and
#   /etc/logwatch/conf/logwatch.conf plus /etc/logrotate.d/logwatch.
#
# Verify:
# - journalctl --disk-usage ; systemctl status systemd-journald
# - sudo -l ; sudo true ; tail -n50 /var/log/sudo.log
# - logrotate -d /etc/logrotate.d/sudo ; systemctl list-timers | grep logwatch
#
# 14-logging-hardening.sh
# Make journald persistent with sane limits, log sudo to file, add logrotate rules,
# and optionally install Logwatch to write daily summaries to /var/log/logwatch/.
# Pi OS Lite (Debian 12/Bookworm). Run as root.
#
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C LANG=C
export DEBIAN_FRONTEND=noninteractive

# Optional: enable Logwatch via environment
ENABLE_LOGWATCH="${ENABLE_LOGWATCH:-0}"

# APT opts (used only if installing logrotate/logwatch)
APT_OPTS=(-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y)
APT_OPTS+=(-o Acquire::Retries=3 -o DPkg::Lock::Timeout=60)

echo "Configuring persistent journald with limits..."

# 1) journald: persistence + conservative limits (tune as needed)
install -d -m 0755 /etc/systemd/journald.conf.d
tee /etc/systemd/journald.conf.d/99-persistent.conf >/dev/null <<'EOF'
[Journal]
# Persist logs under /var/log/journal (not tmpfs)
Storage=persistent

# Cap usage on disk; keep some free space
SystemMaxUse=200M
SystemKeepFree=50M

# Limit individual file size and retention window
SystemMaxFileSize=50M
MaxFileSec=1month

# Optional: rate limiting (uncomment to clamp bursts)
#RateLimitIntervalSec=30s
#RateLimitBurst=1000
EOF

install -d -m 2755 -o root -g systemd-journal /var/log/journal || true
systemctl daemon-reload
systemctl restart systemd-journald
journalctl --flush

echo "Enabling sudo command logging to /var/log/sudo.log ..."

# 2) sudo: log to file via drop-in, validate with visudo
install -d -m 0755 /etc/sudoers.d
# Use a temp file then install with 0440 to satisfy sudo’s requirements
tmp_sudo="$(mktemp)"
cat > "$tmp_sudo" <<'EOF'
Defaults logfile="/var/log/sudo.log"
# Avoid duplicate logging via syslog if rsyslog is present
Defaults !syslog
EOF
# Validate syntax before installing
if visudo -cf "$tmp_sudo" >/dev/null 2>&1; then
  install -m 0440 "$tmp_sudo" /etc/sudoers.d/logfile
else
  echo "visudo validation failed; refusing to install /etc/sudoers.d/logfile" >&2
  rm -f "$tmp_sudo"
  exit 1
fi
rm -f "$tmp_sudo"

# Ensure sudo log exists with tight perms
touch /var/log/sudo.log
chmod 0600 /var/log/sudo.log
chown root:root /var/log/sudo.log

echo "Adding logrotate rule(s)..."

# 3) logrotate for sudo.log (journald rotates itself; no logrotate rule needed for journal)
cat >/etc/logrotate.d/sudo <<'EOF'
/var/log/sudo.log {
    weekly
    rotate 12
    maxsize 5M
    missingok
    compress
    delaycompress
    notifempty
    create 0600 root root
}
EOF

# Ensure logrotate is present
apt-get -o Acquire::Retries=3 update || true
apt-get "${APT_OPTS[@]}" install --no-install-recommends logrotate

# 4) Optional: Logwatch to file (no MTA needed). Set ENABLE_LOGWATCH=1 to enable.
if [[ "$ENABLE_LOGWATCH" == "1" ]]; then
  echo "Installing and configuring Logwatch (file output)..."
  apt-get "${APT_OPTS[@]}" install --no-install-recommends logwatch

  install -d -m 0755 /etc/logwatch/conf || true
  install -d -m 0755 /var/log/logwatch || true

  # Minimal override config: write a daily file; range=yesterday; text format.
  tee /etc/logwatch/conf/logwatch.conf >/dev/null <<'EOF'
# Logwatch override
Output = file
Format = text
Filename = /var/log/logwatch/logwatch.log
Range = yesterday
Detail = Low
Service = All
EOF

  # logrotate for the logwatch output file
  cat >/etc/logrotate.d/logwatch <<'EOF'
/var/log/logwatch/logwatch.log {
    daily
    rotate 14
    missingok
    compress
    delaycompress
    notifempty
    copytruncate
    create 0640 root adm
}
EOF

  # systemd timer to run logwatch daily at 06:00
  cat >/etc/systemd/system/logwatch-daily.service <<'EOF'
[Unit]
Description=Run Logwatch daily report (to file)

[Service]
Type=oneshot
ExecStart=/usr/sbin/logwatch --output file --filename /var/log/logwatch/logwatch.log --range yesterday --detail Low
EOF

  cat >/etc/systemd/system/logwatch-daily.timer <<'EOF'
[Unit]
Description=Daily Logwatch report

[Timer]
OnCalendar=*-*-* 06:00:00
Persistent=true
Unit=logwatch-daily.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now logwatch-daily.timer
else
  echo "Logwatch: skipped (set ENABLE_LOGWATCH=1 to enable)."
fi

# Signal reboot-required for your suite, if you use that convention
install -d -m 0755 /run/billspi || true
touch /run/billspi/reboot-required

echo "Logging hardening complete."
exit 0

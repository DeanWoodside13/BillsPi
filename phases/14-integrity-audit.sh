#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
# Pi OS Lite: Integrity & Audit Hardening
# Purpose: Add file-integrity monitoring (AIDE) and real-time audit trails (auditd) for critical system/config paths.
# Scope: Debian 12 / Raspberry Pi OS Lite. Root required. Idempotent.
#
# What this script sets up:
# - AIDE rules in /etc/aide/aide.conf.d/10-hardening.rules and ensures aide.conf includes that directory.
# - Initializes the AIDE database (first run) and installs a daily integrity check timer at 03:15 writing to /var/log/aide/aide-check.log.
# - Log rotation for the AIDE report via /etc/logrotate.d/aide.
# - auditd watches for /etc, /etc/ssh, /etc/fail2ban, /etc/systemd, /usr/local/{bin,sbin}, and /boot; loads rules with augenrules.
#
# Notes:
# - AIDE macro omits 'selinux' (not always compiled on Pi OS); uses strong hashes and metadata (sha512, xattrs, ACLs).
# - The aide-check service prefers /usr/bin/aide.wrapper, falling back to /usr/bin/aide.
# - No immutable audit mode is set (no -e 2), to avoid locking rules at runtime.
#
# Rollback:
# - Disable timer: systemctl disable --now aide-check.timer
# - Remove AIDE additions: delete /etc/aide/aide.conf.d/10-hardening.rules (and the include line from /etc/aide/aide.conf if desired)
# - Remove audit rules: delete /etc/audit/rules.d/99-hardening.rules && augenrules --load
#
# Verify:
# - AIDE config: aide --config-check ; manual run: /usr/bin/aide --check | less
# - Timer: systemctl status aide-check.timer ; systemctl start aide-check.service ; tail -n +1 /var/log/aide/aide-check.log
# - Audit rules: auditctl -l | egrep '/etc/|/boot/|/usr/local/(bin|sbin)'
#
# 14-integrity-audit.sh
# Add AIDE file-integrity monitoring and basic auditd watches for critical configs.
# Pi OS Lite (Debian 12/Bookworm). Run as root.
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C LANG=C
export DEBIAN_FRONTEND=noninteractive

APT_OPTS=(-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y)
APT_OPTS+=(-o Acquire::Retries=3 -o DPkg::Lock::Timeout=60)

echo "Installing integrity/audit components..."
apt-get -o Acquire::Retries=3 update || true
apt-get "${APT_OPTS[@]}" --no-install-recommends install aide aide-common auditd logrotate

# ---------------- AIDE configuration ----------------
echo "Configuring AIDE rules..."
install -d -m 0755 /etc/aide/aide.conf.d
# Bookworm's aide.conf already includes aide.conf.d using @@x_include.
install -d -m 0755 /var/log/aide
install -d -m 0755 /var/lib/aide


# Conservative rule set: metadata + strong hashes + xattrs/ACLs
# NOTE: omit 'selinux' token (not always compiled into AIDE on Pi OS)
tee /etc/aide/aide.conf.d/10-billspi-hardening >/dev/null <<'EOF'
# AIDE hardening additions
HARDEN = p+i+n+u+g+acl+xattrs+m+c+sha512

# Critical configs
/etc            HARDEN
/etc/ssh        HARDEN
/etc/fail2ban   HARDEN
/etc/systemd    HARDEN

# Local admin binaries
/usr/local/bin  HARDEN
/usr/local/sbin HARDEN

# Boot artifacts
/boot           =vfat HARDEN-i
/boot           HARDEN

# Optional web root (only if present)
/var/www        HARDEN
EOF

## Initialize AIDE database if missing
#if [[ ! -s /var/lib/aide/aide.db.gz && ! -s /var/lib/aide/aide.db ]]; then
#  echo "Initializing AIDE database (first run)..."
#  if command -v aideinit >/dev/null 2>&1; then
#    aideinit
#  else
#    aide --init
#  fi
#  # Move generated DB into place (covers both gzip/plain cases)
#  [[ -f /var/lib/aide/aide.db.new.gz ]] && mv -f /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz || true
#  [[ -f /var/lib/aide/aide.db.new    ]] && mv -f /var/lib/aide/aide.db.new    /var/lib/aide/aide.db    || true
#fi

# Defer AIDE database initialization until provisioning is complete (one-time)
tee /etc/systemd/system/aide-initialize.service >/dev/null <<'EOF'
[Unit]
Description=One-time AIDE DB initialization
ConditionPathExists=/var/lib/billspi/setup.done
ConditionPathExists=!/var/lib/aide/aide.db
ConditionPathExists=!/var/lib/aide/aide.db.gz
After=local-fs.target billspi-setup.service
Before=aide-check.service

[Service]
Type=oneshot
ExecStart=/usr/bin/aide --init -c /etc/aide/aide.conf
ExecStart=/bin/sh -c '[ -f /var/lib/aide/aide.db.new.gz ] && mv -f /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz || true'
ExecStart=/bin/sh -c '[ -f /var/lib/aide/aide.db.new ] && mv -f /var/lib/aide/aide.db.new /var/lib/aide/aide.db || true'
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

systemctl enable aide-initialize.service >/dev/null || true


# AIDE daily check service+timer
echo "Installing AIDE daily check timer..."
tee /etc/systemd/system/aide-check.service >/dev/null <<'EOF'
[Unit]
Description=AIDE integrity check
ConditionPathExists=/var/lib/billspi/setup.done
Requires=aide-initialize.service
After=aide-initialize.service

[Service]
Type=oneshot
# Prefer aide.wrapper if available; fall back to aide
ExecStart=/bin/sh -c 'cmd="/usr/bin/aide.wrapper"; [ -x "$$cmd" ] || cmd="/usr/bin/aide"; exec "$$cmd" --check -c /etc/aide/aide.conf'
# AIDE reports file differences with 1-7; execution/configuration failures remain fatal.
SuccessExitStatus=1 2 3 4 5 6 7
StandardOutput=truncate:/var/log/aide/aide-check.log
StandardError=inherit
EOF

# Gate the packaged daily check on the same completed baseline.
install -d -m 0755 /etc/systemd/system/dailyaidecheck.service.d
tee /etc/systemd/system/dailyaidecheck.service.d/billspi.conf >/dev/null <<'EOF'
[Unit]
ConditionPathExists=/var/lib/billspi/setup.done
Requires=aide-initialize.service
After=aide-initialize.service
EOF

tee /etc/systemd/system/aide-check.timer >/dev/null <<'EOF'
[Unit]
Description=Run AIDE integrity check daily

[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true
Unit=aide-check.service

[Install]
WantedBy=timers.target
EOF

# Rotate AIDE logs
tee /etc/logrotate.d/aide >/dev/null <<'EOF'
/var/log/aide/aide-check.log {
    weekly
    rotate 8
    maxsize 2M
    missingok
    compress
    delaycompress
    notifempty
    copytruncate
    create 0640 root adm
}
EOF

systemctl daemon-reload
systemctl enable aide-check.timer

# ---------------- auditd configuration ----------------
echo "Configuring auditd rules for critical paths..."
install -d -m 0755 /etc/audit/rules.d

tee /etc/audit/rules.d/99-hardening.rules >/dev/null <<'EOF'
# Watch critical configuration trees for writes/attr changes
-w /etc/ -p wa -k etc_watch
-w /etc/ssh/sshd_config -p wa -k ssh_config
-w /etc/fail2ban/ -p wa -k f2b_cfg
-w /etc/systemd/ -p wa -k systemd_cfg
-w /usr/local/bin/ -p wa -k usr_local_bin
-w /usr/local/sbin/ -p wa -k usr_local_sbin
-w /boot/ -p wa -k boot_integrity

# Optional web configs/content (uncomment if applicable)
# -w /var/www/ -p wa -k web_root

# We intentionally do not set immutable (-e 2) to avoid locking rules at runtime.
EOF

# Load rules and ensure auditd is enabled
if command -v augenrules >/dev/null 2>&1; then
  augenrules --load
else
  systemctl restart auditd || true
fi
systemctl enable --now auditd || true

# Reboot marker for your suite (optional)
install -d -m 0755 /run/billspi || true
touch /run/billspi/reboot-required

echo "Integrity/audit hardening complete."
exit 0

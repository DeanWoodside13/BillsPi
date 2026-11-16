#!/usr/bin/env bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
set -euo pipefail

# Set your desired username and password here (password is hashed with SHA-512 crypt).
PI_USER="pi"                    # <== change if you want a different user
PI_PASS_PLAIN="changeme"        # <== change; will be hashed below

# Hash before touching the card. Ubuntu's essential perl-base reads raw bytes,
# including newlines, without placing the password in any external command's argv.
PI_PASS_SALT="$(openssl rand -base64 12 | tr '+' '.')"
PI_PASS_HASH_CODE='
  binmode STDIN, ":raw" or die "Cannot read Pi password: $!\n";
  local $/;
  $! = 0;
  my $password = <STDIN>;
  defined($password) && length($password) && !$!
    or die "Cannot hash an empty or unreadable Pi password\n";
  my $salt = shift;
  defined($salt) && $salt =~ /\A[.\/0-9A-Za-z]{16}\z/
    or die "Invalid password salt\n";
  warn "Warning: truncating password to 256 characters\n" if length($password) > 256;
  my $setting = "\$6\$" . $salt . "\$";
  my $hash = crypt(substr($password, 0, 256), $setting);
  defined($hash) && $hash =~ /\A\Q$setting\E[.\/0-9A-Za-z]{86}\z/
    or die "SHA-512 password hashing failed\n";
  print "$hash\n" or die "Cannot write password hash: $!\n";
'
PI_PASS_HASH="$(printf '%s' "$PI_PASS_PLAIN" | /usr/bin/perl -e "$PI_PASS_HASH_CODE" "$PI_PASS_SALT")"

sudo umount /dev/sda1 2>/dev/null || true
sudo umount /dev/sda2 2>/dev/null || true

sudo dd if=/dev/zero of=/dev/sda bs=1M count=100
sync

# Let the kernel notice the new partition table
sudo partprobe /dev/sda || true
sleep 1

xzcat 2026-10-06-raspios-trixie-arm64-lite.img.xz | sudo dd of=/dev/sda bs=4M status=progress conv=fsync

sync

# Let the kernel notice the new partition table
sudo partprobe /dev/sda || true
sleep 1

# --- MOUNT & VERIFY (must happen AFTER flashing) ---
sudo umount /mnt/pi-boot 2>/dev/null || true
sudo umount /mnt/pi-root 2>/dev/null || true
sudo umount /media/dean/bootfs 2>/dev/null || true
sudo umount /media/dean/rootfs 2>/dev/null || true

sudo mkdir -p /mnt/pi-boot /mnt/pi-root
sudo mount /dev/sda1 /mnt/pi-boot
sudo mount /dev/sda2 /mnt/pi-root






# --- BEGIN: ensure unattended first normal boot (skip wizard) ---
# Create /boot/userconf.txt with the preflight-validated "user:hash".
printf '%s:%s\n' "${PI_USER}" "${PI_PASS_HASH}" | sudo tee /mnt/pi-boot/userconf.txt >/dev/null

# Enable SSH on first boot
sudo touch /mnt/pi-boot/ssh
# --- END: ensure unattended first normal boot (skip wizard) ---









# Hard verify we're writing to the real card
BOOT_SRC="$(findmnt -n -o SOURCE /mnt/pi-boot || true)"
ROOT_SRC="$(findmnt -n -o SOURCE /mnt/pi-root || true)"
if [ "$BOOT_SRC" != "/dev/sda1" ] || [ "$ROOT_SRC" != "/dev/sda2" ]; then
  echo "ERROR: mount mismatch. /mnt/pi-boot=[$BOOT_SRC] /mnt/pi-root=[$ROOT_SRC]" >&2
  exit 1
fi

# Optional sanity: the card's OS release should print here
sudo sed -n '1,4p' /mnt/pi-root/etc/os-release 2>/dev/null || true

sudo install -d -m 0755 /mnt/pi-root/usr/local/sbin
sudo install -d -m 0755 /mnt/pi-root/usr/local/lib/billspi
sudo install -d -m 0755 /mnt/pi-root/usr/local/lib/billspi/phases

ZIP=~/Desktop/Pi/billspi-1.0.0.53.zip
sudo unzip -o "$ZIP" -d /mnt/pi-root/usr/local/lib/billspi

# sudo install -m 0755 /mnt/pi-root/usr/local/lib/billspi/billspi-runner /mnt/pi-root/usr/local/sbin/billspi-runner 2>/dev/null || sudo install -m 0755 /mnt/pi-root/usr/local/lib/billspi/**/billspi-runner /mnt/pi-root/usr/local/sbin/billspi-runner 2>/dev/null || true

# Install runner to PATH on the CARD (robust, no '**' glob)
if [ -f /mnt/pi-root/usr/local/lib/billspi/billspi-runner ]; then
  sudo install -m 0755 /mnt/pi-root/usr/local/lib/billspi/billspi-runner \
                       /mnt/pi-root/usr/local/sbin/billspi-runner
else
  RUN_SRC="$(sudo find /mnt/pi-root/usr/local/lib/billspi -maxdepth 3 -type f -name billspi-runner -print -quit)"
  [ -n "$RUN_SRC" ] || { echo "ERROR: billspi-runner not found under /usr/local/lib/billspi"; exit 1; }
  sudo install -m 0755 "$RUN_SRC" /mnt/pi-root/usr/local/sbin/billspi-runner
fi

sudo chmod 0755 /mnt/pi-root/usr/local/sbin/billspi-runner || true
sudo chmod -R 0755 /mnt/pi-root/usr/local/lib/billspi || true

sudo install -d -m 0755 /mnt/pi-root/etc/systemd/system
sudo install -d -m 0755 /mnt/pi-root/etc/systemd/system/multi-user.target.wants

# Preserve the first Pi boot's journal before the runner or any phase starts.
sudo install -d -m 0755 /mnt/pi-root/etc/systemd/journald.conf.d
sudo install -d -m 2755 /mnt/pi-root/var/log/journal
sudo tee /mnt/pi-root/etc/systemd/journald.conf.d/99-billspi-install.conf >/dev/null <<'JOURNAL'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=200M
SystemKeepFree=50M
SystemMaxFileSize=50M
RuntimeMaxUse=64M
JOURNAL
sudo chmod 0644 /mnt/pi-root/etc/systemd/journald.conf.d/99-billspi-install.conf

sudo tee /mnt/pi-root/etc/systemd/system/billspi-setup.service >/dev/null <<'UNIT'
[Unit]
Description=Bill's Pi setup orchestrator
Wants=network-online.target
After=network-online.target dhcpcd.service keyboard-setup.service getty.target userconfig.service
ConditionPathExists=!/var/lib/billspi/setup.done

[Service]
Type=oneshot
TimeoutStartSec=0
SuccessExitStatus=200
ExecStart=/usr/local/sbin/billspi-runner
WorkingDirectory=/usr/local/lib/billspi
StateDirectory=billspi
Environment=DEBIAN_FRONTEND=noninteractive
Environment=APT_LISTCHANGES_FRONTEND=none
StandardOutput=journal+console
StandardError=journal+console
# Preserve bursts of installer output; other services retain their journal limits.
LogRateLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
UNIT
sudo chmod 0644 /mnt/pi-root/etc/systemd/system/billspi-setup.service

# sudo ln -sfn /etc/systemd/system/billspi-setup.service /mnt/pi-root/etc/systemd/system/multi-user.target.wants/billspi-setup.service
# Enable the unit on the CARD (create wants/ and the symlink, then verify)
sudo install -d -m 0755 /mnt/pi-root/etc/systemd/system/multi-user.target.wants

# sudo ln -sfn /etc/systemd/system/billspi-setup.service  /mnt/pi-root/etc/systemd/system/multi-user.target.wants/billspi-setup.service


# Enable the unit on the CARD (create wants/ and the symlink, then verify)
sudo install -d -m 0755 /mnt/pi-root/etc/systemd/system/multi-user.target.wants
set -x
sudo ln -sfn /etc/systemd/system/billspi-setup.service \
  /mnt/pi-root/etc/systemd/system/multi-user.target.wants/billspi-setup.service
set +x
# immediate proof the link exists on the card
ls -l /mnt/pi-root/etc/systemd/system/multi-user.target.wants/billspi-setup.service >/dev/null || {
  echo "ERROR: failed to create enable symlink on the card" >&2
  echo "--- wants/ directory listing for diagnostics ---"
  ls -la /mnt/pi-root/etc/systemd/system/multi-user.target.wants || true
  echo "--- system dir listing ---"
  ls -la /mnt/pi-root/etc/systemd/system || true
  exit 1
}


ls -l /mnt/pi-root/etc/systemd/system/multi-user.target.wants/billspi-setup.service >/dev/null || {
  echo "ERROR: failed to create enable symlink on the card" >&2; exit 1; }


# --- VERIFY critical files are on the CARD (symlink-safe) ---
set -e

# 1) Unit file must exist as a regular file on the card
[ -f /mnt/pi-root/etc/systemd/system/billspi-setup.service ] || {
  echo "ERROR: missing unit file on the card" >&2; exit 1; }

# 2) Enable symlink must exist on the card, and point to the expected target
LINK=/mnt/pi-root/etc/systemd/system/multi-user.target.wants/billspi-setup.service
[ -L "$LINK" ] || { echo "ERROR: missing enable symlink on the card" >&2; exit 1; }
LINK_TGT="$(readlink "$LINK" || true)"
[ "$LINK_TGT" = "/etc/systemd/system/billspi-setup.service" ] || {
  echo "ERROR: enable symlink points to '$LINK_TGT' (expected '/etc/systemd/system/billspi-setup.service')" >&2
  exit 1; }

# 3) Runner must be present and executable on the card
[ -x /mnt/pi-root/usr/local/sbin/billspi-runner ] || {
  echo "ERROR: runner not found or not executable on the card" >&2; exit 1; }

set +e


sync
sudo umount /mnt/pi-boot || true
sudo umount /mnt/pi-root || true

udisksctl power-off -b /dev/sda
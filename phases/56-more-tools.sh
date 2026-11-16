#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
# ALERT / WARNING / FATAL: enhance the fd/ripgrep with an alias.  Make it alias for 'find' ?  Use multi-core ?
#
# ALIAS ONE OF THESE: ripgrep (rg), fd-find (fdfind) -- fast search/find (huge QoL boost)
# OPTIONAL: net-tools , make this optional in your config files.
# ALIAS ONE OF THESE: ripgrep (rg), fd-find (fdfind) - fast search/find (huge QoL boost)

set -Eeuo pipefail
IFS=$'\n\t'

# Honor wrapper from 01-system-prerequisites.sh when present
case ":${PATH}:" in *:/usr/local/sbin:*) ;; *) export PATH="/usr/local/sbin:/usr/local/bin:${PATH}";; esac

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none
export LC_ALL=C LANG=C

# Common apt options (no downloads here; install strictly from cache)
APT_OPTS=(
  -y
  -o Dpkg::Options::="--force-confdef"
  -o Dpkg::Options::="--force-confold"
  -o APT::Install-Recommends=0
  -o APT::Install-Suggests=0
)
APT_DL_POLICY=(--no-install-recommends --no-download)

# -----------------------------
# Packages (choose rg/fd below)
# -----------------------------
# fd-find and ripgrep listed side-by-side; comment out the one you don't want.
PKG=(
  ca-certificates
  git
  iperf3
  jq
  needrestart
  nmap
  ntfs-3g
  parted
  python3-venv
  traceroute
#  v4l-utils
  vim
  watchdog
  fd-find    # keep this or...
  ripgrep    # ...this (comment one out if undesired)
)

# Reuse persistent archives; fetch only missing or newly selected package versions.
apt-get update
apt-get "${APT_OPTS[@]}" --download-only --no-install-recommends install "${PKG[@]}"
# Install from the populated archive cache.
apt-get "${APT_OPTS[@]}" install "${APT_DL_POLICY[@]}" "${PKG[@]}"

# Preserve the packaged keepalive handoff on ordinary stops, but not during shutdown.
# Do not start wd_keepalive into systemd's shutdown transaction.
install -d -m 0755 /etc/systemd/system/watchdog.service.d
cat >/etc/systemd/system/watchdog.service.d/90-billspi-shutdown.conf <<'EOF'
[Service]
ExecStopPost=
ExecStopPost=/bin/sh -c '[ "$${run_wd_keepalive}" != 1 ] || [ "$$(/usr/bin/systemctl is-system-running 2>/dev/null)" = stopping ]'
EOF
chmod 0644 /etc/systemd/system/watchdog.service.d/90-billspi-shutdown.conf
systemctl daemon-reload

# -----------------------------
# NTFS (ntfs-3g) guidance
# -----------------------------
mkdir -p /mnt/windows
if ! grep -q "^# NTFS template (billspi)" /etc/fstab; then
  cat >> /etc/fstab <<'EOF'
# NTFS template (billspi)
# To mount a Windows NTFS volume, replace <UUID> with the volume UUID from blkid(8).
# Example:
# UUID=<UUID>  /mnt/windows  ntfs-3g  defaults,uid=1000,gid=1000,umask=022,big_writes  0  0
#
# Notes:
# - Use `blkid` to find the correct UUID.
# - `big_writes` improves throughput on NTFS-3g.
# - Remove this comment block when you finalize your mount.
EOF
fi

# -----------------------------
# needrestart policy
# -----------------------------
install -d -m 0755 /etc/needrestart
cat >/etc/needrestart/needrestart.conf <<'EOF'
$nrconf{restart} = 'a';   # auto-restart services (no prompts)
$nrconf{kernelhints} = 1; # warn if kernel upgrade requires reboot
$nrconf{kernelfilter} = qr(vmlinuz-.*-2712$);
EOF

# -----------------------------
# fd/ripgrep ergonomics
# -----------------------------
# - Debian names fd as "fdfind"; provide a friendly "fd" if not already present.
# - Drop aliases unless 55 already provided them.
if command -v fdfind >/dev/null 2>&1 && [ ! -e /usr/local/bin/fd ]; then
  ln -sf /usr/bin/fdfind /usr/local/bin/fd
fi

ALIASES_FILE="/etc/profile.d/56-more-tools-aliases.sh"
if [ ! -f "$ALIASES_FILE" ]; then
  cat > "$ALIASES_FILE" <<'EOF'
# shellcheck shell=sh
# Added by 56-more-tools.sh
# Prefer multi-core friendly defaults; ripgrep auto-parallelizes, fd exposes --threads.
# If 55 already defined these, this file will be ignored if shell sources earlier aliases first.
if command -v rg >/dev/null 2>&1; then
  alias rg='rg --hidden --smart-case'
fi
if command -v fdfind >/dev/null 2>&1; then
  # Use fd if available (Debian binary is fdfind). Threads default to #CPU; be explicit.
  alias fd='fdfind --hidden --follow --exclude .git --threads=$(nproc)'
fi
EOF
  chmod 0644 "$ALIASES_FILE"
fi

# -----------------------------
# Git + SSH signing (ed25519)
# -----------------------------
# Use the invoking user when run via sudo; else current user.
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

# Optional human identity: set these env vars before running to avoid prompts.
if [ -n "${GIT_USER_NAME:-}" ]; then
  sudo -u "$TARGET_USER" git config --global user.name "$GIT_USER_NAME" || true
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
  sudo -u "$TARGET_USER" git config --global user.email "$GIT_USER_EMAIL" || true
fi

# Ensure an ed25519 key exists for SSH signing
SSH_DIR="$TARGET_HOME/.ssh"
PUB="$SSH_DIR/id_ed25519.pub"
KEY="$SSH_DIR/id_ed25519"
if [ ! -f "$PUB" ]; then
  # install -d -m 0700 "$SSH_DIR"
  install -d -m 0700 -o "$TARGET_USER" -g "$TARGET_USER" "$SSH_DIR"
  sudo -u "$TARGET_USER" ssh-keygen -t ed25519 -N '' -f "$KEY" -C "${GIT_USER_EMAIL:-$TARGET_USER@$(hostname -f 2>/dev/null || hostname)}" >/dev/null
fi

# Wire Git to use SSH for signing; point to the public key; optionally sign commits by default.
sudo -u "$TARGET_USER" git config --global gpg.format ssh
sudo -u "$TARGET_USER" git config --global user.signingkey "$PUB"
if [ "${GIT_SIGN_ALL:-1}" != "0" ]; then
  sudo -u "$TARGET_USER" git config --global commit.gpgsign true
fi

touch /run/billspi/reboot-required
exit 0

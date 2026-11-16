#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

apt-get -y autoremove --purge || true
# Purge any residual-config packages (dpkg state 'rc') left behind by earlier purges
dpkg -l | awk '/^rc/ {print $2}' | xargs -r dpkg -P || true
apt-get -y clean || true

## Restore ldconfig so any pending triggers can run it for real
#if dpkg-divert --list /sbin/ldconfig 2>/dev/null | grep -q .; then
## if dpkg-divert --list /sbin/ldconfig >/dev/null 2>&1; then
#  rm -f /sbin/ldconfig
#  dpkg-divert --quiet --rename --remove /sbin/ldconfig || true
#fi

# Restore ldconfig so any pending triggers can run it for real (handle usrmerge paths)
for p in /sbin/ldconfig /usr/sbin/ldconfig; do
  if dpkg-divert --list "$p" 2>/dev/null | grep -q .; then
    rm -f "$p" || true
    dpkg-divert --quiet --rename --remove "$p" || true
  fi
done


# If we deferred dpkg triggers, run them now exactly once (still under eatmydata)
dpkg --triggers-only --pending || true
rm -f /etc/apt/apt.conf.d/99notriggers || true

# Final safety: refresh the dynamic linker cache after running deferred triggers.
# Harmless no-op if already current; ignore errors to keep cleanup non-fatal.
/sbin/ldconfig || true


# We keep /etc/initramfs-tools/conf.d/99zstd-fast so future kernel updates also compress fast. No action needed here.  Don't uncomment for now!
## Revert initramfs compression to distro defaults (install-only optimization was used already).
## Remove after deferred triggers so the final rebuild already got zstd@3 + threads.
# Revert to distro defaults (install-only optimization was used already).
#rm -f /etc/initramfs-tools/conf.d/99zstd-fast || true

# Remove temporary apt config knobs used for speed during provisioning
rm -f /etc/apt/apt.conf.d/99no-pkgcache || true

# Restore update-initramfs (if we diverted it) and run it once only when the system actually uses initramfs
if [ -f /var/lib/billspi/diverted-update-initramfs ] && \
   dpkg-divert --list /usr/sbin/update-initramfs 2>/dev/null | grep -q .; then
  rm -f /usr/sbin/update-initramfs
  dpkg-divert --quiet --rename --remove /usr/sbin/update-initramfs || true

  # Re-detect usage (same logic as earlier, but lightweight)
  _use_initramfs=0
  if [ -f /etc/initramfs-tools/update-initramfs.conf ] && \
     grep -Eq '^\s*update_initramfs\s*=\s*yes\b' /etc/initramfs-tools/update-initramfs.conf; then
    _use_initramfs=1
  fi
  if ls /boot/initrd.img-* /boot/firmware/initrd.img-* >/dev/null 2>&1; then
    _use_initramfs=1
  fi
  if command -v raspi-config >/dev/null 2>&1; then
    if raspi-config nonint get_initramfs 2>/dev/null | grep -qx '1'; then
      _use_initramfs=1
    fi
  fi

  # Run once only if relevant, otherwise skip to preserve end state
  if [ "$_use_initramfs" = "1" ]; then
    update-initramfs -u -k all || true
  fi
  rm -f /var/lib/billspi/diverted-update-initramfs || true
fi



# Remove eatmydata now that provisioning is over
# Keep eatmydata purge before wrapper-removal, and after the removals/clean so that they benefit from eatmydata (slightly faster).
# The result is an identical end state.
apt-get -y purge eatmydata || true

# Restore dpkg defaults
rm -f /etc/dpkg/dpkg.cfg.d/01speed || true
# Re-enable service (re)starts for normal operation
rm -f /usr/sbin/policy-rc.d || true
systemctl daemon-reexec || true
# Restore APT defaults (remove if you prefer to KEEP faster updates)
rm -f /etc/apt/apt.conf.d/99nolang || true
rm -f /etc/apt/apt.conf.d/99speed || true

# Remove provisioning-only APT sandbox override (restore default _apt sandbox)
rm -f /etc/apt/apt.conf.d/02billspi-sandbox-root /var/lib/billspi/apt-sandbox-root.stamp || true

# Restore stock APT behavior by removing our zstd compression preference
rm -f /etc/apt/apt.conf.d/02zstd || true

# Remove IPv4-forcing knobs if present
rm -f /etc/apt/apt.conf.d/03forceipv4 || true
rm -f /usr/local/bin/curl /usr/local/bin/curl.orig || true



# Remove IPv4-enforcing download wrappers unless the user opts to keep them
# Set BILLSPI_KEEP_NET_WRAPPERS=1 to retain post-install.
if [ "${BILLSPI_KEEP_NET_WRAPPERS:-0}" != "1" ]; then
  for t in wget aria2c; do
    p="/usr/local/bin/$t"
    # Only remove if it's our small shell wrapper (defensive: match shebang + our IPv6 logic)
    if [ -f "$p" ] && [ ! -L "$p" ] \
       && head -n1 "$p" | grep -qE '^#! */bin/sh' \
       && grep -qE 'Force IPv4|ipv6.*(broken|unusable)|--inet4-only|--disable-ipv6' "$p"
    then
      rm -f "$p"
    fi
  done
fi

# Optionally drop the v4-force markers too (again, only if not asked to keep)
if [ "${BILLSPI_KEEP_NET_WRAPPERS:-0}" != "1" ]; then
  rm -f /var/lib/billspi/ipv6-broken.stamp \
        /etc/apt/apt.conf.d/03forceipv4 || true
fi




## Cleanup: remove provisioning-only APT setting that preferred gzip indexes (set in 01-system-prerequisites.sh) to restore distro defaults.
#rm -f /etc/apt/apt.conf.d/99gz || true
# Cleanup: restore default APT PDiffs behavior
rm -f /etc/apt/apt.conf.d/99nopdiffs || true

# Remove apt/dpkg wrappers created for provisioning (safe even if missing)
rm -f /usr/local/sbin/apt-get /usr/local/sbin/dpkg /usr/local/sbin/apt /usr/local/bin/apt-get  /usr/local/bin/dpkg  /usr/local/bin/apt  || true


# Restore persistent journaling before flushing the current boot's RAM journal.
mkdir -p /var/log/journal
rm -f /etc/systemd/journald.conf.d/99-volatile.conf /etc/systemd/journald.conf.d/99volatile.conf
systemctl restart systemd-journald
journalctl --flush

# Package archives remain on disk; apt-get clean above empties the cache.

# Return to this when you divert mandb, otherwise remove the block:
# (Only if you diverted mandb earlier)
# If 'mandb' was diverted during provisioning, restore and run it once
if dpkg-divert --list /usr/bin/mandb 2>/dev/null | grep -q .; then
# if dpkg-divert --list /usr/bin/mandb >/dev/null 2>&1; then
  rm -f /usr/bin/mandb
  dpkg-divert --quiet --local --rename --remove /usr/bin/mandb
  mandb -q || true
fi

# Cleanup: unmount provisioning-time tmpfs for APT lists so subsequent updates use disk (default behavior)
if [ "$(findmnt -n -o FSTYPE /var/lib/apt/lists)" = "tmpfs" ]; then
  umount /var/lib/apt/lists || true
fi

systemctl unmask apt-daily.timer apt-daily-upgrade.timer || true
systemctl enable apt-daily.timer apt-daily-upgrade.timer || true

# --- Restore mandb and arm the timer to rebuild off the critical path ---
if dpkg-divert --list /usr/bin/mandb 2>/dev/null | grep -q .; then
# if dpkg-divert --list /usr/bin/mandb >/dev/null 2>&1; then
  rm -f /usr/bin/mandb                         # remove our /bin/true symlink
  dpkg-divert --quiet --rename --remove /usr/bin/mandb || true
fi
# systemctl daemon-reload
# systemctl enable --now billspi-mandb.timer
systemctl daemon-reload || true
if systemctl list-unit-files --type=timer --all | grep -q '^billspi-mandb.timer'; then
  systemctl enable --now billspi-mandb.timer || true
fi



# ---- Restore original I/O settings and remove temp unit/state ----
BASE="$(cat /var/lib/billspi/blk/dev 2>/dev/null || true)"
if [ -z "$BASE" ]; then
  ROOT_DEV="$(readlink -f "$(findmnt -n -o SOURCE /)")"
  BASE="$(lsblk -no PKNAME "$ROOT_DEV" 2>/dev/null || true)"
fi

if [ -n "$BASE" ] && [ -d "/sys/block/$BASE/queue" ]; then
  BLK="/sys/block/$BASE"
  if [ -r /var/lib/billspi/blk/ra ]; then
    cat /var/lib/billspi/blk/ra > "$BLK/queue/read_ahead_kb" 2>/dev/null || true
  fi
  if [ -r /var/lib/billspi/blk/sched ] && [ -w "$BLK/queue/scheduler" ]; then
    ORIG="$(cat /var/lib/billspi/blk/sched)"
    echo "$ORIG" > "$BLK/queue/scheduler" 2>/dev/null || true
  fi
fi

systemctl disable --now billspi-io-fast.service 2>/dev/null || true
rm -f /etc/systemd/system/billspi-io-fast.service
systemctl daemon-reload || true
rm -rf /var/lib/billspi/blk


# Restore root mount atime mode if we flipped it
if [ -f /var/lib/billspi/noatime.stamp ]; then
  mount -o remount,relatime / || true
  rm -f /var/lib/billspi/noatime.stamp
fi

# If we disabled swap early and zram wasn't configured by phase 45, re-enable swap
if [ -f /var/lib/billspi/swapoff-early.stamp ]; then
  if ! swapon --noheadings --show=NAME | grep -qE '^/dev/zram[0-9]+'; then
    systemctl start dphys-swapfile 2>/dev/null || true
    swapon -a 2>/dev/null || true
  fi
  rm -f /var/lib/billspi/swapoff-early.stamp
fi

# Unmount /tmp tmpfs if we mounted it
if [ -f /var/lib/billspi/tmpfs-tmp.stamp ]; then
  # mountpoint -q /tmp && umount /tmp || true
  # mountpoint -q /tmp && umount -l /tmp || true
  if mountpoint -q /tmp; then
    if ! umount /tmp; then
      if mountpoint -q /tmp; then
        echo "WARN: /tmp is busy; lazy-unmounting" >&2
        umount -l /tmp || true
      fi
    fi
  fi
  rm -f /var/lib/billspi/tmpfs-tmp.stamp
fi

# Unmount /var/tmp tmpfs if we mounted it
if [ -f /var/lib/billspi/tmpfs-vartmp.stamp ]; then
  # mountpoint -q /var/tmp && umount /var/tmp || true
  # mountpoint -q /var/tmp && umount -l /var/tmp || true
  if mountpoint -q /var/tmp; then
    if ! umount /var/tmp; then
      if mountpoint -q /var/tmp; then
        echo "WARN: /var/tmp is busy; lazy-unmounting" >&2
        umount -l /var/tmp || true
      fi
    fi
  fi
  rm -f /var/lib/billspi/tmpfs-vartmp.stamp
fi

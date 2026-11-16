#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
# Script Name: install_script.sh
# Author: Dean Woodside
# Date: 2024-09-09
# Version: 1.0.0
# Description:
#   A brief description of what the script does. For example, this script
#   demonstrates how to use a header and provides a basic function.
#
# Usage:
#   How to use the script, any arguments it accepts, expected output, etc.
#   Example: ./example_script.sh [option1] [option2]
#
# Release Notes:
#   - 1.0.0: Initial release of the script with basic functionality.
#   - Next version notes or changes to come.
#
# Acknowledgment:
#   In memory of William John Woodside, the greatest coder I know.
#   November 27, 2021.
#
# Script starts here
echo "Bill's Pi, install script starting..."


#######################################################################################
# Performance enhancements to speed up installation (no change to end state)
#
# APT/dpkg speed & noninteractive defaults
# - Retries + HTTP timeout -> resilient networking on flaky/first-boot links
# - No PTY (Dpkg::Use-Pty=0) -> less CPU/context-switch churn on ARM
# - dpkg lock timeout -> tolerate brief lock holders (avoids apt-daily races)
# - Noninteractive conffiles -> keep existing or defaults (no prompts)
# - Disable APT hardlinking (APT::Cmd::Use-Hardlinking=0) ->
#     avoid extra inode/IO work on SD/overlay/tmpfs; hardlinks add cost but no benefit here
# - Keep downloaded .debs on disk across installation reboots; phase 70 cleans them.
#printf 'Acquire::Retries "3";\nAcquire::http::Timeout "30";\nDpkg::Use-Pty "0";\nDPkg::Lock::Timeout "600";\nAPT::Cmd::Use-Hardlinking "0";\nAPT::Keep-Downloaded-Packages "true";\nDPkg::Options { "--force-confdef"; "--force-confold"; };\n' >/etc/apt/apt.conf.d/99speed
install -D -m0644 /dev/stdin /etc/apt/apt.conf.d/99speed <<'EOF'
Acquire::Retries "3";
Acquire::http::Timeout "30";
Acquire::http::No-Cache "true";
Acquire::Queue-Mode "access";
APT::Keep-Downloaded-Packages "true";
APT::Cmd::Use-Hardlinking "0";
DPkg::Use-Pty "0";
DPkg::Lock::Timeout "600";
DPkg::Options { "--force-confdef"; "--force-confold"; };
EOF

# --- Provisioning-only: cut metadata writes by disabling atime updates on root ---
# Debian defaults to "relatime"; flip to "noatime" during heavy churn, then restore.
if findmnt -nr -o OPTIONS / | grep -qw relatime; then
  mount -o remount,noatime / || true
  install -D -m0644 /dev/null /var/lib/billspi/noatime.stamp
fi

# Prefer zstd APT index compression for a small 'apt update' speedup (falls back to xz/gz automatically)
install -D -m0644 /dev/stdin /etc/apt/apt.conf.d/02zstd <<'EOF'
Acquire::CompressionTypes::Order { "zstd"; "xz"; "gz"; };
EOF

# Run package triggers normally: later phases reboot before cleanup.

# Reduce apt update CPU/IO churn during provisioning
printf 'Dir::Cache::pkgcache ""; Dir::Cache::srcpkgcache "";\n' >/etc/apt/apt.conf.d/99no-pkgcache

# --- Provisioning-only: keep APT methods as root to reduce churn on tmpfs ---
SANDBOX_FILE="/etc/apt/apt.conf.d/02billspi-sandbox-root"
SANDBOX_STAMP="/var/lib/billspi/apt-sandbox-root.stamp"

if [ ! -f "$SANDBOX_FILE" ]; then
  install -D -m 0644 /dev/null "$SANDBOX_FILE"
  cat >"$SANDBOX_FILE" <<'EOF'
/* BILLSPI provisioning-only override: revert in 70-cleanup.sh */
APT::Sandbox::User "root";
EOF
  install -D -m 0644 /dev/null "$SANDBOX_STAMP"
fi
# --- end provisioning-only sandbox override ---

# Do not divert update-initramfs across the runner's intermediate reboots.

# Keep the persistent journaling configured by PrepBill throughout provisioning.

# --- BEGIN: set hostname (ultra-minimal) ---
PI_HOSTNAME="BillsPi"
STATIC_HOSTNAME="$(printf '%s' "$PI_HOSTNAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
printf '%s\n' "$STATIC_HOSTNAME" > /etc/hostname
hostnamectl set-hostname "$STATIC_HOSTNAME" 2>/dev/null || hostname "$STATIC_HOSTNAME"
hostnamectl set-hostname "$PI_HOSTNAME" --pretty 2>/dev/null || true
sed -i -E "s/^(127\.0\.1\.1\s+).*/\1${STATIC_HOSTNAME}/" /etc/hosts || echo -e "127.0.1.1\t${STATIC_HOSTNAME}" >> /etc/hosts
# --- END: set hostname ---

# ---- Temporary fast I/O during install: save originals, apply faster settings ----
install -d -m0755 /var/lib/billspi/blk

# Find the base block device for /
ROOT_DEV="$(readlink -f "$(findmnt -n -o SOURCE /)")"           # e.g., /dev/mmcblk0p2, /dev/nvme0n1p2, /dev/sda2
BASE_DEV="$(lsblk -no PKNAME "$ROOT_DEV" 2>/dev/null || true)"  # e.g., mmcblk0, nvme0n1, sda

# Fallback if PKNAME is empty (uncommon, but be safe)
if [ -z "$BASE_DEV" ]; then
  BN="$(basename "$ROOT_DEV")"
  case "$BN" in
    mmcblk*p[0-9]*|nvme*n*[0-9]*p[0-9]*)  BASE_DEV="${BN%%p*}" ;;   # mmcblk0p2→mmcblk0, nvme0n1p2→nvme0n1
    sd*[0-9]*)                            BASE_DEV="${BN%%[0-9]*}" ;;# sda2→sda
    *)                                    BASE_DEV="$BN" ;;
  esac
fi

if [ -n "$BASE_DEV" ] && [ -d "/sys/block/$BASE_DEV/queue" ]; then
  BLK="/sys/block/$BASE_DEV"

  # Save originals once
  if [ ! -f /var/lib/billspi/blk/dev ]; then
    printf '%s\n' "$BASE_DEV" > /var/lib/billspi/blk/dev
  fi
  [ -f /var/lib/billspi/blk/ra ] || cat "$BLK/queue/read_ahead_kb" > /var/lib/billspi/blk/ra 2>/dev/null || true
  if [ -r "$BLK/queue/scheduler" ] && [ ! -f /var/lib/billspi/blk/sched ]; then
    awk '{for(i=1;i<=NF;i++) if ($i ~ /^\[.*\]$/){gsub(/[\[\]]/,"",$i); print $i; exit}}' "$BLK/queue/scheduler" \
      > /var/lib/billspi/blk/sched 2>/dev/null || true
  fi

  # Apply faster settings (best-effort)
  echo 4096 > "$BLK/queue/read_ahead_kb" 2>/dev/null || true
  if [ -w "$BLK/queue/scheduler" ]; then
    case "$BASE_DEV" in
      mmcblk*|sd*) echo mq-deadline > "$BLK/queue/scheduler" 2>/dev/null || true ;;
      nvme*)       echo none        > "$BLK/queue/scheduler" 2>/dev/null || true ;;
    esac
  fi
fi

# Re-apply on every boot during the install (removed in 70-cleanup.sh)
install -D -m0644 /dev/stdin /etc/systemd/system/billspi-io-fast.service <<'EOF'
[Unit]
Description=Temporarily speed up block I/O during installation
After=local-fs.target
ConditionPathExists=/var/lib/billspi/blk/dev

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'BASE="$$(cat /var/lib/billspi/blk/dev 2>/dev/null || true)"; [ -n "$$BASE" ] || exit 0; BLK="/sys/block/$$BASE"; if [ -d "$$BLK/queue" ]; then echo 4096 > "$$BLK/queue/read_ahead_kb" 2>/dev/null || true; if [ -w "$$BLK/queue/scheduler" ]; then case "$$BASE" in mmcblk*|sd*) echo mq-deadline > "$$BLK/queue/scheduler" 2>/dev/null || true ;; nvme*) echo none > "$$BLK/queue/scheduler" 2>/dev/null || true ;; esac; fi; fi'
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now billspi-io-fast.service


# Temporarily speed up dpkg's I/O:
# Why: Avoids extra fsyncs during unpack/configure--biggest cost on flash storage.
echo 'force-unsafe-io' >/etc/dpkg/dpkg.cfg.d/01speed
# Disable APT Translations (persistent unless you remove it later):
# Why: Stops downloading language index files; safe for servers.
printf 'Acquire::Languages "none";\n' >/etc/apt/apt.conf.d/99nolang

# There is a corresponding line in 70-cleanup.sh to undo this change below, uncomment it too if you keep this
# this is gzip for lists, reconsider if its positive or not
# make it an opt-in toggle for install, when you finish the project (maybe 10-20 configurable values)
## Prefer faster-to-decompress gzip indexes during provisioning
#cat >/etc/apt/apt.conf.d/99gz <<'EOF'
#Acquire::GzipIndexes "true";
#Acquire::CompressionTypes::Order { "gz"; };
#EOF

# Disable APT PDiffs during provisioning: full indexes are faster on fresh runs
echo 'Acquire::PDiffs "false";' >/etc/apt/apt.conf.d/99nopdiffs

systemctl stop apt-daily.timer apt-daily-upgrade.timer || true
systemctl mask apt-daily.timer apt-daily-upgrade.timer || true

# This is already set further up.  Don't duplicate.
## Make journald write to RAM (less I/O during install)
## Heavy logging to disk can add measurable latency on flash.
#mkdir -p /etc/systemd/journald.conf.d
#printf "[Journal]\nStorage=volatile\n" >/etc/systemd/journald.conf.d/99volatile.conf
#systemctl restart systemd-journald

# ---- Boost CPU for provisioning (effective immediately) ----
if [ -d /sys/devices/system/cpu ]; then
  for p in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
    [ -w "$p" ] && echo performance > "$p" 2>/dev/null || true
  done
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -w "$g" ] && echo performance > "$g" 2>/dev/null || true
  done
fi

# Persist across reboots with a package-free oneshot
install -D -m0644 /dev/stdin /etc/systemd/system/cpugovernor.service <<'EOF'
[Unit]
Description=Set CPU governor to performance
After=local-fs.target ondemand.service raspi-config.service
ConditionPathExistsGlob=/sys/devices/system/cpu/cpufreq/policy*/scaling_governor

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for p in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do [ -w "$p" ] && echo performance > "$p" || true; done; for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w "$g" ] && echo performance > "$g" || true; done'
ExecReload=/bin/sh -c 'for p in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do [ -w "$p" ] && echo performance > "$p" || true; done; for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w "$g" ] && echo performance > "$g" || true; done'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cpugovernor.service


# Block auto (re)starts of services during package installs to save time.
# dpkg will skip invoke-rc.d actions (exit status 101); we remove this in cleanup.
printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# Optional: pick a faster Debian mirror if helper tools are available
# Leaves Raspberry Pi/raspbian repos untouched. No-op if tools are missing.
if [ -f /etc/apt/sources.list ]; then
  CODENAME="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-bookworm}")"

  if command -v apt-select >/dev/null 2>&1; then
    # Try apt-select (quick). Outputs a candidate sources.list; we only use debian lines from it.
    if apt-select -t 5 -m -c "$CODENAME" -o /tmp/apt-select.list >/dev/null 2>&1; then
      # Extract first Debian deb line's base URL
      NEW_MIRROR="$(awk '$1=="deb" && $2 ~ /debian/ {print $2; exit}' /tmp/apt-select.list)"
      if [ -n "$NEW_MIRROR" ]; then
        sed -i.bak -E "s|^(deb\\s+)http(s)?://deb\\.debian\\.org/debian|\\1${NEW_MIRROR}|g" /etc/apt/sources.list || true
      fi
    fi
  elif command -v netselect-apt >/dev/null 2>&1; then
    # Fallback: netselect-apt (slower). Generate candidate list and apply the first Debian line.
    if netselect-apt -n -o /tmp/debian-sources.list "$CODENAME" >/dev/null 2>&1; then
      NEW_MIRROR="$(awk '$1=="deb" && $2 ~ /debian/ {print $2; exit}' /tmp/debian-sources.list)"
      if [ -n "$NEW_MIRROR" ]; then
        sed -i.bak -E "s|^(deb\\s+)http(s)?://deb\\.debian\\.org/debian|\\1${NEW_MIRROR}|g" /etc/apt/sources.list || true
      fi
    fi
    else
    # Lightweight by-country fallback (no extra packages). We only switch Debian lines
    # if a country-specific mirror both resolves and serves the current codename.
    CC="$(printf '%s' "${LC_ALL:-${LANG:-}}" | awk -F'[_.@]' '/_/ {print toupper($2)}')"

    # Optional: very fast external check (1s) if CC not found from locale.
    if [ -z "$CC" ] && command -v curl >/dev/null 2>&1; then
      CC="$(curl -fsSL --max-time 1 https://ifconfig.co/country-iso 2>/dev/null | tr -d '\r\n' | tr '[:lower:]' '[:upper:]' | head -c2 || true)"
    fi

    if [ -n "$CC" ]; then
      CAND_HOST="ftp.${CC}.debian.org"

      # Host must resolve; otherwise bail quietly.
      if getent hosts "$CAND_HOST" >/dev/null 2>&1; then
        SCHEME="https"
        # Prefer https, fall back to http if the Release file isn't reachable quickly.
        if command -v curl >/dev/null 2>&1; then
          if ! curl -Is --max-time 1 "${SCHEME}://${CAND_HOST}/debian/dists/${CODENAME}/Release" >/dev/null 2>&1; then
            SCHEME="http"
            curl -Is --max-time 1 "${SCHEME}://${CAND_HOST}/debian/dists/${CODENAME}/Release" >/dev/null 2>&1 || SCHEME=""
          fi
        fi

        if [ -n "$SCHEME" ]; then
          NEW_MIRROR="${SCHEME}://${CAND_HOST}/debian"
          # Only rewrite Debian lines that currently use deb.debian.org
          sed -i.bak -E "s|^(deb\\s+)http(s)?://deb\\.debian\\.org/debian|\\1${NEW_MIRROR}|g" /etc/apt/sources.list || true
        fi
      fi
    fi

  fi
fi


# Optional: pick a faster *Raspbian* mirror if any raspbian lines are present
# (Does NOT touch archive.raspberrypi.com; that's CDN-backed.)
if grep -RqsE 'https?://[^ ]*/raspbian' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
  # Require curl for probing; skip silently if absent
  if command -v curl >/dev/null 2>&1; then
    CODENAME="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-bookworm}")"
    TEST_PATH="dists/${CODENAME}/InRelease"

    # Try to infer a country code from locale (fallback to blank)
    CC="$(printf '%s' "${LC_ALL:-${LANG:-}}" | awk -F'[_.@]' '/_/ {print toupper($2)}')"

    # Candidate mirrors by region (+ the default director). Tweak as desired.
    CANDIDATES="$(cat <<'CAND'
https://raspbian.raspberrypi.org/raspbian
https://mirror.umd.edu/raspbian/raspbian
https://ftp.osuosl.org/pub/raspbian/raspbian
https://mirror.csclub.uwaterloo.ca/raspbian/raspbian
https://mirrorservice.org/sites/archive.raspbian.org/raspbian
https://ftp.acc.umu.se/mirror/raspbian/raspbian
CAND
)"

    case "$CC" in
      US|CA)
        CANDIDATES="$(printf '%s\n' \
          https://raspbian.raspberrypi.org/raspbian \
          https://mirror.umd.edu/raspbian/raspbian \
          https://ftp.osuosl.org/pub/raspbian/raspbian \
          https://mirror.csclub.uwaterloo.ca/raspbian/raspbian)"
        ;;
      GB|IE|FR|DE|NL|SE|NO|DK|CH|AT|BE|PL|CZ|ES|IT)
        CANDIDATES="$(printf '%s\n' \
          https://raspbian.raspberrypi.org/raspbian \
          https://mirrorservice.org/sites/archive.raspbian.org/raspbian \
          https://ftp.acc.umu.se/mirror/raspbian/raspbian)"
        ;;
    esac

    best_url=""
    best_t=9.0

    # Honor your IPv4-forcing marker so probes don't hang on AAAA
    CURL_IPOPT=""
    [ -f /etc/apt/apt.conf.d/03forceipv4 ] && CURL_IPOPT="-4"

    for base in $CANDIDATES; do
      u="${base%/}/$TEST_PATH"
      # Try HEAD, then a 1-byte GET; both measure TTFB, cap at 2s
      t=$(curl $CURL_IPOPT -fsS --head --max-time 2 -w '%{time_starttransfer}\n' -o /dev/null "$u" 2>/dev/null \
          || curl $CURL_IPOPT -fsS --range 0-0 --max-time 2 -w '%{time_starttransfer}\n' -o /dev/null "$u" 2>/dev/null \
          || printf '9')
      # Update best in the *current* shell (no subshell)
      if awk "BEGIN{exit !($t+0 < $best_t+0)}"; then
        best_url="$base"
        best_t="$t"
      fi
    done

    # Find the current raspbian base URL (handles optional [opts] after 'deb')
    current_base="$(
      awk '
        $1 ~ /^deb(-src)?$/ {
          for (i=2; i<=NF; i++) if ($i ~ /^https?:\/\/.*raspbian(\/|$)/) { print $i; exit }
        }
      ' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
    )"

    if [ -n "$best_url" ] && [ -n "$current_base" ] && [ "$best_url" != "$current_base" ]; then
      cur_t=$(curl $CURL_IPOPT -fsS --head --max-time 2 -w '%{time_starttransfer}\n' -o /dev/null \
                "${current_base%/}/$TEST_PATH" 2>/dev/null \
              || curl $CURL_IPOPT -fsS --range 0-0 --max-time 2 -w '%{time_starttransfer}\n' -o /dev/null \
                "${current_base%/}/$TEST_PATH" 2>/dev/null \
              || printf '9')
      # Switch only if improvement ≥ 100ms to avoid churn
      if awk "BEGIN{exit !($cur_t+0 - $best_t+0 > 0.10)}"; then
        # Replace URLs in both 'deb' and 'deb-src' lines; handle optional [opts]
        sed -i.bak -E \
          -e "s|^(deb[[:space:]]+(\\[[^]]*\\][[:space:]]+)?)(https?://[^ ]*/raspbian)|\\1${best_url%/}|g" \
          -e "s|^(deb-src[[:space:]]+(\\[[^]]*\\][[:space:]]+)?)(https?://[^ ]*/raspbian)|\\1${best_url%/}|g" \
          /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
      fi
    fi
  fi
fi




install -D -m 0755 /dev/stdin /usr/local/bin/wget <<'EOF'
#!/bin/sh
# Force IPv4 when IPv6 was flagged as unusable.
force=0
[ -f /etc/apt/apt.conf.d/03forceipv4 ] && force=1
[ -e /usr/local/bin/curl.orig ] && force=1
[ -f /var/lib/billspi/ipv6-broken.stamp ] && force=1
[ "${BILLSPI_FORCE_V4:-}" = "1" ] && force=1

# If caller explicitly asked for -4/-6, respect it.
if [ "$force" -eq 1 ]; then
  for a in "$@"; do
    case "$a" in
      -4|--inet4-only|-6|--inet6-only) force=0; break;;
    esac
  done
fi

if [ "$force" -eq 1 ]; then
  exec /usr/bin/wget --inet4-only "$@"
else
  exec /usr/bin/wget "$@"
fi
EOF


install -D -m 0755 /dev/stdin /usr/local/bin/aria2c <<'EOF'
#!/bin/sh
# Force IPv4 when IPv6 was flagged as unusable.
force=0
[ -f /etc/apt/apt.conf.d/03forceipv4 ] && force=1
[ -e /usr/local/bin/curl.orig ] && force=1
[ -f /var/lib/billspi/ipv6-broken.stamp ] && force=1
[ "${BILLSPI_FORCE_V4:-}" = "1" ] && force=1

# If forcing v4 and caller didn't set an IPv6 toggle, add --disable-ipv6.
if [ "$force" -eq 1 ]; then
  for a in "$@"; do
    case "$a" in
      --disable-ipv6|--disable-ipv6=*|--enable-ipv6|--enable-ipv6=*) have=1; break;;
    esac
  done
  if [ -z "${have:-}" ]; then
    exec /usr/bin/aria2c --disable-ipv6=true "$@"
  fi
fi

exec /usr/bin/aria2c "$@"
EOF


# Ensure only one UTF-8 locale is enabled; generate it only if missing
L="${BILLSPI_LOCALE:-en_US.UTF-8}"
if ! locale -a 2>/dev/null | grep -qx "$L"; then
  # Comment out all enabled locales, then enable just $L
  sed -i 's/^[^#]/# &/' /etc/locale.gen
  printf '%s UTF-8\n' "$L" >> /etc/locale.gen
  # Generate only if we actually need to (use eatmydata if present)
  if command -v eatmydata >/dev/null 2>&1; then
    /usr/bin/eatmydata locale-gen --keep-existing
  else
    locale-gen --keep-existing
  fi
fi
update-locale LANG="$L"


# Install + enable eatmydata (affects child processes only during scripts):
# Why: Skips fsyncs; huge speedups on SD/USB install media.
# Wait for first-boot clock synchronization before APT checks repository signatures.
echo "Waiting up to 180 seconds for clock synchronization before APT..."
if ! timeout 180 bash -c 'until [ "$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)" = yes ]; do sleep 1; done'; then
  echo "ERROR: Clock synchronization was not confirmed within 180 seconds; refusing to run APT." >&2
  exit 1
fi
echo "Clock synchronization confirmed."
apt-get update
command -v eatmydata >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get -y install eatmydata

# Preload eatmydata for the remainder of this phase
for p in /usr/lib/aarch64-linux-gnu/libeatmydata.so /usr/lib/arm-linux-gnueabihf/libeatmydata.so /usr/lib/libeatmydata.so; do
  [ -r "$p" ] && export LD_PRELOAD="$p" && break
done

# Install aria2 (downloader used by apt-fast); apt-fast itself is vendored below (curl/wget + optional checksum)
DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install aria2

# --- Vendor apt-fast if it isn't available from repos ---
if ! command -v apt-fast >/dev/null 2>&1; then
  # 1) Offline, from repo (preferred if you ship it). Place a copy at one of these paths.
  for CAND in \
      /opt/billspi/vendor/apt-fast \
      /usr/local/src/billspi/vendor/apt-fast \
      /mnt/billspi/vendor/apt-fast \
      /root/billspi/vendor/apt-fast \
      /home/pi/billspi/vendor/apt-fast
  do
    if [ -r "$CAND" ]; then
      install -D -m 0755 "$CAND" /usr/local/sbin/apt-fast
      break
    fi
  done
fi

# Before using curl/wget fallback:
# [ -n "${APTFAST_SHA256:-}" ] || { echo "Refusing apt-fast network fetch without APTFAST_SHA256" >&2; exit 1; }
# if ! command -v apt-fast >/dev/null 2>&1; then
if [ -z "${APTFAST_SHA256:-}" ]; then
  echo "apt-fast not pre-staged; skipping network fetch and continuing with apt-get." >&2
elif ! command -v apt-fast >/dev/null 2>&1; then
  # 2) Online, pinned download from upstream (fill in a pinned tag/commit URL you trust)
  APTFAST_URL="${APTFAST_URL:-https://raw.githubusercontent.com/ilikenwf/apt-fast/master/apt-fast}"
  tmp="$(mktemp)"
  if command -v curl >/dev/null 2>&1; then
    # curl -fsSL "$APTFAST_URL" -o "$tmp" && install -D -m 0755 "$tmp" /usr/local/sbin/apt-fast
    # curl -fsSL -- "$APTFAST_URL" -o "$tmp" && echo "${APTFAST_SHA256}  $tmp" | sha256sum -c - && install -D -m0755 "$tmp" /usr/local/sbin/apt-fast
    if curl -fsSL -o "$tmp" -- "$APTFAST_URL" \
      && echo "${APTFAST_SHA256}  $tmp" | sha256sum -c - \
      && install -D -m0755 "$tmp" /usr/local/sbin/apt-fast; then
      :
    else
      echo "apt-fast vendoring failed; continuing with apt-get." >&2
    fi
  elif command -v wget >/dev/null 2>&1; then
    # wget -qO "$tmp" "$APTFAST_URL" && install -D -m 0755 "$tmp" /usr/local/sbin/apt-fast
    # wget -qO "$tmp" -- "$APTFAST_URL" && echo "${APTFAST_SHA256}  $tmp" | sha256sum -c - && install -D -m0755 "$tmp" /usr/local/sbin/apt-fast

    if wget -qO "$tmp" -- "$APTFAST_URL" \
      && echo "${APTFAST_SHA256}  $tmp" | sha256sum -c - \
      && install -D -m0755 "$tmp" /usr/local/sbin/apt-fast; then
      :
    else
      echo "apt-fast vendoring failed; continuing with apt-get." >&2
    fi

  fi
  rm -f "$tmp"
fi

# Optional hardening (recommended): checksum pinning for the vendored download
# If you pin a specific upstream commit/tag, set APTFAST_URL and APTFAST_SHA256 beforehand (or hardcode them).
# Optional: checksum verification. Set APTFAST_SHA256 to a known-good value if you pin a commit.
if command -v apt-fast >/dev/null 2>&1 && [ -n "${APTFAST_SHA256:-}" ]; then
  echo "${APTFAST_SHA256}  /usr/local/sbin/apt-fast" | sha256sum -c - >/dev/null 2>&1 || {
    echo "apt-fast checksum mismatch; removing vendored file" >&2
    rm -f /usr/local/sbin/apt-fast
  }
fi

## Provide a non-interactive apt-fast config if not present (dynamic concurrency)
#if command -v apt-fast >/dev/null 2>&1 && [ ! -f /etc/apt-fast.conf ]; then
#  # Size concurrency to CPU; cap between 8 and 16. More rarely helps on 1GbE.
#  CORES=$(nproc)
#  CONN=$(( CORES * 2 ))
#  [ "$CONN" -lt 8 ]  && CONN=8
#  [ "$CONN" -gt 16 ] && CONN=16
#
#  install -D -m 0644 /dev/stdin /etc/apt-fast.conf <<EOF
#DOWNLOADBEFORE=true
#MAXCONNECTIONS=$CONN
#DLOWNER=root
#APTMGR=apt-get
#DOWNLOADER=aria2c
#_OPTIONS='-x $CONN -s $CONN -j $CONN --min-split-size=1M --connect-timeout=600 --timeout=600'
#EOF
#fi
# Provide a non-interactive apt-fast config if not present (storage-aware tuning)
if command -v apt-fast >/dev/null 2>&1 && [ ! -f /etc/apt-fast.conf ]; then
  # Detect storage class from the root filesystem device (robust to dm-crypt/LVM)
  ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  ROOT_DEV="$(readlink -f "${ROOT_SRC}" 2>/dev/null || true)"
  # Get the parent block device name (e.g., mmcblk0, nvme0n1, sda)
  BASE="$(lsblk -no pkname "${ROOT_DEV}" 2>/dev/null || true)"
  [ -z "${BASE}" ] && BASE="${ROOT_DEV##*/}"  # fallback

  # Default classification; refine below if we have a base device
  STORAGE_CLASS="ssd"

  if [ -n "${BASE}" ]; then
    if [[ "${BASE}" == mmcblk* ]]; then
      STORAGE_CLASS="sd"
    elif [ -r "/sys/block/${BASE}/queue/rotational" ] && grep -qx '1' "/sys/block/${BASE}/queue/rotational"; then
      STORAGE_CLASS="hdd"
    fi
  fi


  # Default concurrency/alloc; adjust by storage
  case "${STORAGE_CLASS}" in
    sd|hdd)
      CONN_SERVER=4   # --max-connection-per-server
      SPLIT=8         # --split
      J=8             # --max concurrent downloads (aria2c -j via MAXCONNECTIONS)
      ALLOC="none"    # --file-allocation
      ;;
    *)
      # NVMe/SSD/USB SSD
      CONN_SERVER=10
      SPLIT=16
      J=16
      ALLOC="falloc"
      ;;
  esac

  install -D -m 0644 /dev/stdin /etc/apt-fast.conf <<EOF
DOWNLOADBEFORE=true
# Max concurrent downloads (aria2c -j)
MAXCONNECTIONS=${J}
DLOWNER=root
APTMGR=apt-get
DOWNLOADER=aria2c
# Storage-aware aria2c options:
# -x: max-connection-per-server, -s: split
# --file-allocation: falloc on SSD/NVMe, none on SD/HDD to reduce writes
OPTIONS="-x ${CONN_SERVER} -s ${SPLIT} --min-split-size=1M --file-allocation=${ALLOC} --connect-timeout=600 --timeout=600"
_OPTIONS='-x ${CONN_SERVER} -s ${SPLIT} --min-split-size=1M --file-allocation=${ALLOC} --connect-timeout=600 --timeout=600'
EOF

  # Optional: log what we decided (handy for support)
  echo "apt-fast tuned for storage=${STORAGE_CLASS} base=${BASE}: j=${J}, -x=${CONN_SERVER}, -s=${SPLIT}, alloc=${ALLOC}"
fi
# --- end vendoring block ---


# Speed enhancement when you add LUKS/cryptsetup by using zstd lvl=3 with threads.
# **** KEEP THIS BLOCK IF YOU ADD ENCRYPTION WITH LUKS!
# Fast initramfs compression (install-time optimization)
# Speeds up the final update-initramfs by switching to zstd level 3 with multi-threading.
# Applies to any initramfs rebuild queued during install (e.g., kernel/crypto/fs packages).
# Safe to keep for future kernel updates; remove in cleanup if you want stock defaults.
THREADS="$(nproc)"
install -D -m0644 /dev/stdin /etc/initramfs-tools/conf.d/99zstd-fast <<EOF
# initramfs-tools honors COMPRESS and COMPRESSLEVEL on Bookworm.
COMPRESS=zstd
COMPRESSLEVEL=3
# zstd will multi-thread; harmless if the caller already sets -T0.
ZSTD_NBTHREADS=${THREADS}
EOF

# Optional: ensure zstd exists (normally present on Bookworm)
if ! command -v zstd >/dev/null 2>&1; then
  apt-get install -y zstd || true
fi



# Ensure /usr/local/{sbin,bin} win in PATH so wrappers are used
case ":$PATH:" in
  *:/usr/local/sbin:*) ;;
  *) export PATH="/usr/local/sbin:/usr/local/bin:$PATH" ;;
esac

# wrapper commented out in favour of wrapper which prefers apt-fast below, where possible
## Wrap apt-get, apt, and dpkg so every call runs under eatmydata during provisioning
#install -D -m 0755 /dev/stdin /usr/local/sbin/apt-get <<'EOF'
##!/bin/sh
#if command -v eatmydata >/dev/null 2>&1; then
#  exec /usr/bin/eatmydata /usr/bin/apt-get "$@"
#else
#  exec /usr/bin/apt-get "$@"
#fi
#EOF

# Overwrite apt-get wrapper to prefer apt-fast when available (still under eatmydata), otherwise passthrough to apt-get

# The below started with these two lines but you replaced them:
# #!/bin/sh
# set -eu
install -D -m 0755 /dev/stdin /usr/local/sbin/apt-get <<'EOF'
#!/bin/bash
set -Eeuo pipefail
# Force no Recommends/Suggests for 'install' calls
INST=0
for a in "$@"; do
  if [ "$a" = "install" ]; then INST=1; break; fi
done
EXTRA=()
if [ "$INST" -eq 1 ]; then
  EXTRA=(-o APT::Install-Recommends=false -o APT::Install-Suggests=false)
  # Insert our options before the caller's first end-of-options marker.
  forwarded=()
  for a in "$@"; do
    if [[ "$a" == -- && ${#EXTRA[@]} -gt 0 ]]; then
      forwarded+=("${EXTRA[@]}")
      EXTRA=()
    fi
    forwarded+=("$a")
  done
  set -- "${forwarded[@]}"
fi

# Prefer apt-fast if available; avoid recursion
if command -v apt-fast >/dev/null 2>&1 && [ -z "${APT_FAST_ACTIVE:-}" ]; then
  AF="$(command -v apt-fast)"
  if command -v eatmydata >/dev/null 2>&1; then
    if command -v ionice >/dev/null 2>&1; then
      exec env APT_FAST_ACTIVE=1 ionice -c2 -n0 nice -n -5 /usr/bin/eatmydata "$AF" "$@" "${EXTRA[@]}"
    else
      exec env APT_FAST_ACTIVE=1 nice -n -5 /usr/bin/eatmydata "$AF" "$@" "${EXTRA[@]}"
    fi
  else
    if command -v ionice >/dev/null 2>&1; then
      exec env APT_FAST_ACTIVE=1 ionice -c2 -n0 nice -n -5 "$AF" "$@" "${EXTRA[@]}"
    else
      exec env APT_FAST_ACTIVE=1 nice -n -5 "$AF" "$@" "${EXTRA[@]}"
    fi
  fi
fi

# Fallback to the real apt-get (or when called from apt-fast)
if command -v eatmydata >/dev/null 2>&1; then
  if command -v ionice >/dev/null 2>&1; then
    exec ionice -c2 -n0 nice -n -5 /usr/bin/eatmydata /usr/bin/apt-get "$@" "${EXTRA[@]}"
  else
    exec nice -n -5 /usr/bin/eatmydata /usr/bin/apt-get "$@" "${EXTRA[@]}"
  fi
else
  if command -v ionice >/dev/null 2>&1; then
    exec ionice -c2 -n0 nice -n -5 /usr/bin/apt-get "$@" "${EXTRA[@]}"
  else
    exec nice -n -5 /usr/bin/apt-get "$@" "${EXTRA[@]}"
  fi
fi
EOF



#install -D -m 0755 /dev/stdin /usr/local/sbin/dpkg <<'EOF'
##!/bin/sh
#if command -v eatmydata >/dev/null 2>&1; then
#  exec /usr/bin/eatmydata /usr/bin/dpkg "$@"
#else
#  exec /usr/bin/dpkg "$@"
#fi
#EOF
# the below used '#!/bin/sh' but you replaced it
install -D -m 0755 /dev/stdin /usr/local/sbin/dpkg <<'EOF'
#!/bin/bash
set -Eeuo pipefail
if command -v eatmydata >/dev/null 2>&1; then
  if command -v ionice >/dev/null 2>&1; then
    exec ionice -c2 -n0 nice -n -5 /usr/bin/eatmydata /usr/bin/dpkg "$@"
  else
    exec nice -n -5 /usr/bin/eatmydata /usr/bin/dpkg "$@"
  fi
else
  if command -v ionice >/dev/null 2>&1; then
    exec ionice -c2 -n0 nice -n -5 /usr/bin/dpkg "$@"
  else
    exec nice -n -5 /usr/bin/dpkg "$@"
  fi
fi
EOF

# The below started with these two lines but you replaced them:
# #!/usr/bin/env bash
# set -euo pipefail
install -D -m 0755 /dev/stdin /usr/local/sbin/apt <<'EOF'
#!/bin/bash
set -Eeuo pipefail

# Find index of first non-option token (the subcommand)
idx=0; sub=""
for arg in "$@"; do
  ((++idx))
  if [[ "$arg" != -* ]]; then sub="$arg"; break; fi
done

case "$sub" in
  install|upgrade|dist-upgrade|full-upgrade|autoremove|remove|purge)
    # Map apt's 'full-upgrade' to apt-get's 'dist-upgrade'
    if [[ "$sub" == "full-upgrade" ]]; then
      before=("${@:1:$((idx-1))}")
      after=("${@:$((idx+1))}")
      set -- "${before[@]}" dist-upgrade "${after[@]}"
    fi
    # Always route these verbs through our apt-get wrapper (which prefers apt-fast and uses eatmydata)
    exec /usr/local/sbin/apt-get "$@"
    ;;
esac

# Fallback: use apt directly (e.g., 'apt update', 'apt show', etc.)
exec /usr/bin/apt "$@"
EOF


# Also provide wrappers in /usr/local/bin (covers edge PATHs)
install -D -m 0755 /usr/local/sbin/apt-get /usr/local/bin/apt-get
install -D -m 0755 /usr/local/sbin/dpkg /usr/local/bin/dpkg
install -D -m 0755 /usr/local/sbin/apt /usr/local/bin/apt

# Refresh the shell's command hash so new wrappers are picked up immediately
hash -r 2>/dev/null || true
#######################################################################################
# --- Install-time speed boosts ------------------------------------------------
# The runner keeps package archives on disk and APT lists on tmpfs.
# Below we only divert mandb to skip heavy triggers during bulk APT.
# ------------------------------------------------------------------------------
# Defer heavy trigger: divert mandb (we'll restore & run once in 70-cleanup.sh)
if command -v mandb >/dev/null 2>&1 && [ -z "$(dpkg-divert --list /usr/bin/mandb 2>/dev/null)" ]; then
  dpkg-divert --quiet --local --rename --add /usr/bin/mandb
  ln -sf /bin/true /usr/bin/mandb
fi
#########################################################################################

# Keep ldconfig active: package library caches must be current before intermediate reboots.


# Install systemd units to rebuild man-db after the final reboot (off the critical path)
install -D -m 0644 /dev/stdin /etc/systemd/system/billspi-mandb.service <<'EOF'
[Unit]
Description=Rebuild man-db quietly after install
# Run only once; skip if stamp exists
ConditionPathExists=!/var/lib/billspi/mandb.done

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
CPUWeight=1
# 1) rebuild, 2) stamp, 3) self-clean: disable timer, remove units, reload systemd
ExecStart=/bin/sh -c 'set -eu; mkdir -p /var/lib/billspi; mandb -q || true; touch /var/lib/billspi/mandb.done'
ExecStartPost=/bin/sh -c 'systemctl disable --now billspi-mandb.timer || true; rm -f /etc/systemd/system/billspi-mandb.service /etc/systemd/system/billspi-mandb.timer; systemctl daemon-reload || true'
EOF

install -D -m 0644 /dev/stdin /etc/systemd/system/billspi-mandb.timer <<'EOF'
[Unit]
Description=Schedule man-db rebuild after boot

[Timer]
OnBootSec=2min
Persistent=true
Unit=billspi-mandb.service

[Install]
WantedBy=timers.target
EOF

# Store original sudo timeout (read from base and includes; default 5)
ORIGINAL_TIMEOUT="$(
  awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*Defaults/ && match($0, /timestamp_timeout[[:space:]]*=[[:space:]]*-?[0-9]+/) {
      v=substr($0, RSTART, RLENGTH)
      sub(/^[^=]*=[[:space:]]*/, "", v)
    }
    END{print (v=="" ? 5 : v)}
  ' /etc/sudoers /etc/sudoers.d/* 2>/dev/null
)"
echo "$ORIGINAL_TIMEOUT" > ~/original_sudo_timeout.txt

# OPTIONAL: Verify if visudo is installed; If it's installed, this command will return the path to visudo (typically /usr/sbin/visudo).
# which visudo
# OPTIONAL: If for some reason it's not installed, you can install it by running:
# apt-get install sudo


# Set a custom sudo timeout for the duration of the script (60 minutes) via sudoers.d
install -d -m 0755 /etc/sudoers.d
_tmp="$(mktemp)"
printf 'Defaults:%s timestamp_timeout=60\n' "$(id -un)" >"$_tmp"
if visudo -cf "$_tmp"; then
  install -m 0440 "$_tmp" "/etc/sudoers.d/timeout-$(id -un)"
else
  echo "Invalid sudoers fragment; not installing." >&2
  rm -f "$_tmp"
  exit 1
fi
rm -f "$_tmp"


# Set complex temporary password
# Random password generated with openssl using random string of characters using Base64 encoding, then trims it to 15 characters using cut.


# Uncomment the two lines below
                                          #NEW_PASSWORD=$(openssl rand -base64 15 | cut -c1-15)
                                          #echo "New Password: $NEW_PASSWORD"

# OPTION 2: WILL INCLUDE SPECIAL CHARACTERS
# OPTION 2: Random password generated with /dev/urandom random number generator with tr to filter the characters:
# OPTION 2: This command pulls random characters from /dev/urandom, filters them to include only alphanumeric and special characters, and then extracts 15 characters.
# OPTIONN 2:tr -dc 'A-Za-z0-9!@#$%^&*()_+=' < /dev/urandom | head -c 15
# NEW_PASSWORD=$(tr -dc 'A-Za-z0-9!@#$%^&*()_+{}[]:;<>,.?/' < /dev/urandom | head -c 15)


# These commands will immediately stop the interfaces. If you need permanent shutdowns, you may want to disable the services for wireless and Bluetooth via systemd, and configure network interfaces to not start at boot using configuration files like /etc/dhcpcd.conf or /etc/network/interfaces.
# Disable Ethernet
# ip link set eth0 down
# Disable Wi-Fi
# ip link set wlan0 down
# Disable Bluetooth
# Uncomment the line below:
# rfkill block bluetooth



# VERSION 1, NO PERSISTENCE, JUST ONE LONG INSTALL
# Restore the original sudo timeout
# echo "Restoring original sudo timeout..."
# sed -i '/timestamp_timeout=30/d' /etc/sudoers

# if [[ "$ORIGINAL_TIMEOUT" != "5" ]]; then
#   echo "$ORIGINAL_TIMEOUT" | EDITOR='tee -a' visudo
# else
#   echo "Defaults:$(whoami) timestamp_timeout=5" | EDITOR='tee -a' visudo
#fi

#echo "Done."


# Enable Ethernet
# ip link set eth0 up
# Enable Wi-Fi
# ip link set wlan0 up
# Enable Bluetooth
# rfkill unblock bluetooth


# Restore the original sudo timeout
if [[ -f ~/original_sudo_timeout.txt ]]; then
  ORIGINAL_TIMEOUT="$(cat ~/original_sudo_timeout.txt)"
  echo "Restoring original sudo timeout..."

  # Remove our drop-in
  rm -f "/etc/sudoers.d/timeout-$(id -un)"

  # If original wasn't the Debian default (5), recreate a drop-in with that value
  if [[ "${ORIGINAL_TIMEOUT:-5}" != "5" ]]; then
    _tmp="$(mktemp)"
    printf 'Defaults:%s timestamp_timeout=%s\n' "$(id -un)" "$ORIGINAL_TIMEOUT" >"$_tmp"
    if visudo -cf "$_tmp"; then
      install -m 0440 "$_tmp" "/etc/sudoers.d/timeout-$(id -un)"
    else
      echo "Invalid sudoers fragment during restore; leaving default." >&2
    fi
    rm -f "$_tmp"
  fi

  # Sanity-check whole sudoers config
  visudo -c || { echo "sudoers validation failed after restore" >&2; exit 1; }
fi


# touch /run/billspi/reboot-required
[[ -f /var/run/reboot-required ]] && touch /run/billspi/reboot-required

exit 0

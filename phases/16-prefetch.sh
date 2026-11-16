#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
# FATAL / WARNING / NOT YET IMPLEMENTED:
# 1. In all other scripts, Use 'apt-get --no-download install <pkg>' .  This will force installation from cache and fail fast.
# That is since this script downloads the files; use --no-download throughout other scripts
#
# 2. ALIAS ONE OF THESE: ripgrep (rg), fd-find (fdfind) -- fast search/find (huge QoL boost)
# OPTIONAL: net-tools , make this optional in your config files.
# ALIAS ONE OF THESE: ripgrep (rg), fd-find (fdfind) - fast search/find (huge QoL boost)
#
#
#
set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------
# Noninteractive & safe defaults
# -----------------------------
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a               # auto-restart services when needed (no prompts)
export APT_LISTCHANGES_FRONTEND=none    # suppress apt-listchanges if present
export LC_ALL=C LANG=C

case ":$PATH:" in *:/usr/local/sbin:*) ;; *) export PATH="/usr/local/sbin:/usr/local/bin:$PATH" ;; esac
ulimit -n 65536 || true

# -----------------------------
# Packages to prefetch (deduped)
# -----------------------------
PKG=(
  # original list (alphabetical)
  aide
  aide-common
  aria2
  auditd
  bpfcc-tools
  bpftrace
  build-essential
  coreutils
  cppcheck
  curl
  dnsmasq
  dstat
  eatmydata
  ethtool
  fail2ban
  fd-find
  gawk
  gdb
  git
  golang
  binutils
  htop
  iftop
  iotop
  iproute2
  irqbalance
  libarchive-tools
  libpam-modules
  libpam-modules-bin
  libpam-runtime
  raspi-utils
  libssl3
  linux-perf
  logrotate
  logwatch
  # ltrace has no Bookworm ARM64 package.
  lz4
  ncdu
  net-tools
  ninja-build
  openssh-server
  openssl
  p7zip-full
  parallel
  pbzip2
  # PF_RING is checked after its repository is configured in phase 40.
  pigz
  procps
  xz-utils
  linux-headers-rpi-2712
  ripgrep
  rsync
  strace
  sysstat
  trace-cmd
  ufw
  unattended-upgrades
  valgrind
  zram-tools
  zstd

# new additions (alphabetical)
  ca-certificates
# docker   use the official Docker repository instead;
# fd-find
  git
# htop
  iperf3
  jq
  needrestart
# net-tools
  nmap
  ntfs-3g
  parted
  python3-venv
# ripgrep
  traceroute
#  v4l-utils
  vim
  watchdog
)

# -----------------------------
# Common apt-get options
# -----------------------------
APT_OPTS=(
  -y
  -o Dpkg::Options::="--force-confdef"    # use maintainer defaults for new conffiles
  -o Dpkg::Options::="--force-confold"    # keep existing conffiles if changed
  -o Acquire::Retries=5                   # retry transient failures
  -o Acquire::http::Timeout=30            # bound per-req latency
  -o DPkg::Lock::Timeout=600              # coexist with apt-daily
  -o APT::Color=0                         # no ANSI
  -o Dpkg::Progress-Fancy=0               # simpler output
  # Speed tweaks:
  -o Acquire::Languages=none              # skip i18n indexes
  -o Acquire::PDiffs=false                # prefer full indexes (faster on ARM)
  -o Acquire::Queue-Mode=access           # more parallelism
  -o Acquire::http::Pipeline-Depth=50     # aggressive pipelining
  -o Acquire::http::No-Cache=true         # bypass proxy caches
  -o Acquire::ForceIPv4=true              # avoid IPv6 stalls
  -o Acquire::CompressionTypes::Order::=gz # faster decompression
)

# Always prefetch only; do not install now
APT_DL_OPTS=(
  --no-install-recommends
  --download-only
)

# -----------------------------
# Run
# -----------------------------

RAMDIR=/dev/shm/aptprefetch; mkdir -p "$RAMDIR/archives/partial" "$RAMDIR/lists/partial"
APT_RAM_OPTS=(-o Dir::Cache::archives="$RAMDIR/archives" -o Dir::State::lists="$RAMDIR/lists")
# Refresh indices quickly with the same performance options
apt-get "${APT_OPTS[@]}" "${APT_RAM_OPTS[@]}" update
# One big prefetch to maximize throughput and minimize connection setup
apt-get "${APT_OPTS[@]}" "${APT_RAM_OPTS[@]}" "${APT_DL_OPTS[@]}" install "${PKG[@]}"

mkdir -p /var/cache/apt/archives /var/lib/apt/lists

# Persist prefetched archives without deleting packages cached by earlier phases.
# APT lists remain temporary; replace them with the refreshed lists.
if command -v rsync >/dev/null 2>&1; then
  rsync -a --whole-file "$RAMDIR/archives/" /var/cache/apt/archives/
  rsync -a --delete --whole-file "$RAMDIR/lists/"    /var/lib/apt/lists/
else
  mkdir -p /var/cache/apt/archives /var/lib/apt/lists
  cp -a "$RAMDIR/archives/." /var/cache/apt/archives/
  cp -a "$RAMDIR/lists/."    /var/lib/apt/lists/
fi

# Optional: verify packages are cached (non-fatal)
# ls -lh /var/cache/apt/archives/ || true

touch /run/billspi/reboot-required
exit 0

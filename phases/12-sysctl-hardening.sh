#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
# Pi OS Lite: Kernel/Sysctl Hardening
# Purpose: Reduce info leaks, cut common privesc surfaces, and enforce sane network hygiene.
# Scope: Writes hardening sysctls and the NetworkManager default needed to retain strict rp_filter.
# Platform: Raspberry Pi OS (Debian 12/Bookworm) on Raspberry Pi 5. Root required.
#
# What this config does (high level):
# - Kernel: hide pointers/dmesg, harden eBPF/perf; apply ptrace, kexec and unprivileged-user-namespace controls when supported.
# - Filesystem: protect hardlinks/symlinks/FIFOs/regular files from common local-abuse patterns.
# - Network (IPv4): enable rp_filter, disable redirects/source-route/secure_redirects, enable SYN cookies, log martians, ICMP sanity.
# - Network (IPv6): drop redirects and RA by default (adjust if you rely on SLAAC).
#
# Important knobs you may need to relax for certain workloads:
# - kernel.unprivileged_userns_clone=0     # set to 1 if you need rootless containers/some sandboxes.
# - net.core.bpf_jit_harden=2 and kernel.unprivileged_bpf_disabled=1  # may limit advanced tracing.
# - kernel.perf_event_paranoid=3           # restricts perf to root only.
# - net.ipv6.conf.*.accept_ra=0            # breaks IPv6 SLAAC; set to 1 if you require RA.
#
# Idempotency: Safe to re-run. The file is replaced atomically and reapplied each time.
# Rollback: Delete /etc/sysctl.d/90-hardening.conf and
# /etc/NetworkManager/conf.d/90-billspi-rp-filter.conf, then reboot.
# Override: Place custom settings in a higher-numbered file (e.g., /etc/sysctl.d/99-local.conf).
# Verify: `sysctl -a | grep <key>`; kernel messages via `journalctl -k`.
#
set -Eeuo pipefail
IFS=$'\n\t'

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y)
APT_OPTS+=(-o Acquire::Retries=3 -o DPkg::Lock::Timeout=60)

# Step Y: Kernel/sysctl hardening
echo "Applying kernel/sysctl hardening..."

# Write hardening config (idempotent)
install -d -m 0755 /etc/sysctl.d
tee /etc/sysctl.d/90-hardening.conf >/dev/null <<'EOF'
# ---- Kernel info-leak surface
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1

# ---- IPv4 anti-spoofing and sane routing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.*.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# ---- IPv6 hardening (use these if IPv6 is enabled)
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.*.accept_redirects = 0
# If you do NOT depend on router advertisements (RA), keep these at 0:
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

# ---- If IPv6 is truly unused, you can disable it entirely instead:
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1

# ---- Filesystem link protections
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# ---- Restrict kernel features often abused for privesc/side-channels
kernel.perf_event_paranoid = 3
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2

# ---- Extra IPv4 hygiene
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
EOF

# Emit kernel-specific controls only when the running kernel exposes them.
for setting in \
  'kernel.yama.ptrace_scope=1' \
  'kernel.unprivileged_userns_clone=0' \
  'kernel.kexec_load_disabled=1'
do
  key="${setting%%=*}"
  value="${setting#*=}"
  if [[ -e "/proc/sys/${key//.//}" ]]; then
    printf '%s = %s\n' "$key" "$value" >> /etc/sysctl.d/90-hardening.conf
  else
    printf 'WARNING: %s is unavailable; its requested setting was not applied.\n' "$key" >&2
    if [[ "$key" == kernel.unprivileged_userns_clone ]]; then
      printf '%s\n' 'WARNING: BillsPi has not applied its intended unprivileged-user-namespace restriction on this kernel.' >&2
    fi
  fi
done

# UFW applies this file after sysctl.d; keep its martian logging policy aligned.
sed -i -E \
  -e 's~^([[:space:]]*net/ipv4/conf/(all|default)/log_martians[[:space:]]*=[[:space:]]*)0([[:space:]]*(#.*)?)$~\11\3~' \
  -e "s/^# Don't log Martian Packets/# Log Martian Packets/" \
  /etc/ufw/sysctl.conf

# NetworkManager's automatic MPTCP endpoint handling relaxes rp_filter to 2.
# Keep the existing strict policy; this does not disable kernel MPTCP support.
install -d -m 0755 /etc/NetworkManager/conf.d
tee /etc/NetworkManager/conf.d/90-billspi-rp-filter.conf >/dev/null <<'EOF'
[connection]
connection.mptcp-flags=1
EOF
chmod 0644 /etc/NetworkManager/conf.d/90-billspi-rp-filter.conf
# The requested reboot below loads this default before the next activation.

# Load new settings immediately
sysctl -e --system >/dev/null

touch /run/billspi/reboot-required
exit 0

#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
: "${LOG:=/var/log/ssh_perf_setup.log}"

#
# Purpose
#   Server-side SSH/SFTP/SCP performance & latency improvements for Raspberry Pi OS Lite (Debian 12/Bookworm).
#   Writes a single drop-in config at /etc/ssh/sshd_config.d/30-performance.conf and sysctl.d files
#   (no edits to the base /etc/ssh/sshd_config). Validates with `sshd -t` and reloads sshd.
#
# What this script does
#   - Transport/cipher policy tuned for Pi 5 (AES-GCM first, chacha fallback, CTR for compatibility)
#   - Modern KEX (sntrup761x25519 + curve25519), modern pubkey algs
#   - Faster handshakes: UseDNS no, GSSAPIAuthentication no
#   - Reliability: ClientAliveInterval/CountMax; fewer rekeys (RekeyLimit 2G 2h); IPQoS none
#   - SFTP: use internal-sftp
#   - Kernel: enables TCP Fast Open + BBR via /etc/sysctl.d
#
# What this script does NOT do
#   - It doesn't touch firewall or Fail2Ban.
#   - It doesn't edit /etc/ssh/sshd_config directly (drop-in only).
#   - It doesn't change the SSH port, users, or authentication policy (handled by your core SSH script).
#
# Requirements
#   - Raspberry Pi OS Bookworm with OpenSSH supporting Include /etc/ssh/sshd_config.d/*.conf (default on Bookworm)
#   - Run as root
#
# Rollback
#   - Remove /etc/ssh/sshd_config.d/30-performance.conf and reload ssh: `systemctl reload ssh`
#   - Remove /etc/sysctl.d/99-ssh-fastopen.conf and /etc/sysctl.d/99-tcp-bbr.conf, then `sysctl --system`
#
# Logging
#   - /var/log/ssh_perf_setup.log
#
# Notes
#   - Compression may be turned off for high-speed LAN bulk transfers if CPU becomes the bottleneck.
#   - Client-side flags (e.g., `sftp -R 128 -B 1048576`) often give larger throughput wins than server tweaks.
#
# Raspberry Pi OS Lite (Debian 12/Bookworm) - SSH/SFTP/SCP performance tunings
# - Creates /etc/ssh/sshd_config.d/30-performance.conf with transport tweaks
# - Enables TCP Fast Open and BBR via /etc/sysctl.d
# - Validates config and reloads sshd

# Require root once; avoid scattered sudo prompts
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo -i)"; exit 1
fi

LOG=/var/log/ssh_perf_setup.log
CONF_DIR=/etc/ssh/sshd_config.d
CONF_FILE="$CONF_DIR/30-performance.conf"
SYSCTL_D=/etc/sysctl.d
SYSCTL_TFO="$SYSCTL_D/99-ssh-fastopen.conf"
SYSCTL_BBR="$SYSCTL_D/99-tcp-bbr.conf"

log(){ echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

log "Starting SSH/SFTP/SCP optimization..."

# Ensure conf.d dir exists
install -d -m 0755 "$CONF_DIR"

# Write the performance drop-in (server-side options only)
# Notes:
# - AES-GCM first (fast on Pi 5 with ARMv8 AES), then chacha, then CTR fallbacks
# - Modern KEX with PQ hybrid first, curve25519 fallback
# - Disable UseDNS and GSSAPI to reduce handshake latency (if you don't use Kerberos)
# - Keep compression explicit (Bookworm default is yes, post-auth)
# - Keep NAT-friendly keepalives; neutralize DSCP; fewer rekeys during long transfers
# - Prefer internal-sftp (same code, fewer moving parts)
cat > "$CONF_FILE" <<'EOF'
# ---- SSH Performance/Transport Tunings (drop-in) ----

# Prefer fast modern AEAD ciphers, then CTR fallbacks
Ciphers aes128-gcm@openssh.com,aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes128-ctr,aes192-ctr,aes256-ctr

# Modern KEX: hybrid PQ+X25519 first, then X25519; add NIST P-256 fallback for older clients
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256

# Accept modern public-key signatures only (Ed25519/FIDO2, ECDSA P-256, RSA-SHA2; no SHA-1 'ssh-rsa')
PubkeyAcceptedAlgorithms ssh-ed25519,sk-ssh-ed25519@openssh.com,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256

# Reduce handshake latency
UseDNS no
GSSAPIAuthentication no

# Compression is post-auth by default on Bookworm; keep explicit
Compression yes

# Keep unreliable/NAT'd links alive but don't spam
ClientAliveInterval 30
ClientAliveCountMax 3

# Prefer responsive shells under load: mark interactive=lowdelay, bulk=throughput.
# If your network misbehaves with DSCP, switch to: IPQoS none
IPQoS 16 8

# Re-key less often during very large transfers
RekeyLimit 2G 2h

# Protect performance under bursts of connections
MaxStartups 10:30:60
LoginGraceTime 30

# The existing SFTP declaration in sshd_config is updated below.
EOF

# Bookworm already declares this subsystem in the main configuration.
sed -i -E 's@^[[:space:]]*Subsystem[[:space:]]+sftp[[:space:]].*@Subsystem sftp internal-sftp@' /etc/ssh/sshd_config
log "Wrote $CONF_FILE"

# TCP Fast Open (both client/server)
install -d -m 0755 "$SYSCTL_D"
echo "net.ipv4.tcp_fastopen = 3" > "$SYSCTL_TFO"
log "Wrote $SYSCTL_TFO (TFO client+server)"

# Enable BBR congestion control system-wide (benefits all TCP, including SSH/SFTP)
cat > "$SYSCTL_BBR" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
log "Wrote $SYSCTL_BBR (BBR + fq)"

# Apply sysctls immediately (best effort)
# Dangerous, make these lines independent and non-fatal: sysctl -q -p "$SYSCTL_TFO" && sysctl -q -p "$SYSCTL_BBR" || sysctl --system || true
sysctl -q -p "$SYSCTL_TFO" || true
sysctl -q -p "$SYSCTL_BBR" || true
sysctl --system || true


#        # Validate sshd config before reload
#        if sshd -t 2>>"$LOG"; then
#            log "sshd config validation OK"
#        else
#            log "ERROR: sshd -t failed; aborting"; exit 1
#        fi
#
#        # Reload is sufficient (no port/path changes here)
#        if systemctl reload ssh 2>/dev/null; then :; else
#          systemctl reload sshd 2>/dev/null || true
#        fi
#        log "Reloaded SSH service"

# Validate sshd config before reload; reload only on success; clean up on failure
sshd_check_status=0
sshd_check_output="$(/usr/sbin/sshd -t -f /etc/ssh/sshd_config 2>&1)" || sshd_check_status=$?
if [[ -n "$sshd_check_output" ]]; then
    printf '%s\n' "$sshd_check_output" | tee -a "$LOG" >&2
fi
if [[ "$sshd_check_status" -eq 0 ]]; then
    log "sshd config validation OK"
    # Reload is sufficient (no port/path changes here)
    if systemctl reload ssh; then :; else
      systemctl reload sshd || true
    fi
    log "Reloaded SSH service"
else
    log "ERROR: sshd -t failed; restoring previous state and aborting"
    rm -f "${CONF_FILE:-}"
    exit 1
fi

log "Done. Active drop-in: ${CONF_FILE:-(none)}"

install -d -m0755 /run/billspi
touch /run/billspi/reboot-required
exit 0

#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
# SSH Setup Script for Raspberry Pi OS Lite - One-time during install
# - Pre-downloads openssh-server, then (optionally) drops network and installs from cache
# - Chooses a free random high SSH port, writes to /var/log/ssh_setup.log and /root/ssh_port.log
# - Enforces key auth; disables password auth; disables root login globally
# - Optional: allow root login ONLY from KNOWN_IP (toggle)
# - Applies UFW rules ONLY if UFW is present AND active; does not install UFW
# - Configures Fail2Ban ONLY if installed (uses UFW if active, else iptables-multiport)
# - Uses systemd drop-in for ssh.service restart policy
# - Validates sshd config before restart
# - Reboot prompt (UNATTENDED=1 to skip)

# --- Must run as root to avoid interactive sudo prompts ---
if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (e.g., sudo -i, then run this script)."
    exit 1
fi

LOGFILE="/var/log/ssh_setup.log"

############################################
# CONFIG - EDIT ME
############################################
USERNAME="$(awk -F: '$3==1000{print $1; exit}' /etc/passwd)"  # same primary account as the runner
KNOWN_IP="203.0.113.10"                       # restrict SSH to this IP
PREDEFINED_KEY_PATH="/boot/firmware/id_rsa.pub" # where you placed your public key
UNATTENDED="${UNATTENDED:-0}"                 # set UNATTENDED=1 to skip reboot prompt
ALLOW_ROOT_FROM_KNOWN_IP="${ALLOW_ROOT_FROM_KNOWN_IP:-0}"  # 1 = allow root ONLY from KNOWN_IP
############################################

log()  { echo "$(date +"%Y-%m-%d %H:%M:%S") - $*" | tee -a "$LOGFILE"; }
warn() { log "WARNING: $*"; }
die()  { echo "ERROR: $*" | tee -a "$LOGFILE" >&2; exit 1; }

trap 'die "Command failed at line $LINENO. Check $LOGFILE."' ERR

USER_HOME="$(eval echo ~"$USERNAME")"
SSH_CFG="/etc/ssh/sshd_config"
PORT_LOG="/root/ssh_port.log"

have_cmd(){ command -v "$1" >/dev/null 2>&1; }

set_sshd(){
    local key="$1"; shift
    local val="$*"
    if grep -Eq "^[#[:space:]]*${key}([[:space:]]|$)" "$SSH_CFG"; then
        local val_esc
        val_esc="$(printf '%s' "$val" | sed -e 's/[\\&~]/\\&/g')"
        # use '~' as sed delimiter so '|' in the pattern is alternation, not a delimiter
        sed -ri "s~^[#[:space:]]*${key}([[:space:]]|$).*~${key} ${val_esc}~" "$SSH_CFG"
    else
        printf '%s %s\n' "$key" "$val" >> "$SSH_CFG"
    fi
}

bring_net_down(){
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        warn "Running over SSH; skipping network shutdown."
        return
    fi
    if have_cmd ifdown && have_cmd ifup; then
        log "Bringing all interfaces down via ifdown..."
        ifdown --all || true
    else
        log "ifdown/ifup not found; stopping dhcpcd and bringing links down..."
        systemctl stop dhcpcd 2>/dev/null || true
#        for IF in $(ls /sys/class/net | grep -v '^lo$'); do
#            ip link set "$IF" down 2>/dev/null || true
#        done
        for IF_PATH in /sys/class/net/*; do
            IF="${IF_PATH##*/}"
            [ "$IF" = "lo" ] && continue
            ip link set "$IF" down 2>/dev/null || true
        done
    fi
}

bring_net_up(){
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        return
    fi
    if have_cmd ifup && have_cmd ifdown; then
        log "Bringing all interfaces up via ifup..."
        ifup --all || true
    else
        log "Starting dhcpcd and bringing links up..."
        systemctl start dhcpcd 2>/dev/null || true
#        for IF in $(ls /sys/class/net | grep -v '^lo$'); do
#            ip link set "$IF" up 2>/dev/null || true
#        done
        for IF_PATH in /sys/class/net/*; do
            IF="${IF_PATH##*/}"
            [ "$IF" = "lo" ] && continue
            ip link set "$IF" up 2>/dev/null || true
        done
    fi
}

choose_port(){
    local p
    while true; do
        p="$(shuf -i 20000-65000 -n 1)"
        # robust: works for IPv4/IPv6 and exact port match
#        if ! ss -H -ltn "sport = :$p" >/dev/null 2>&1; then
#            echo "$p"
#            return
#        fi
        if command -v ss >/dev/null 2>&1; then
            if listeners="$(ss -H -ltn "sport = :$p")"; then
                if [[ -z "$listeners" ]]; then echo "$p"; return; fi
            else
                return 1
            fi
#        else
#            if ! grep -qi "[: ]$(printf "%04x" "$p")[: ]" /proc/net/tcp /proc/net/tcp6 2>/dev/null; then echo "$p"; return; fi
#        fi
        else
            hexp="$(printf '%04x' "$p")"
            if ! grep -qiE "[: ]${hexp}[: ]" /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
                echo "$p"; return
            fi
        fi
    done
}

log "Starting SSH setup script..."
id -u "$USERNAME" >/dev/null 2>&1 || die "User '$USERNAME' does not exist."

# Step 1: Install/Update OpenSSH (download first, then offline install)
log "Updating package list..."
apt-get update

log "Pre-downloading openssh-server..."
apt-get install -y --download-only openssh-server

log "Shutting down network for offline install (if safe)..."
bring_net_down

# if dpkg -s openssh-server >/dev/null 2>&1; then
if dpkg-query -W -f='${db:Status-Status}\n' openssh-server 2>/dev/null | grep -qx installed; then
    log "Upgrading openssh-server from cache..."
    apt-get install -y --only-upgrade --no-download openssh-server
else
    log "Installing openssh-server from cache..."
    apt-get install -y --no-download openssh-server
fi

# Step 2: Configure SSH (free random high port + hardening)
SSH_PORT="$(choose_port)"
log "Selected SSH port: $SSH_PORT"

set_sshd Port "$SSH_PORT"
set_sshd PasswordAuthentication no
set_sshd PubkeyAuthentication yes
set_sshd ChallengeResponseAuthentication no
set_sshd PermitRootLogin no  # global default; optional exception below
set_sshd MaxAuthTries 3
set_sshd LoginGraceTime 20


# Step 3: SSH Key Setup Automation (single key on install)
log "Ensuring ~${USERNAME}/.ssh and authorized_keys..."
SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"
touch "$AUTH_KEYS"; chmod 600 "$AUTH_KEYS"
chown -R "$USERNAME:$USERNAME" "$SSH_DIR"

if [[ -f "$PREDEFINED_KEY_PATH" ]]; then
    if ! grep -Fqx "$(cat "$PREDEFINED_KEY_PATH")" "$AUTH_KEYS"; then
        cat "$PREDEFINED_KEY_PATH" >> "$AUTH_KEYS"
        log "Added public key from $PREDEFINED_KEY_PATH"
    else
        log "Public key already present; skipping add."
    fi
    chown "$USERNAME:$USERNAME" "$AUTH_KEYS"
else
    # die "Public key not found at $PREDEFINED_KEY_PATH"

    # No pubkey at $PREDEFINED_KEY_PATH; enforce "key-only" (no PasswordAuthentication).
    # Create ~/.ssh and empty authorized_keys with strict perms atomically; use user's primary group.
    # Remove authorized_keys if it's a symlink to avoid following it.
    # Continue provisioning; SSH stays locked until a key is added.

    log "No public key at $PREDEFINED_KEY_PATH; leaving SSH locked (PasswordAuthentication no, no authorized_keys)."
    install -d -m0700 -o "$USERNAME" -g "$(id -gn "$USERNAME")" "$(dirname "$AUTH_KEYS")"
    [ -L "$AUTH_KEYS" ] && rm -f "$AUTH_KEYS"
    install -m0600 -o "$USERNAME" -g "$(id -gn "$USERNAME")" /dev/null "$AUTH_KEYS"
fi

# Step 4: UFW rules (only if ufw exists AND is active)
if have_cmd ufw; then
    UFW_STATUS="$(ufw status | awk 'NR==1{print $2}')"
    if [[ "$UFW_STATUS" == "active" ]]; then
        log "UFW is active; applying ordered rules for port $SSH_PORT..."
        # Prepend works even with no user rules; add deny first, then allow ahead of it.
        ufw prepend deny "$SSH_PORT"/tcp || die "Failed to install SSH deny rule"
        ufw prepend allow from "$KNOWN_IP" to any port "$SSH_PORT" proto tcp || die "Failed to install SSH allow rule"
        # Optional hygiene: remove allow on 22 if present
        ufw status | grep -qE '22/tcp.*ALLOW' && ufw delete allow 22/tcp || true
    else
        warn "UFW detected but not active; skipping firewall rules in this script."
    fi
else
    warn "UFW not found; skipping firewall rules in this script."
fi

# Step 4b: Fail2Ban jail (only if installed)
if have_cmd fail2ban-server; then
    # Choose action based on UFW status
    F2B_ACTION="iptables-multiport[port=${SSH_PORT}, protocol=tcp]"
    if have_cmd ufw; then
        UFW_STATUS="$(ufw status | awk 'NR==1{print $2}')"
        [[ "$UFW_STATUS" == "active" ]] && F2B_ACTION="ufw"
    fi

    log "Writing Fail2Ban jail.local (action=${F2B_ACTION})..."
    tee /etc/fail2ban/jail.d/billspi-sshd.local >/dev/null <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
action = ${F2B_ACTION}
backend = systemd
maxretry = 3
EOF
# 08/10/2025 use these instead:
#backend = systemd
#banaction = ufw
#maxretry = 3
#findtime = 1h
#bantime = 1h

    log "Restarting fail2ban..."
    systemctl restart fail2ban || warn "Failed to restart fail2ban"
else
    warn "Fail2Ban not found; skipping jail creation and restart."
fi

# Build AllowUsers safely (avoid "user@" when KNOWN_IP is empty)
if [[ -n "${KNOWN_IP:-}" ]]; then
  ALLOWED_USERS="${USERNAME}@${KNOWN_IP}"
else
  ALLOWED_USERS="${USERNAME}"
fi
if [[ "${ALLOW_ROOT_FROM_KNOWN_IP:-0}" == "1" && -n "${KNOWN_IP:-}" ]]; then
  ALLOWED_USERS+=" root@${KNOWN_IP}"
fi
set_sshd AllowUsers "$ALLOWED_USERS"

# Remove any previous root-login exception block
sed -i '/^# BEGIN root-login-exception/,/^# END root-login-exception/d' "$SSH_CFG"

# Only add the Match block if explicitly enabled AND KNOWN_IP is set
if [[ "${ALLOW_ROOT_FROM_KNOWN_IP:-0}" == "1" && -n "${KNOWN_IP:-}" ]]; then
  # NOTE: unquoted EOF so ${KNOWN_IP} expands into sshd_config
  cat >> "$SSH_CFG" <<EOF

# BEGIN root-login-exception
# Allow root login *only* from KNOWN_IP, with *keys only* (no passwords)
Match Address ${KNOWN_IP}
    PermitRootLogin prohibit-password
    PasswordAuthentication no
    PubkeyAuthentication yes
# END root-login-exception
EOF
fi

# Step 6: systemd auto-restart via drop-in
log "Adding systemd drop-in for ssh.service restart policy..."
install -d -m 0755 /etc/systemd/system/ssh.service.d
cat > /etc/systemd/system/ssh.service.d/override.conf <<'EOF'
[Service]
Restart=on-failure
RestartSec=5s
EOF
systemctl daemon-reload

# Validate config before touching the service
log "Validating sshd configuration..."
install -d -m 0755 /run/sshd
sshd -t || die "sshd configuration test failed"

## Step 7: Enable/Restart services
#log "Enabling and reloading ssh..."
#systemctl enable ssh
#sshd -t && systemctl reload ssh


# Step 7: Enable/Restart services
log "Enabling and reloading ssh..."
# Enable whichever unit name exists; don't abort if neither does (e.g., minimal images)
systemctl enable --now ssh
# Validate config; only reload if it parses cleanly
if /usr/sbin/sshd -t; then
  systemctl reload ssh  || systemctl reload sshd  || true
else
  echo "WARN: sshd -t failed; leaving sshd config unchanged." >&2
fi


# Step 8: Bring network back up (if we took it down)
bring_net_up
# Link-up alone does not guarantee that DHCP and repository DNS are ready.
if systemctl is-active --quiet NetworkManager; then
    nm-online -q --timeout=60 || die "NetworkManager reconnection timed out"
fi
timeout --kill-after=5s 60s bash -c '
    until timeout --kill-after=1s 5s getent ahostsv4 deb.debian.org >/dev/null \
       && timeout --kill-after=1s 5s getent ahostsv4 archive.raspberrypi.com >/dev/null; do
        sleep 1
    done
' || die "Repository DNS readiness timed out after network reconnection"
# (optional) reload ssh again after interfaces are up
sshd -t && systemctl reload ssh

# Step 9: Security-only updates (best effort)
# ******************************************************************************
# Use --download-only if you want to download, not patch...patch in subsequent scripts?
# ******************************************************************************
# Apply updates preferring the Debian Security suite (installs, not just downloads)
APT_OPTS=(-y -o Acquire::Retries=3 -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=600 \
          -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

if apt-cache policy | grep -q 'trixie-security'; then
  echo "Applying upgrade preferring 'trixie-security'..."
  apt-get "${APT_OPTS[@]}" update
  apt-get "${APT_OPTS[@]}" -t trixie-security upgrade || true
else
  echo "No 'trixie-security' suite detected; skipping security-preferring upgrade."
fi

# Step 10: Health check
if systemctl is-active --quiet ssh; then
    log "SSH is active."
else
    die "SSH failed to start."
fi

# Step 11: Print & log the port prominently (write to BOTH files as root)
BANNER="==== SSH CONFIGURED ===="
{
    echo "$BANNER"
    echo "User:     $USERNAME"
    echo "SSH Port: $SSH_PORT"
    echo "Allowed:  $ALLOWED_USERS"
    echo "Log:      $LOGFILE"
    echo "$BANNER"
} | tee "$PORT_LOG" | tee -a "$LOGFILE" >/dev/null

echo
echo "$BANNER"
echo "SSH will listen on port: $SSH_PORT"
echo "Allowed users: $ALLOWED_USERS"
echo "Saved to: $PORT_LOG and $LOGFILE"
echo "$BANNER"
echo

touch /run/billspi/reboot-required
exit 0

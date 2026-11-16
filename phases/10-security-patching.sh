#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y)
APT_OPTS+=(-o Acquire::Retries=3 -o DPkg::Lock::Timeout=60)

# Function to handle errors
error_exit() {
    # echo "Error occurred during $1, exiting..."
    echo "Error at line ${2:-$LINENO}: ${BASH_COMMAND:-unknown} (${1})" >&2
    exit 1
}

# Step 1: Security Patching
echo "Starting security patching..."

# Download Security Patches (First Pass)
echo "Starting security patch download (First Pass)..."
apt-get -o Acquire::Retries=3 update || error_exit "apt-get update (First Pass)"
apt-get "${APT_OPTS[@]}" --download-only -t trixie-security --with-new-pkgs upgrade  || error_exit "security patch download (First Pass)"
echo "Security patch download completed (First Pass)."

# Download UFW
echo "Starting firewall (UFW) download..."
apt-get "${APT_OPTS[@]}" --download-only --no-install-recommends install ufw || error_exit "prefetch ufw"
echo "Firewall (UFW) download completed."

# Disable network interfaces
# --- Bring network down (Pi OS: NetworkManager or dhcpcd) ---
# Detect active manager
if systemctl is-active --quiet NetworkManager; then
    PI_NET_MGR="nm"
elif systemctl is-active --quiet dhcpcd; then
    PI_NET_MGR="dhcpcd"
else
    PI_NET_MGR="none"
fi
echo "Disabling all non-loopback interfaces (manager: ${PI_NET_MGR})..."
# Record only interfaces currently UP (not lo) so we restore just those
NET_UP_DEVICES="$(ip -o link show up | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -v '^lo$' || true)"

# Ask the manager to stop managing networking, then drop links for good measure
case "$PI_NET_MGR" in
  nm)
    if command -v nmcli >/dev/null 2>&1; then
      nmcli networking off || true
    else
      systemctl stop NetworkManager || true
    fi
    ;;
  dhcpcd)
    systemctl stop dhcpcd || true
    systemctl stop wpa_supplicant 2>/dev/null || true
    ;;
  *)
    : # none
    ;;
esac

#for dev in $NET_UP_DEVICES; do
#    ip link set "$dev" down || true
#done
if [ -n "${NET_UP_DEVICES:-}" ]; then
  for dev in $NET_UP_DEVICES; do ip link set "$dev" down || true; done
fi
echo "Network interfaces disabled."

# Apply downloaded security patches (First Pass)
echo "Applying security patches (First Pass)..."
apt-get "${APT_OPTS[@]}" --no-download -t trixie-security --with-new-pkgs upgrade || error_exit "applying security patches (First Pass)"
echo "Security patches applied (First Pass)."

# Firewall Setup (UFW)
echo "Setting up UFW firewall..."
apt-get "${APT_OPTS[@]}" --no-download --no-install-recommends install ufw || error_exit "UFW installation"
ufw --force default deny incoming || error_exit "UFW deny incoming"
ufw --force default allow outgoing || error_exit "UFW allow outgoing"
ufw logging low || true
ufw --force enable || error_exit "UFW enable"
echo "Firewall setup completed."

# Re-enable network interfaces
# --- Bring network back up (restore only what we took down) ---
echo "Re-enabling network interfaces..."

#for dev in $NET_UP_DEVICES; do
#ip link set "$dev" up || true
#done
if [ -n "${NET_UP_DEVICES:-}" ]; then
  for dev in $NET_UP_DEVICES; do ip link set "$dev" up || true; done
fi

case "$PI_NET_MGR" in
  nm)
    if command -v nmcli >/dev/null 2>&1; then
      nmcli networking on || true
    else
      systemctl restart NetworkManager || true
    fi
    ;;
  dhcpcd)
    systemctl start wpa_supplicant 2>/dev/null || true
    systemctl start dhcpcd || true
    ;;
  *)
    : # none
    ;;
esac
NET_UP_DEVICES=""
echo "Network interfaces re-enabled."

if [[ "$PI_NET_MGR" == "nm" ]]; then
  nm-online -q --timeout=60 || error_exit "NetworkManager reconnection"
fi
timeout 60 bash -c 'until getent ahostsv4 deb.debian.org >/dev/null; do sleep 1; done' \
  || error_exit "DNS readiness after network reconnection"

# Fail2Ban install (do not rely on defaults)
echo "Installing and configuring Fail2Ban..."
apt-get "${APT_OPTS[@]}" --no-install-recommends install fail2ban python3-systemd || error_exit "Fail2Ban installation"
# Create jail.local BEFORE first start, so desired policy is active at first boot
install -d -m 0755 /etc/fail2ban || error_exit "create /etc/fail2ban"
tee /etc/fail2ban/jail.local >/dev/null <<'EOL' || error_exit "write jail.local"
[DEFAULT]
bantime = 1h
findtime = 1h
maxretry = 3
backend = systemd
banaction = ufw
EOL
# (Intentionally no [sshd] jail yet since SSH is configured later)
# Enable and start with our config
systemctl enable --now fail2ban || error_exit "enable/start Fail2Ban"
echo "Fail2Ban installed and started with custom policy."

# Security Patching - Second Pass (while online)
echo "Starting security patch check and application (Second Pass)..."
apt-get -o Acquire::Retries=3 update || error_exit "apt-get update (Second Pass)"
apt-get "${APT_OPTS[@]}" -t trixie-security --with-new-pkgs upgrade || error_exit "security patching (Second Pass)"
echo "Security patches applied (Second Pass)."
echo "Security patching completed."


# ----- Post-flight verification: UFW, Fail2Ban, security upgrades -----
echo "Running post-flight verification..."

# (Optional but recommended: force English for predictable parsing)
export LC_ALL=C LANG=C

FAIL=0

# 1) UFW installed and ACTIVE (use ufw status, not systemd oneshot state)
if ! dpkg-query -W -f='${Status}\n' ufw 2>/dev/null | grep -q 'install ok installed'; then
  echo "UFW: package NOT installed" >&2
  FAIL=1
else
  UFW_STATUS="$(ufw status || true)"
  if echo "$UFW_STATUS" | grep -qi '^Status: active'; then
    echo "UFW: ACTIVE"
    # Verify defaults are sane (deny incoming / allow outgoing)
    UFW_VERBOSE="$(ufw status verbose || true)"
    echo "$UFW_VERBOSE" | grep -qi 'Default: deny (incoming)' || { echo "UFW: default incoming not 'deny'"; FAIL=1; }
    echo "$UFW_VERBOSE" | grep -Fqi 'allow (outgoing)' || { echo "UFW: default outgoing not 'allow'"; FAIL=1; }
  else
    echo "UFW: INACTIVE" >&2
    FAIL=1
  fi
fi

# 2) Fail2Ban installed, enabled, active, and responding
if ! dpkg-query -W -f='${Status}\n' fail2ban 2>/dev/null | grep -q 'install ok installed'; then
  echo "Fail2Ban: package NOT installed" >&2
  FAIL=1
else
  if systemctl is-enabled --quiet fail2ban; then
    echo "Fail2Ban: systemd ENABLED"
  else
    echo "Fail2Ban: NOT enabled" >&2
    FAIL=1
  fi

  if systemctl is-active --quiet fail2ban; then
    echo "Fail2Ban: service ACTIVE"
  else
    echo "Fail2Ban: service INACTIVE" >&2
    FAIL=1
  fi

  if fail2ban-client ping | grep -qi 'pong'; then
    echo "Fail2Ban: client ping OK"
  else
    echo "Fail2Ban: client ping FAILED" >&2
    FAIL=1
  fi

  # Ensure our jail.local exists (you create it earlier)
  if [[ ! -s /etc/fail2ban/jail.local ]]; then
    echo "Fail2Ban: /etc/fail2ban/jail.local missing or empty" >&2
    FAIL=1
  fi
fi

# 3) No pending *security* upgrades (sanity)
#    We consider it OK if there are zero pending packages from the security pocket.
SECURITY_SIMULATION="$(apt-get -s -o Debug::NoLocking=true -t trixie-security dist-upgrade)" \
  || error_exit "security upgrade simulation"
PENDING_SECURITY="$(printf '%s\n' "$SECURITY_SIMULATION" \
  | awk '/^Inst / && /Debian-Security:/{print}')"
if [[ -n "$PENDING_SECURITY" ]]; then
  echo "Security upgrades still pending from trixie-security:" >&2
  echo "$PENDING_SECURITY" >&2
  FAIL=1
else
  echo "Security pocket: no pending upgrades"
fi

# Final verdict
if [[ "$FAIL" -ne 0 ]]; then
  error_exit "post-flight verification failed"
fi

echo "Post-flight verification PASSED."
# ----- end post-flight verification -----

touch /run/billspi/reboot-required
exit 0

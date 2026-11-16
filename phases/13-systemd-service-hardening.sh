#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
# Pi OS Lite: systemd Service Hardening (drop-in overrides)
# Purpose: Clamp blast radius of services with systemd sandboxing defaults; apply per-unit overrides safely.
# Scope: Writes /etc/systemd/system/<unit>.service.d/hardening.conf and reloads systemd. Root required.
#
# What this sets (baseline):
# - Privilege: NoNewPrivileges=yes, RestrictSUIDSGID=yes, LockPersonality=yes, RestrictNamespaces=yes
# - Memory/exec: MemoryDenyWriteExecute=yes, SystemCallArchitectures=native
# - Filesystem: ProtectSystem=strict, ProtectHome=yes, PrivateTmp=yes, PrivateDevices=yes, DevicePolicy=closed
# - Kernel: ProtectKernel{Logs,Modules,Tunables}=yes, ProtectControlGroups=yes, ProtectClock=yes, ProtectProc=invisible, ProcSubset=pid
# - Network: IPAddressDeny=any by default; relaxed automatically if AF includes inet/inet6
# - Address families: RestrictAddressFamilies=<from --af>; default "unix"
# - Capabilities: drop all by default; keep only those passed with --caps
#
# Notes:
# - --af tokens are mapped to systemd names (inet->AF_INET, inet6->F_INET6, unix->AF_UNIX, etc.).
# - If AF includes inet/inet6, IPAddressDeny=any is auto-relaxed with IPAddressAllow=any.
# - By default all capabilities are dropped; use --caps to retain only the minimal set required.
#
# Usage:
#   13-systemd-service-hardening.sh <unit.service> [--preset generic|web|db|cache]
#                                   [--writable /var/lib/foo,/var/log/foo,/run/foo]
#                                   [--caps CAP_NET_BIND_SERVICE[,...]] [--af inet,inet6,unix]
#                                   [--dynamic-user] [--dry-run]
# Examples:
#   ./13-systemd-service-hardening.sh nginx.service --preset web \
#       --writable /var/log/nginx,/run/nginx --caps CAP_NET_BIND_SERVICE --af inet,inet6
#   ./13-systemd-service-hardening.sh redis-server.service --preset db \
#       --writable /var/lib/redis,/var/log/redis,/run/redis --af inet,inet6,unix
#
# Flags:
# - --preset: sets sensible AF/caps defaults for common roles (still overridable)
# - --writable: comma list of paths that must remain writable under ProtectSystem=strict (generates ReadWritePaths= lines)
# - --caps: comma list of capabilities to retain (else all dropped)
# - --af: comma list of address families to allow (e.g., inet,inet6,unix)
# - --dynamic-user: enable DynamicUser=yes if the service is stateless and writes only to /run
# - --dry-run: print planned drop-in without writing or reloading
#
# Cautions:
# - Most breakages come from missing writable paths when ProtectSystem=strict is on. Add them with --writable.
# - For ports <1024, either use --caps CAP_NET_BIND_SERVICE or socket activation.
# - DynamicUser=yes is not suitable for services that need fixed ownership under /var/lib.
#
# Rollback:
# - Remove /etc/systemd/system/<unit>.service.d/hardening.conf and `systemctl daemon-reload`
# - Or override specific keys in another drop-in file (higher priority in the same directory)
#
# Verify:
# - systemd-analyze verify <unit.service>
# - systemctl show <unit> -p NoNewPrivileges -p ProtectSystem -p RestrictAddressFamilies -p CapabilityBoundingSet -p ReadWritePaths
#
# 13-systemd-service-hardening.sh
# Apply systemd sandboxing to a service via drop-in override (Pi OS Lite / Debian 12).
set -Eeuo pipefail
IFS=$'\n\t'

usage() {
  cat <<'USAGE'
Usage: 13-systemd-service-hardening.sh <unit.service> [--preset generic|web|db|cache]
       [--writable /var/lib/foo,/var/log/foo,/run/foo] [--caps CAP_NET_BIND_SERVICE]
       [--af inet,inet6,unix] [--dynamic-user] [--dry-run]

Examples:
  ./13-systemd-service-hardening.sh nginx.service --preset web \
    --writable /var/log/nginx,/run/nginx --caps CAP_NET_BIND_SERVICE --af inet,inet6

  ./13-systemd-service-hardening.sh redis-server.service --preset db \
    --writable /var/lib/redis,/var/log/redis,/run/redis --af inet,inet6,unix
USAGE
}

# The runner has no service target configured for this argument-driven helper.
if [[ $# -eq 0 ]]; then
  echo "No service target configured; skipping service-specific hardening."
  exit 0
fi

UNIT="$1"; shift || true
[[ "$UNIT" != *.service ]] && UNIT="${UNIT}.service"

PRESET="generic"
WRITABLE=""
CAPS=""
AF=""
AF_SET=0
CAPS_SET=0
DYNAMIC=0
DRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preset) PRESET="$2"; shift 2;;
    --writable) WRITABLE="$2"; shift 2;;
    --caps) CAPS="$2"; CAPS_SET=1; shift 2;;
    --af) AF="$2"; AF_SET=1; shift 2;;
    --dynamic-user) DYNAMIC=1; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

# Unit must exist (works even if inactive)
if ! systemctl cat "$UNIT" >/dev/null 2>&1; then
  echo "Unit not found: $UNIT" >&2
  exit 1
fi

# Preset defaults (respect explicit flags)
case "$PRESET" in
  generic) : ;;
  web)
    [[ $AF_SET -eq 0 ]] && AF="inet,inet6,unix"
    [[ $CAPS_SET -eq 0 ]] && CAPS="CAP_NET_BIND_SERVICE"
    ;;
  db|cache)
    [[ $AF_SET -eq 0 ]] && AF="inet,inet6,unix"
    ;;
  *) echo "Unknown preset: $PRESET" >&2; exit 2;;
esac
[[ -z "$AF" ]] && AF="unix"

# Map --af tokens to systemd AF_* names
to_af_names() {
  local in="$1" out= t
  IFS=',' read -r -a toks <<<"$in"
  for t in "${toks[@]}"; do
    case "${t,,}" in
      unix|local)     out+="AF_UNIX ";;
      inet|ipv4)      out+="AF_INET ";;
      inet6|ipv6)     out+="AF_INET6 ";;
      netlink)        out+="AF_NETLINK ";;
      packet)         out+="AF_PACKET ";;
      bluetooth|bt)   out+="AF_BLUETOOTH ";;
      *)              out+="$t ";;  # allow already-formed AF_* or numeric
    esac
  done
  echo "${out%% }"
}
RestrictAddressFamilies="$(to_af_names "$AF")"

# Capabilities (default: drop all)
CapabilityBoundingSet=""
AmbientCapabilities=""
if [[ -n "$CAPS" ]]; then
  CapabilityBoundingSet="${CAPS//,/ }"
  AmbientCapabilities="$CapabilityBoundingSet"
fi

# Writable paths (one ReadWritePaths= per path)
ReadWritePaths=""
if [[ -n "$WRITABLE" ]]; then
  ReadWritePaths="$(
    tr ',' '\n' <<<"$WRITABLE" |
    while IFS= read -r path; do
      path="${path//\\/\\\\}"
      path="${path//\"/\\\"}"
      if [[ -n "$path" ]]; then
        printf 'ReadWritePaths="%s"\n' "$path"
      else
        printf 'ReadWritePaths=\n'
      fi
    done
  )"
fi

# Dynamic user line
DynamicUserLine=""
[[ $DYNAMIC -eq 1 ]] && DynamicUserLine="DynamicUser=yes"

# Hardened defaults
read -r -d '' DROPIN <<"EOF" || true
# --- Systemd Sandbox Hardening ---
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectControlGroups=yes
ProtectKernelLogs=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectClock=yes
ProtectProc=invisible
ProcSubset=pid
PrivateDevices=yes
DevicePolicy=closed
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
# Add SystemCallFilter= per service after testing.
# Networking default: deny all IP; will be relaxed below if AF includes inet/inet6.
IPAddressDeny=any
EOF

# Networking relaxations
NET_BLOCK=""
if [[ -n "$RestrictAddressFamilies" ]]; then
  NET_BLOCK+="RestrictAddressFamilies=${RestrictAddressFamilies}"$'\n'
fi
if grep -qE '\bAF_INET\b|\bAF_INET6\b' <<<"$RestrictAddressFamilies"; then
  NET_BLOCK+="IPAddressAllow=any"$'\n'
fi

# Compose optional blocks
CAP_BLOCK="CapabilityBoundingSet=${CapabilityBoundingSet}
AmbientCapabilities=${AmbientCapabilities}"
[[ -z "$CapabilityBoundingSet" ]] && CAP_BLOCK="CapabilityBoundingSet=
AmbientCapabilities="

DYN_BLOCK="${DynamicUserLine}"
RWP_BLOCK="${ReadWritePaths}"

# Output drop-in
OUT_DIR="/etc/systemd/system/${UNIT}.d"
OUT_FILE="${OUT_DIR}/hardening.conf"
mkdir -p "$OUT_DIR"

{
  echo "[Service]"
  printf "%s\n" "$DROPIN"
  [[ -n "$NET_BLOCK" ]] && printf "%s" "$NET_BLOCK"
  printf "%s\n" "$CAP_BLOCK"
  [[ -n "$DYN_BLOCK" ]] && printf "%s\n" "$DYN_BLOCK"
  [[ -n "$RWP_BLOCK" ]] && printf "%s\n" "$RWP_BLOCK"
} > /tmp/.hardening.$$

echo "Planned drop-in for ${UNIT}:"
echo "----------------------------------------"
cat /tmp/.hardening.$$
echo "----------------------------------------"

if [[ "$DRY" -eq 1 ]]; then
  echo "(dry-run) Not writing or reloading."
  rm -f /tmp/.hardening.$$
  exit 0
fi

install -m 0644 /tmp/.hardening.$$ "$OUT_FILE"
rm -f /tmp/.hardening.$$

systemctl daemon-reload

verify_out="$(systemd-analyze verify "$UNIT" 2>&1 || true)"
if [[ -n "$verify_out" ]]; then
  printf '%s\n' "$verify_out" | sed 's/^/verify: /'
fi

echo "Effective sandbox (subset):"
systemctl show "$UNIT" \
  -p NoNewPrivileges -p PrivateTmp -p ProtectSystem -p ProtectHome \
  -p RestrictSUIDSGID -p MemoryDenyWriteExecute -p RestrictNamespaces \
  -p CapabilityBoundingSet -p AmbientCapabilities -p RestrictAddressFamilies \
  -p IPAddressDeny -p IPAddressAllow -p ReadWritePaths -p DynamicUser \
  | sed 's/^/  /'

echo "Apply with: systemctl restart ${UNIT}"

touch /run/billspi/reboot-required
exit 0

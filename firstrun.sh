#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

log(){ echo "[billspi firstrun] $*"; logger -t billspi-firstrun "$*"; }

BOOT="/boot"; [ -d /boot/firmware ] && BOOT="/boot/firmware"
PAYLOAD_DIR="$BOOT/billspi"

log "Starting first-boot bootstrap."

# 1) Install Bill's Pi files into the rootfs
install -d -m 0755 /usr/local/lib/billspi/phases
install -d -m 0755 /usr/local/sbin

if [ -d "$PAYLOAD_DIR/phases" ]; then
    install -m 0755 "$PAYLOAD_DIR"/phases/*.sh /usr/local/lib/billspi/phases/ || true
fi

install -m 0755 "$PAYLOAD_DIR"/billspi-runner /usr/local/sbin/billspi-runner
install -m 0644 "$PAYLOAD_DIR"/billspi-setup.service /etc/systemd/system/billspi-setup.service

systemctl daemon-reload
systemctl enable billspi-setup.service

# Enable wait-online only for the active/installed stack
if command -v nm-online >/dev/null 2>&1 && systemctl is-enabled NetworkManager >/dev/null 2>&1; then
    systemctl enable NetworkManager-wait-online.service || true
elif systemctl is-enabled systemd-networkd >/dev/null 2>&1; then
    systemctl enable systemd-networkd-wait-online.service || true
else
    # dhcpcd-based setups generally have no dedicated wait-online unit
    :
fi

# 2) Clean up cmdline parameters we added for first boot
if [ -f "$BOOT/cmdline.txt" ]; then
    sed -i -E \
    -e 's#[[:space:]]*systemd\.run=[^ ]+##g' \
    -e 's#[[:space:]]*systemd\.run_success_action=[^ ]+##g' \
    -e 's#[[:space:]]*systemd\.unit=kernel-command-line\.target##g' \
    "$BOOT/cmdline.txt" || true
fi

# 3) Remove bootstrap artifacts
rm -f "$BOOT/firstrun.sh" "$BOOT/cmdline-append.txt" 2>/dev/null || true

log "Bootstrap complete. Continuing normal boot."

# Continue with a normal boot to multi-user target (so SSH/TTYs come up)
systemctl start --no-block multi-user.target

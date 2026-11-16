# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
#LUKS:
#Full disk encryption adds strong physical security but complicates unattended boots (needs remote-unlock in initramfs like dropbear, or a local prompt).
#A pragmatic middle ground: encrypt data volumes (databases/backups) with LUKS, keep root unencrypted for headless boots.
#Always combine with encrypted, versioned backups (e.g., restic/borg) stored off-box.
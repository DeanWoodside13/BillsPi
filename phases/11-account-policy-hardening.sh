#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
# Pi OS Lite: Account Policy Hardening (PAM + UMASK + System Accounts)
# Purpose: Enforce local login lockouts, tighten default file permissions, and prevent interactive shells on system users.
# Scope: Enables pam_faillock via pam-auth-update, sets UMASK 027 in /etc/login.defs, and (optionally) switches interactive shells
#        for UID<1000 service accounts to /usr/sbin/nologin. Designed for Raspberry Pi OS (Debian 12/Bookworm). Root required.
#
# What this config does:
# - pam_faillock: Locks accounts after 3 failed attempts for 10 minutes (deny=3, unlock_time=600, even_deny_root).
#                 Applies to local TTY, sudo, and su via Debian's common-* PAM stack. SSH key-only logins are unaffected.
# - UMASK 027   : New files default to 640 and directories to 750 (reduces world access). Does not change existing files.
# - System users: Optional DRY RUN by default. When enabled, converts interactive shells for UID<1000 users to nologin and password-locks them,
#                 excluding root, the current user, and SUDO_USER.
#
# Controls:
# - LOCK_SYSTEM_SHELLS=1   # Apply the shell lockdown (default 0 = dry-run only).
# - LC_ALL=C               # Ensures deterministic parsing/messages; set by the script.
#
# Packages required:
# - libpam-modules, libpam-modules-bin, libpam-runtime  (installed if missing).
#
# Idempotency:
# - Safe to re-run. pam-auth-update profile is created/enabled once; UMASK line is replaced or appended; lockdown loop skips already-locked users.
#
# Rollback:
# - Disable faillock: pam-auth-update --disable faillock-hardening --package --force
# - Clear lockouts:   faillock --reset
# - Restore UMASK:    edit /etc/login.defs and set UMASK back to 022 (or your preferred value)
# - Revert shells:    usermod -s /bin/bash <user> ; passwd -u <user>   (for any service account you intentionally re-enable)
#
# Verify:
# - PAM profile:      pam-auth-update --list | grep -F '[enabled] faillock-hardening'
# - Test lockouts:    run incorrect sudo password 3x, then check `faillock`
# - UMASK:            umask in a fresh login shell should show 0027; new files come out 640, dirs 750
# - System users:     getent passwd | awk -F: '$3<1000{print $1,$7}'  (should show /usr/sbin/nologin for locked accounts)
#
set -Eeuo pipefail
IFS=$'\n\t'

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y)
APT_OPTS+=(-o Acquire::Retries=3 -o DPkg::Lock::Timeout=60)

# Step X: Local account policy - pam_faillock, UMASK, system-account shells
echo "Hardening local account policy (pam_faillock, UMASK, system accounts)..."

export LC_ALL=C LANG=C

# X.1 Ensure PAM modules present (usually already installed)
apt-get -o Acquire::Retries=3 update || true
apt-get "${APT_OPTS[@]}" --no-install-recommends install libpam-modules libpam-modules-bin libpam-runtime

# X.2 Configure pam_faillock via pam-auth-update (Debian-native, idempotent)
#     Locks account after 3 failed attempts for 10 minutes (also protects sudo/su/local TTY).
FAILLOCK_PROFILE="/usr/share/pam-configs/faillock-hardening"
if [[ ! -s "$FAILLOCK_PROFILE" ]]; then
  tee "$FAILLOCK_PROFILE" >/dev/null <<'EOF'
Name: faillock-hardening
Default: no
Priority: 900
Auth-Type: Primary
Auth:
        required                        pam_faillock.so preauth silent deny=3 unlock_time=600 even_deny_root
        [success=1 default=bad]         pam_unix.so nullok
        [default=die]                   pam_faillock.so authfail deny=3 unlock_time=600 even_deny_root
Account-Type: Additional
Account:
        required                        pam_faillock.so
Session-Type: Additional
Session:
        optional                        pam_umask.so nousergroups
EOF
fi

if command -v pam-auth-update >/dev/null 2>&1; then
  pam-auth-update --enable faillock-hardening --package --force || echo "WARN: pam-auth-update failed"
else
  echo "WARN: pam-auth-update not found; skipping PAM profile enable"
fi

# X.3 Set UMASK 027 in /etc/login.defs (idempotent)
if grep -Eq '^[#[:space:]]*UMASK[[:space:]]+' /etc/login.defs; then
  sed -ri 's~^[#[:space:]]*UMASK[[:space:]]+.*~UMASK 027~' /etc/login.defs
else
  echo 'UMASK 027' | tee -a /etc/login.defs >/dev/null
fi

# X.4 Optional: lock shells for *interactive* system accounts (safe default: DRY RUN)
#     Set LOCK_SYSTEM_SHELLS=1 in environment to apply changes.
LOCK_SYSTEM_SHELLS="${LOCK_SYSTEM_SHELLS:-0}"
NLOGIN=/usr/sbin/nologin
# Candidates: UID < 1000, real interactive shell, not root
#mapfile -t _cand < <(awk -F: '$3<1000 && $1!="root" && ($7=="/bin/bash" || $7=="/bin/sh"){print $1":"$7}' /etc/passwd || true)
mapfile -t _cand < <(awk -F: -v cu="$(id -un)" -v su="${SUDO_USER:-}" '$3<1000 && $1!="root" && $1!=cu && $1!=su && ($7=="/bin/bash" || $7=="/bin/sh"){print $1":"$7}' /etc/passwd || true)

if (( ${#_cand[@]} )); then
  echo "System accounts with interactive shells detected: ${#_cand[@]}"
  for entry in "${_cand[@]}"; do
    acc="${entry%%:*}"; shl="${entry#*:}"
    if [[ "$LOCK_SYSTEM_SHELLS" == "1" ]]; then
      usermod -s "$NLOGIN" "$acc" || echo "WARN: Failed to set nologin for $acc"
      passwd -l "$acc" >/dev/null || true
      echo "Locked shell for $acc ($shl -> $NLOGIN)"
    else
      echo "(DRY RUN) Would lock shell for $acc ($shl -> $NLOGIN)"
    fi
  done
else
  echo "No interactive system-account shells found to lock."
fi

touch /run/billspi/reboot-required
exit 0
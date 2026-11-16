#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

apt-get update
apt-get install -y --no-install-recommends openssl parallel coreutils rhash

umask 022
install -d /usr/local/bin

# ---------- md5sum wrapper ----------
cat >/usr/local/bin/md5sum <<'EOF'
#!/bin/sh
# Wrapper: fast parallel MD5 for file args via OpenSSL; exact coreutils behavior otherwise.

REAL=/usr/bin/md5sum
OSSL=/usr/bin/openssl
PAR=/usr/bin/parallel
ALG="-md5"

# If any options are present, or no args, or "-" (stdin), use the real tool for exact semantics
for a in "$@"; do
  case "$a" in
    -*|*\\*|*"$(printf '\r')"*|*'
'*) exec "$REAL" "$@";;
  esac
done
[ $# -eq 0 ] && exec "$REAL" "$@"
for a in "$@"; do [ "$a" = "-" ] && exec "$REAL" "$@"; done

fmt() { sed -E 's/^([0-9a-fA-F]+) \*/\1  /'; }

tmp="$(mktemp)"; rc=0
trap 'rm -f "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ $# -eq 1 ]; then
  "$OSSL" dgst $ALG -r -- "$1" >"$tmp" || rc=1
else
  if command -v "$PAR" >/dev/null 2>&1; then
    printf '%s\0' "$@" | "$PAR" -0 -k -j+0 --will-cite -- "$OSSL" dgst $ALG -r -- >"$tmp" || rc=1
  else
    # No parallel: do it sequentially but still faster than coreutils
    rc=0
    for f in "$@"; do
      "$OSSL" dgst $ALG -r -- "$f" >>"$tmp" || rc=1
    done
  fi
fi

# Reformat OpenSSL output to match coreutils: "hash filename"
fmt <"$tmp" || rc=1
exit "$rc"
EOF
chmod 0755 /usr/local/bin/md5sum

# ---------- sha256sum wrapper ----------
cat >/usr/local/bin/sha256sum <<'EOF'
#!/bin/sh
REAL=/usr/bin/sha256sum
OSSL=/usr/bin/openssl
PAR=/usr/bin/parallel
ALG="-sha256"

for a in "$@"; do
  case "$a" in
    -*|*\\*|*"$(printf '\r')"*|*'
'*) exec "$REAL" "$@";;
  esac
done
[ $# -eq 0 ] && exec "$REAL" "$@"
for a in "$@"; do [ "$a" = "-" ] && exec "$REAL" "$@"; done

fmt() { sed -E 's/^([0-9a-fA-F]+) \*/\1  /'; }

tmp="$(mktemp)"; rc=0
trap 'rm -f "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ $# -eq 1 ]; then
  "$OSSL" dgst $ALG -r -- "$1" >"$tmp" || rc=1
else
  if command -v "$PAR" >/dev/null 2>&1; then
    printf '%s\0' "$@" | "$PAR" -0 -k -j+0 --will-cite -- "$OSSL" dgst $ALG -r -- >"$tmp" || rc=1
  else
    rc=0
    for f in "$@"; do
      "$OSSL" dgst $ALG -r -- "$f" >>"$tmp" || rc=1
    done
  fi
fi

fmt <"$tmp" || rc=1
exit "$rc"
EOF
chmod 0755 /usr/local/bin/sha256sum

# ---------- sha512sum wrapper ----------
cat >/usr/local/bin/sha512sum <<'EOF'
#!/bin/sh
REAL=/usr/bin/sha512sum
OSSL=/usr/bin/openssl
PAR=/usr/bin/parallel
ALG="-sha512"

for a in "$@"; do
  case "$a" in
    -*|*\\*|*"$(printf '\r')"*|*'
'*) exec "$REAL" "$@";;
  esac
done
[ $# -eq 0 ] && exec "$REAL" "$@"
for a in "$@"; do [ "$a" = "-" ] && exec "$REAL" "$@"; done

fmt() { sed -E 's/^([0-9a-fA-F]+) \*/\1  /'; }

tmp="$(mktemp)"; rc=0
trap 'rm -f "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ $# -eq 1 ]; then
  "$OSSL" dgst $ALG -r -- "$1" >"$tmp" || rc=1
else
  if command -v "$PAR" >/dev/null 2>&1; then
    printf '%s\0' "$@" | "$PAR" -0 -k -j+0 --will-cite -- "$OSSL" dgst $ALG -r -- >"$tmp" || rc=1
  else
    rc=0
    for f in "$@"; do
      "$OSSL" dgst $ALG -r -- "$f" >>"$tmp" || rc=1
    done
  fi
fi

fmt <"$tmp" || rc=1
exit "$rc"
EOF
chmod 0755 /usr/local/bin/sha512sum


# /usr/local/bin/crc32 wrapper:
# - Single file: rhash --crc32
# - Many files: use GNU Parallel if available (-k keeps input order)
# - STDIN: supported (prints "HASH  -")
# - Output: SFV-style "HASH  filename"
# - Exit code: non-zero if any hashing fails
cat >/usr/local/bin/crc32 <<'EOF'
#!/bin/sh
RHASH=/usr/bin/rhash
PAR=/usr/bin/parallel

if ! command -v "$RHASH" >/dev/null 2>&1; then
  echo "crc32: 'rhash' not found (apt-get install rhash)" >&2
  exit 127
fi

# If no args: read stdin as a single stream and label as "-"
if [ "$#" -eq 0 ]; then
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  cat >"$tmp" || exit 1
  rc=0
  out=$("$RHASH" --crc32 --simple -- "$tmp") || rc=$?
  printf '%s  -\n' "$(printf '%s\n' "$out" | awk '{print $1}')" || rc=1
  exit "$rc"
fi

# If any "-" appears, process sequentially to preserve order and reuse stdin once
stdin_seen=0
for a in "$@"; do [ "$a" = "-" ] && stdin_seen=1 && break; done
if [ "$stdin_seen" -eq 1 ]; then
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # Read stdin once up-front if "-" occurs anywhere
  cat >"$tmp" || exit 1
  rc_all=0
  for f in "$@"; do
    if [ "$f" = "-" ]; then
      out=$("$RHASH" --crc32 --simple -- "$tmp") || rc_all=1
      printf '%s  -\n' "$(printf '%s\n' "$out" | awk '{print $1}')" || rc_all=1
    else
      "$RHASH" --crc32 --simple -- "$f" || rc_all=1
    fi
  done
  exit "$rc_all"
fi

# No "-" present: many files -> parallel if available, else sequential
if command -v "$PAR" >/dev/null 2>&1 && [ "$#" -gt 1 ]; then
  # One job per file; keep output order; suppress citation
  printf '%s\0' "$@" | "$PAR" -0 -k -j+0 --will-cite -- "$RHASH" --crc32 --simple --
else
  rc_all=0
  for f in "$@"; do
    "$RHASH" --crc32 --simple -- "$f" || rc_all=1
  done
  exit "$rc_all"
fi
EOF
chmod 0755 /usr/local/bin/crc32
# --- Optional quick checks (manual) ---
# type -a crc32
# printf test | crc32
# crc32 /etc/hosts /etc/services | head


# ---------- Ensure cron sees /usr/local/bin first ----------
if grep -qE '^PATH=' /etc/crontab; then
  sed -r -i 's|^PATH=.*$|PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin|' /etc/crontab
else
  printf '\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n' >> /etc/crontab
fi

# ---------- Ensure systemd services see /usr/local/bin ----------
install -d /etc/systemd/system.conf.d
cat >/etc/systemd/system.conf.d/10-path.conf <<'EOF'
[Manager]
DefaultEnvironment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF
# Apply the systemd manager env update
systemctl daemon-reexec || true

# ---------- Quick self-check hints (optional) ----------
# type -a sha256sum
# sha256sum --version  # should show GNU coreutils (fallback) info when you pass --version
# sha256sum /etc/hosts /etc/services | head

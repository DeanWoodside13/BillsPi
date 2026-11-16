#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
# BillsPi diagnostic collector 1.2 — tailored to BillsPi 1.0.0.53.
# Run on the LIVE Pi after provisioning has finished or stopped with an error.
# Usage: sudo /bin/bash billspi-diagnostics.sh [EXISTING_OUTPUT_DIRECTORY]
# No installation, network requests, configuration changes, benchmarks or repairs.
# Only the collector's private staging directory and result archive are written.
# Logs are bounded and redacted on a best-effort basis; read SUMMARY.txt first.

set -uo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C LANG=C SYSTEMD_PAGER=cat SYSTEMD_COLORS=0
unset LD_PRELOAD LD_LIBRARY_PATH BASH_ENV ENV
umask 077

usage() {
    cat <<'HELP'
BillsPi diagnostic collector 1.2 (Bash; no additional packages required)

Run on the Raspberry Pi, not on Ubuntu:
  sudo /bin/bash /path/to/billspi-diagnostics.sh
  sudo /bin/bash /path/to/billspi-diagnostics.sh /home/pi

The optional output directory must already exist. Default: /var/tmp.
One billspi-diagnostics-TIMESTAMP-RANDOM.tar.gz file is produced.
Choose your mounted USB directory to write the archive directly onto the stick.
Otherwise use sudo cp to copy it there; the script prints its exact path.
Run after the BillsPi installer finishes or stops. Do not reboot for collection.
The collector never mounts/unmounts USB devices or uploads any data.

The archive contains SUMMARY.txt, README.txt, command-status.tsv,
configuration/log snapshots, and a SHA-256 manifest of its collected files.
Private keys, shadow files, Wi-Fi profiles, APT auth files and the provisioning
password scripts are excluded. Logs may still contain identifying information
or unrecognized secrets; review the archive before sharing it publicly.
The installation transcript is collected first, up to 32 MiB. The complete
original is never modified. Previously discarded RAM journals cannot be recovered.
Exit 0 means the archive was created, not that every system check passed.
HELP
}

fatal() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
WORK=''
ARCHIVE=''
FINISHED=0
cleanup() {
    if [[ -n "$WORK" && -d "$WORK" ]]; then /usr/bin/rm -rf -- "$WORK"; fi
    if [[ "$FINISHED" != 1 && -n "$ARCHIVE" && -f "$ARCHIVE" ]]; then
        /usr/bin/rm -f -- "$ARCHIVE"
    fi
}

# All command output passes through this bounded collector. Its drain prevents
# the byte cap from causing SIGPIPE in an otherwise successful diagnostic.
capture() {
    local ident=$1 seconds=$2 limit=$3
    shift 3
    local raw="$WORK/capture.raw" dest="$DATA/commands/$ident.txt"
    local resolved rc drain_rc count truncated=0 started ended head_rc cat_rc remaining
    local -a pipe_status shift_command
    started=$(/usr/bin/date -u '+%FT%TZ')
    resolved=$(type -P -- "$1" 2>/dev/null || true)
    remaining=$((67108864 - CAPTURE_BYTES))
    if (( remaining < 4096 )); then
        printf '%s\t125\t0\t0\tSKIPPED_TOTAL_SIZE_LIMIT\n' "$ident" >> "$DATA/command-status.tsv" || fatal 'Cannot write status index.'
        LAST_RC=125
        return 0
    fi
    (( limit <= remaining - 2048 )) || limit=$((remaining - 2048))
    if [[ -z "$resolved" || ! -x "$resolved" ]]; then
        printf 'Command unavailable: %s\n' "$1" > "$raw" || fatal 'Cannot write capture file.'
        rc=127; drain_rc=0
    else
        shift_command=("$resolved" "${@:2}")
        /usr/bin/timeout --kill-after=5s "${seconds}s" "${shift_command[@]}" </dev/null 2>&1 |
            { /usr/bin/head -c "$((limit + 1))"; head_rc=$?; /usr/bin/cat >/dev/null; cat_rc=$?; (( head_rc == 0 && cat_rc == 0 )); } > "$raw"
        pipe_status=("${PIPESTATUS[@]}")
        rc=${pipe_status[0]}; drain_rc=${pipe_status[1]}
        [[ "$drain_rc" == 0 ]] || fatal 'Output capture failed (check free space).'
    fi
    count=$(/usr/bin/stat -c %s -- "$raw") || fatal 'Cannot measure capture.'
    if (( count > limit )); then
        truncated=1
        /usr/bin/truncate -s "$limit" -- "$raw" || fatal 'Cannot limit capture.'
    fi
    ended=$(/usr/bin/date -u '+%FT%TZ')
    {
        printf 'START_UTC: %s\nEND_UTC: %s\nCOMMAND: ' "$started" "$ended"
        printf '%q ' "$@"
        printf '\nEXIT_STATUS: %s\nTRUNCATED: %s\n' "$rc" "$truncated"
        [[ "$rc" != 124 && "$rc" != 137 ]] || printf 'TIME_LIMIT: reached or process killed; inspect output.\n'
        printf '%s\n' '--- output (best-effort redaction) ---'
        /usr/bin/awk -f "$WORK/redact.awk" "$raw"
    } > "$dest" || fatal 'Cannot write diagnostic output.'
    count=$(/usr/bin/stat -c %s -- "$dest") || fatal 'Cannot measure report output.'
    CAPTURE_BYTES=$((CAPTURE_BYTES + count))
    /usr/bin/rm -f -- "$raw"
    printf '%s\t%s\t%s\t%s\t%s\n' "$ident" "$rc" "$truncated" "$count" "commands/$ident.txt" >> "$DATA/command-status.tsv" || fatal 'Cannot write status index.'
    LAST_RC=$rc
    return 0
}

finding() {
    printf '[%s] %s\n' "$1" "$2" >> "$DATA/SUMMARY.txt" || fatal 'Cannot write summary.'
}

section() { printf '\n[%s] %s\n' "$(/usr/bin/date -u '+%H:%M:%S')" "$1"; }

file_snapshot() {
    local src=$1 resolved
    [[ -f "$src" ]] || return 0
    if [[ -L "$src" ]]; then
        printf '%s\tSKIPPED_SYMLINK\n' "$src" >> "$DATA/file-index.tsv" || fatal 'Cannot write file index.'
        return 0
    fi
    resolved=$(/usr/bin/readlink -f -- "$src") || return 0
    case "$resolved" in
        /etc/shadow*|/etc/gshadow*|*/.ssh/*|*/system-connections/*|*/auth.conf*|*/PrepBill.sh|*/firstrun.sh|/etc/ssh/ssh_host_*_key)
            printf '%s\tEXCLUDED_CREDENTIAL_PATH\n' "$src" >> "$DATA/file-index.tsv" || fatal 'Cannot write file index.'
            return 0 ;;
    esac
    FILE_COUNT=$((FILE_COUNT + 1))
    local label
    printf -v label 'file-%04d' "$FILE_COUNT"
    printf '%s\t%s\n' "$src" "commands/$label.txt" >> "$DATA/file-index.tsv" || fatal 'Cannot write file index.'
    /usr/bin/stat -c '%a %u:%g %s %n' -- "$src" >> "$DATA/file-metadata.txt" 2>/dev/null || true
    capture "$label" 10 262144 /usr/bin/cat -- "$src"
}

log_snapshot() {
    local src=$1 label
    [[ -f "$src" && ! -L "$src" ]] || return 0
    FILE_COUNT=$((FILE_COUNT + 1)); printf -v label 'log-%04d' "$FILE_COUNT"
    printf '%s\t%s\n' "$src" "commands/$label.txt" >> "$DATA/file-index.tsv" || fatal 'Cannot write file index.'
    case "$src" in
        *.gz) capture "$label" 15 1048576 /usr/bin/gzip -cd -- "$src" ;;
        *) capture "$label" 15 1048576 /usr/bin/tail -n 6000 -- "$src" ;;
    esac
}

# Preserve the beginning and complete normal-sized installation transcript.
# Its separate 32 MiB allowance takes priority over later diagnostics.
installation_snapshot() {
    local src=$1
    if [[ ! -f "$src" || -L "$src" ]]; then
        finding REVIEW 'Installation transcript is absent or a symlink; see logging state.'
        return 0
    fi
    printf '%s\t%s\n' "$src" 'commands/installation-transcript.txt' >> "$DATA/file-index.tsv" || fatal 'Cannot write file index.'
    capture installation-transcript-metadata 10 524288 /usr/bin/stat -c '%a %u:%g %s %n' -- "$src"
    capture installation-transcript 30 33554432 /usr/bin/cat -- "$src"
    if (( $(/usr/bin/stat -c %s -- "$src") > 33554432 )); then
        finding REVIEW 'Installation transcript exceeds 32 MiB; only its beginning is exported. The complete original remains on the Pi.'
    fi
}

# END FUNCTIONS — tests exercise these functions without running main on Ubuntu.

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then usage; exit 0; fi
(( $# <= 1 )) || { usage >&2; exit 2; }
[[ $EUID == 0 ]] || fatal 'Run this on the Pi with sudo /bin/bash billspi-diagnostics.sh.'
[[ -r /proc/device-tree/model ]] || fatal 'This must run on the live Raspberry Pi, not on an Ubuntu-mounted card.'
MODEL=$(/usr/bin/tr -d '\000' </proc/device-tree/model)
[[ "$MODEL" == *'Raspberry Pi 5'* ]] || fatal "Expected Raspberry Pi 5; detected: $MODEL"

for required in timeout head cat stat truncate awk mktemp tar gzip sha256sum date readlink df mkdir rm sort xargs grep sed tr; do
    type -P "$required" >/dev/null || fatal "Required system command missing: $required"
done
OUT_DIR=$(/usr/bin/readlink -f -- "${1:-/var/tmp}") || fatal 'Cannot resolve output directory.'
[[ -d "$OUT_DIR" && -w "$OUT_DIR" ]] || fatal 'Output directory must already exist and be writable.'
AVAILABLE_KB=$(/usr/bin/df -Pk /var/tmp | /usr/bin/awk 'END {print $4}')
[[ "$AVAILABLE_KB" =~ ^[0-9]+$ ]] || fatal 'Cannot determine staging free space.'
(( AVAILABLE_KB >= 262144 )) || fatal 'At least 256 MiB free in /var/tmp is required for collection.'
WORK=$(/usr/bin/mktemp -d /var/tmp/billspi-diagnostics.XXXXXXXX) || fatal 'Cannot create private staging directory.'
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
DATA="$WORK/report"
/usr/bin/mkdir -p "$DATA/commands" || fatal 'Cannot create report directory.'
FILE_COUNT=0; LAST_RC=0; CAPTURE_BYTES=0
printf 'id\texit_status\ttruncated\tstored_bytes\tfile\n' > "$DATA/command-status.tsv" || fatal 'Cannot initialize command index.'
printf 'source\tcollected_file_or_disposition\n' > "$DATA/file-index.tsv" || fatal 'Cannot initialize file index.'

cat > "$WORK/redact.awk" <<'AWK'
# Exclude key blocks and redact common credentials without modifying originals.
/-----BEGIN .*PRIVATE KEY-----/ { private_block=1; print "[PRIVATE KEY BLOCK REDACTED]"; next }
private_block { if ($0 ~ /-----END .*PRIVATE KEY-----/) private_block=0; next }
{
    s=$0; low=tolower(s)
    if (low ~ /(authorization["']?[[:space:]]*:|pi_pass_plain|(password|passwd|passphrase|psk|secret|token|api[_-]?key)["']?[[:space:]]*[:=]|[?&](token|key|password|secret)=|--?(password|passphrase|token|secret)([[:space:]]|=))/) {
        print "[POSSIBLE CREDENTIAL LINE REDACTED]"; next
    }
    if (s ~ /\$(y|gy|[156]|2[aby]?)\$[A-Za-z0-9.\/]/) {
        print "[PASSWORD HASH LINE REDACTED]"; next
    }
    out=""
    while (index(s, "://") && match(s, /[A-Za-z][A-Za-z0-9+.-]*:\/\/[^\/[:space:]"<>]*@/)) {
        pos=RSTART; len=RLENGTH
        part=substr(s,pos,len); sub(/:\/\/.*/,"://[REDACTED]@",part)
        out=out substr(s,1,pos-1) part
        s=substr(s,pos+len)
    }
    print out s
}
AWK
[[ $? == 0 ]] || fatal 'Cannot write redaction program.'

cat > "$DATA/README.txt" <<'README'
BillsPi live diagnostic snapshot — collector 1.2

Read SUMMARY.txt, then command-status.tsv and file-index.tsv.
Every command output records UTC start/end, arguments, exit status and whether
the byte cap was reached. Nonzero status may mean absent/inactive/unsupported,
not necessarily a defect. Exit 124 normally means a timeout. Missing tools use 127.
Configuration inputs are limited to 256 KiB each; most commands to 512 KiB;
package lists to 4 MiB; journal streams to 8 MiB. Plain logs retain up to 6000 tail
lines and 1 MiB. Compressed logs retain the first 1 MiB after decompression.
At 64 MiB of stored command output, later captures are skipped with status 125
and SKIPPED_TOTAL_SIZE_LIMIT in the index (a redaction may cross that threshold).
The installation transcript is collected first, up to 32 MiB; its original is
never modified. Setup and runner journals and warnings cover all retained boots,
with byte caps recorded in command-status.tsv. Other journal excerpts have entry
limits shown in their command headers. Truncated results are explicitly indexed;
this is not an unlimited transcript.

This collector reads live state and allowlisted files. It installs nothing,
makes no network requests, applies no sysctls, does not mount/unmount devices,
does not start/stop/reload services, and runs no benchmarks or AIDE scans.
Only private staging files and the output archive are intentionally written.
Ordinary access accounting/audit logs may record the collector's reads/commands.

Excluded: private keys, raw authorized_keys, /etc/shadow and gshadow, Wi-Fi
connection profiles, APT authentication files, arbitrary environment/process
command lines, and PrepBill.sh/firstrun.sh contents and hashes.
Redaction of collected text is best effort, not a guarantee. Hostnames, local
IP/MAC addresses, account names, paths and public fingerprints remain useful
diagnostic evidence. Review before public sharing.

The .52 reference hashes identify unchanged shipped source files. Modified
SSH configuration/KNOWN_IP or later BillsPi releases can legitimately differ.
An inactive/disabled completed setup service is normal. Completion markers do
not prove every best-effort phase command succeeded. Previously lost volatile
journals cannot be recovered. An offline card alone cannot reproduce live state.
README
[[ $? == 0 ]] || fatal 'Cannot write README.'
{
    printf 'BillsPi diagnostic snapshot\nCollector: 1.2\nReference release: 1.0.0.53\n'
    printf 'Collected UTC: %s\nModel: %s\n\n' "$(/usr/bin/date -u '+%FT%TZ')" "$MODEL"
} > "$DATA/SUMMARY.txt" || fatal 'Cannot initialize summary.'

section 'Persistent installation transcript'
installation_snapshot /var/log/billspi/install.log
capture installation-logging-state 10 524288 /usr/bin/stat -c '%a %u:%g %s %n' /var/log/billspi /var/log/billspi/install.log /var/log/journal

section 'System identity, time and provisioning state'
capture os 10 524288 /usr/bin/cat /etc/os-release
capture kernel 10 524288 /usr/bin/uname -a
capture uptime 10 524288 /usr/bin/uptime
capture time 15 524288 /usr/bin/timedatectl status
capture timesync 15 524288 /usr/bin/timedatectl show-timesync --all
capture memory 10 524288 /usr/bin/free -h
capture filesystems 10 524288 /usr/bin/df -hT
capture block-devices 15 524288 /usr/bin/lsblk -o NAME,PATH,SIZE,MODEL,TRAN,TYPE,FSTYPE,MOUNTPOINTS
capture mounts 15 1048576 /usr/bin/findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS
file_snapshot /var/lib/billspi/current
file_snapshot /root/ssh_port.log
capture billspi-state 10 524288 /usr/bin/find /var/lib/billspi -maxdepth 2 -printf '%M %u:%g %s %p\n'
capture reboot-markers 10 524288 /usr/bin/ls -ld /run/reboot-required /run/reboot-required.pkgs /run/billspi/reboot-required
if [[ -f /var/lib/billspi/setup.done ]]; then finding OBSERVED 'setup.done exists (runner completion marker).'; else finding REVIEW 'setup.done is absent; installation is incomplete or the marker is missing.'; fi
if [[ -f /var/lib/billspi/current ]] && /usr/bin/grep -qxF '70-cleanup.sh' /var/lib/billspi/current; then
    finding OBSERVED 'Last completed phase is 70-cleanup.sh.'
else finding REVIEW 'Last-completed-phase marker is not 70-cleanup.sh; see state evidence.'; fi

section 'Services and timers'
capture failed-units 20 1048576 /usr/bin/systemctl --failed --no-pager --plain
capture unit-files 20 1048576 /usr/bin/systemctl list-unit-files --no-pager --plain
capture service-list 20 1048576 /usr/bin/systemctl list-units --type=service --all --no-pager --plain
capture timers 20 1048576 /usr/bin/systemctl list-timers --all --no-pager --plain
UNITS=(network_optimize.service cpugovernor.service logwatch-daily.service logwatch-daily.timer billspi-setup.service systemd-journald.service systemd-timesyncd.service NetworkManager.service ssh.service ssh.socket ufw.service fail2ban.service auditd.service aide-initialize.service aide-check.service aide-check.timer zramswap.service systemd-zram-setup@zram0.service dev-zram0.swap rpi-zram-writeback.timer rpi-zram-writeback.service rpi-setup-loop@var-swap.service rpi-resize-swap-file.service apt-daily.timer apt-daily-upgrade.timer apt-daily-upgrade.service unattended-upgrades.service billspi-monthly-upgrade.timer billspi-monthly-upgrade.service disable-usb.service disable-onboard-eth.service disable-wireless.service disable-audio.service disable-gpio.service)
capture unit-state 25 2097152 /usr/bin/systemctl show --no-pager -p Id -p LoadState -p ActiveState -p SubState -p Result -p ExecMainStatus -p UnitFileState "${UNITS[@]}"
capture setup-definition 15 524288 /usr/bin/systemctl cat billspi-setup.service
capture network-tuning-units 15 1048576 /usr/bin/systemctl cat network_optimize.service disable-usb.service disable-onboard-eth.service
capture hardening-units 20 2097152 /usr/bin/systemctl cat ssh.service apt-daily.timer apt-daily-upgrade.timer apt-daily-upgrade.service billspi-monthly-upgrade.service billspi-monthly-upgrade.timer aide-initialize.service aide-check.service aide-check.timer logwatch-daily.service logwatch-daily.timer cpugovernor.service getty@tty1.service

section 'Installed packages and retained logs'
capture packages 30 4194304 /usr/bin/dpkg-query -W '-f=${binary:Package}\t${Version}\t${Architecture}\t${db:Status-Abbrev}\n'
capture package-audit 30 1048576 /usr/bin/dpkg --audit
capture diversions 20 1048576 /usr/bin/dpkg-divert --list
capture retained-boots 20 524288 /usr/bin/journalctl --list-boots --no-pager
capture setup-journal 30 8388608 /usr/bin/journalctl -u billspi-setup.service --no-pager -o short-iso-precise
capture runner-journal 30 4194304 /usr/bin/journalctl -t billspi-runner -t billspi --no-pager -o short-iso-precise
capture retained-warnings 30 8388608 /usr/bin/journalctl -p warning --no-pager -o short-iso-precise
capture kernel-journal 25 4194304 /usr/bin/journalctl -k -b --no-pager -o short-iso-precise -n 15000
capture journal-usage 15 524288 /usr/bin/journalctl --disk-usage
capture journal-configuration 15 1048576 /usr/bin/systemd-analyze cat-config systemd/journald.conf
shopt -s nullglob
for src in /var/log/ssh_setup.log /var/log/ssh_perf_setup.log /var/log/auto-update-script.log /var/log/billspi-monthly-upgrade.log /var/log/dpkg.log /var/log/dpkg.log.1 /var/log/dpkg.log.2.gz /var/log/apt/history.log /var/log/apt/history.log.1.gz /var/log/apt/term.log /var/log/apt/term.log.1.gz /var/log/unattended-upgrades/*.log /var/log/unattended-upgrades/*.log.1 /var/log/aide/aide-check.log /var/log/logwatch/logwatch.log; do log_snapshot "$src"; done

section 'Security, accounts and network state'
capture ssh-syntax 15 524288 sshd -t
if [[ "$LAST_RC" == 0 ]]; then finding PASS 'sshd -t accepted the SSH configuration.'; else finding REVIEW 'SSH syntax check did not succeed; inspect ssh-syntax.txt.'; fi
capture ssh-effective 15 1048576 sshd -T
capture firewall 15 1048576 ufw status verbose
capture firewall-rules 20 2097152 nft list ruleset
capture fail2ban 15 524288 fail2ban-client status
capture fail2ban-ssh 15 524288 fail2ban-client status sshd
capture audit-status 15 524288 auditctl -s
capture audit-rules 15 1048576 auditctl -l
capture ip-addresses 10 524288 ip -brief address
capture ipv4-routes 10 524288 ip -4 route show table all
capture ipv6-routes 10 524288 ip -6 route show table all
capture listeners 15 1048576 ss -lntup
capture nm-devices 15 524288 nmcli -f DEVICE,TYPE,STATE,CONNECTION device status
capture nm-addressing 15 1048576 nmcli -f GENERAL.DEVICE,GENERAL.STATE,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,IP6.ADDRESS,IP6.GATEWAY,IP6.DNS device show
capture dns-status 15 524288 resolvectl status
capture radio-blocks 10 524288 rfkill list
capture accounts 10 524288 /usr/bin/awk -F: '{printf "%s\tuid=%s\tgid=%s\thome=%s\tshell=%s\n",$1,$3,$4,$6,$7}' /etc/passwd
capture groups 10 524288 /usr/bin/awk -F: '{printf "%s\tgid=%s\tmembers=%s\n",$1,$3,$4}' /etc/group
capture sudo-policy-syntax 15 524288 visudo -c
PRIMARY_USER=$(/usr/bin/awk -F: '$3==1000{print $1;exit}' /etc/passwd)
PRIMARY_HOME=$(/usr/bin/awk -F: '$3==1000{print $6;exit}' /etc/passwd)
if [[ -n "$PRIMARY_USER" && "$PRIMARY_HOME" == /* ]]; then
    capture user-key-permissions 10 524288 /usr/bin/stat -c '%a %u:%g %F %n' -- "$PRIMARY_HOME" "$PRIMARY_HOME/.ssh" "$PRIMARY_HOME/.ssh/authorized_keys"
    capture user-key-fingerprints 10 524288 /usr/bin/ssh-keygen -lf "$PRIMARY_HOME/.ssh/authorized_keys"
fi
ADMIN_IP=$(/usr/bin/sed -n 's/^KNOWN_IP="\([0-9.]*\)".*/\1/p' /usr/local/lib/billspi/phases/25-ssh-install-and-hardening.sh 2>/dev/null || true)
if [[ -n "$PRIMARY_USER" && "$ADMIN_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    capture ssh-effective-admin 15 1048576 sshd -T -C "user=$PRIMARY_USER,host=localhost,addr=$ADMIN_IP"
fi
capture root-password-state 10 524288 /usr/bin/passwd -S root
if [[ -n "$PRIMARY_USER" ]]; then capture user-password-state 10 524288 /usr/bin/passwd -S "$PRIMARY_USER"; fi
for key in /etc/ssh/ssh_host_*.pub; do
    label=${key##*/}; capture "fingerprint-$label" 10 524288 /usr/bin/ssh-keygen -lf "$key"
done
for dev in /sys/class/net/*; do
    [[ -e "$dev/device" ]] || continue
    iface=${dev##*/}; [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] || continue
    capture "link-$iface" 10 524288 ethtool "$iface"
    capture "offloads-$iface" 10 524288 ethtool -k "$iface"
    capture "coalesce-$iface" 10 524288 ethtool -c "$iface"
    capture "driver-$iface" 10 524288 ethtool -i "$iface"
done

section 'Kernel, zram, memory and power state'
capture sysctl 20 2097152 /usr/sbin/sysctl -a
capture swap 10 524288 swapon --show --bytes
capture zram 10 524288 zramctl
capture modules 10 524288 lsmod
capture temperature 10 524288 vcgencmd measure_temp
capture throttle 10 524288 vcgencmd get_throttled
capture firmware 10 524288 vcgencmd version
capture bootloader 10 524288 vcgencmd bootloader_version
capture eeprom-package 10 524288 /usr/bin/dpkg-query -W rpi-eeprom
if /usr/bin/grep -q '^/dev/zram' /proc/swaps; then finding OBSERVED 'A /dev/zram device is active as swap.'; else finding REVIEW 'No /dev/zram entry in /proc/swaps; phase 45 intended to enable zram swap.'; fi
for src in /proc/swaps /proc/cmdline /proc/meminfo /sys/kernel/mm/lru_gen/enabled /sys/kernel/mm/lru_gen/min_ttl_ms /sys/block/zram*/comp_algorithm /sys/block/zram*/disksize /sys/block/zram*/mm_stat /sys/block/zram*/io_stat /sys/block/zram*/backing_dev /sys/devices/system/cpu/cpufreq/policy*/scaling_governor /sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq /sys/class/thermal/thermal_zone*/temp /sys/block/mmcblk*/queue/scheduler /sys/block/mmcblk*/queue/read_ahead_kb; do file_snapshot "$src"; done

section 'Configuration snapshots and cleanup evidence'
for src in /etc/fstab /etc/sysctl.conf /etc/sysctl.d/*.conf /etc/login.defs /etc/bash.bashrc /etc/profile.d/56-more-tools-aliases.sh /etc/locale.gen /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf /etc/pam.d/common-* /etc/pam.d/sshd /etc/pam.d/login /etc/pam.d/sudo /usr/share/pam-configs/faillock-hardening /etc/security/limits.conf /etc/security/limits.d/*.conf /etc/security/faillock.conf /etc/default/ufw /etc/default/zramswap /etc/default/network_optimize /etc/default/sysstat /etc/ufw/ufw.conf /etc/ufw/user.rules /etc/ufw/user6.rules /etc/ufw/before.rules /etc/ufw/before6.rules /etc/ufw/after.rules /etc/ufw/after6.rules /etc/ufw/sysctl.conf /etc/fail2ban/jail.local /etc/fail2ban/jail.d/*.conf /etc/fail2ban/jail.d/*.local /etc/rpi/swap.conf.d/*.conf /etc/tmpfiles.d/billspi-mglru.conf /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf /etc/systemd/system.conf.d/90-rpi5-limits.conf /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources /etc/apt/apt.conf.d/* /etc/apt/billspi-pi-unattended.conf /etc/apt/preferences.d/* /etc/dpkg/dpkg.cfg.d/* /etc/modules-load.d/*.conf /etc/modprobe.d/*.conf /etc/udev/rules.d/*.rules /boot/firmware/config.txt /boot/firmware/cmdline.txt /etc/initramfs-tools/initramfs.conf /etc/initramfs-tools/update-initramfs.conf /etc/initramfs-tools/conf.d/* /etc/audit/rules.d/99-hardening.rules /etc/aide/aide.conf /etc/aide/aide.conf.d/10-billspi-hardening /etc/needrestart/needrestart.conf /etc/sudoers.d/faillock /etc/sudoers.d/logfile; do file_snapshot "$src"; done
capture temporary-directory-permissions 10 524288 /usr/bin/stat -c '%a %u:%g %F %n' /tmp /var/tmp /var/cache/apt/archives /var/lib/apt/lists /var/log/journal
capture wrapper-metadata 10 1048576 /usr/bin/ls -l /usr/local/bin /usr/local/sbin
for src in /usr/local/bin/{gzip,gunzip,xz,bzip2,cp,mv,rsync,grep,find,md5sum,sha1sum,sha256sum,sha512sum,curl,wget,aria2c} /usr/local/sbin/{apt,apt-get,dpkg,apt-fast}; do
    [[ -f "$src" && ! -L "$src" ]] || continue
    # Only read small text wrappers, never an arbitrary installed binary.
    magic=$(/usr/bin/head -c 2 -- "$src")
    [[ "$magic" == '#!' ]] && file_snapshot "$src"
done
if [[ -f /etc/systemd/journald.conf.d/99-volatile.conf ]]; then
    finding REVIEW '99-volatile.conf remains: earlier boot journal entries may be unavailable; inspect effective journal configuration.'
fi
for leftover in /etc/apt/apt.conf.d/02billspi-sandbox-root /etc/apt/apt.conf.d/99speed /etc/dpkg/dpkg.cfg.d/01speed /usr/sbin/policy-rc.d /usr/local/sbin/apt-get /usr/local/sbin/dpkg; do
    if [[ -e "$leftover" || -L "$leftover" ]]; then finding REVIEW "Provisioning-related file still exists: $leftover (interpret against completion state)."; fi
done

section 'Installed BillsPi source identity (no provisioning-password files)'
printf 'reference_sha256\tactual_sha256\tstate\tfile\n' > "$DATA/billspi-source-hashes.tsv" || fatal 'Cannot initialize source index.'
while read -r expected relative; do
    [[ -n "$expected" && -n "$relative" ]] || continue
    target="/usr/local/lib/billspi/$relative"
    if [[ -f "$target" && ! -L "$target" ]]; then
        if actual=$(/usr/bin/sha256sum -- "$target"); then
            actual=${actual%% *}
            state=MATCH; [[ "$actual" == "$expected" ]] || state=DIFFERENT
        else actual=unavailable; state=UNREADABLE; fi
    else actual=unavailable; state=MISSING_OR_SYMLINK; fi
    printf '%s\t%s\t%s\t%s\n' "$expected" "$actual" "$state" "$target" >> "$DATA/billspi-source-hashes.tsv" || fatal 'Cannot write source index.'
done <<'EXPECTED53'
5e98ffd65f424727ed13a1116bfa83f149e89acf16f3fba1f68d3c369b1f03bb  billspi-runner
d260e472e849c7eec57128b000899e48e0a7e1ac8cb65f607aef91623ca38c2a  phases/01-system-prerequisites.sh
d1309681c7516282368363c19faf06feae9f65603faa31a3a21b656a0e4ac70c  phases/05-debloat-and-disable-services.sh
157a2eed55be90842a452b79dc11d8fe602f0c57496c9d69022a70ee9a964249  phases/10-security-patching.sh
e2f37ec83d2b5d1adad24d50844d98ba27fdfa271323b85da7f7f03cc82fe6b1  phases/11-account-policy-hardening.sh
58bfd22e35c397396378517dcc486d24bcd88a6af4eb6d67019c5a8d09139bd6  phases/12-sysctl-hardening.sh
8d019af473a4ff0588da095c28c6815705bda83c012e290677a2054517225f45  phases/13-systemd-service-hardening.sh
3ea66a677c4715158a46456963bb2e51788d38514685f23929bb5dcfecd1a96e  phases/14-integrity-audit.sh
bec6db6ef3d833687f76d98c6ffbe8741a8a2138d0f54d458902f4d59d9a477e  phases/14-logging-hardening.sh
7d2b766305cc2db895f4088ac680e22b915ef1a4234a7adc919f9a0751365715  phases/15-kernel-bootloader-eeprom-update.sh
64532d33f5c77b7da382241e320a56aed489069216ca51635291464ba7836a92  phases/16-prefetch.sh
e065ce23c36db547c4d8ec8d35a0e0fcb5f975ed2411c733d7956e9900823572  phases/20-upgrade-all.sh
d66f8f28380acec5426571ac2c0dda07b02fb3d485a652f903440c342d8aa80f  phases/25-ssh-install-and-hardening.sh
9662ae023826334265e46685f6f8e99b4f085636f1e7539fd8cec82ad670ad58  phases/30-ssh-sftp-scp-optimizations.sh
f4d9b96a74a01c11a82507dcd83c40322e26c8c1a7d5b5ba7f185a24b729b9a7  phases/35-power-optimization.sh
cf88b069d7a9015f728b528b6010c225b35a20ba593555469ff0cf9e98ba2e63  phases/40-network-tuning.sh
45a62c2d2fd73a2a6ad53cdd5394c436e460ab566fa7dfec06e482f2447c445e  phases/45-swap-zram-and-mglru.sh
679ec90fdddb9b7e483aabe06882db92943f95687263ce0214f6fa5a192a9a0f  phases/50-optimized-unix-tools-and-aliases.sh
2b5cf20a1697ab888514e015accd7d6555016af210ac60ee1b16929f494e42c1  phases/55-optional-dev-and-perf-tools.sh
5846ed595a5ab9cb19d3cc8ea7711c725c7a9782a4a784da09cc016ee72ae641  phases/56-more-tools.sh
0dba9f8e541900c8f4a521fb85d72bb571b06be2a2c916d3116ef1baca03936b  phases/60-automated-updates-unattended-upgrades.sh
ea9aaaf3ded05ea34f9582ab5b08e868ce30cbb3ead7302e3470136e5943a789  phases/65-upgrade-all.sh
7eb45626a34b000f5132e652a9e7708d5227bf4bfde15c56c8ce7e830e7b8cad  phases/70-cleanup.sh
920d97d04c77f04f273f9c9fe9d36e17f9ed1fbdda4c93a0f89916043bc2a26a  billspi-setup.service
b982973c1fb4cd42fdc38c1d315eb35d7da48488f15fdcec44648dea5d1a7a97  phases/good-wrappers.sh
59ac08b95575ffe4417b4e400911d00f920ef09d4df7460c2645a641cc4dec7f  phases/luks.sh
EXPECTED53
capture active-payload-hashes 10 524288 /usr/bin/sha256sum /usr/local/sbin/billspi-runner /etc/systemd/system/billspi-setup.service

section 'Preparing one export archive'
{
    printf '\nCollection outcomes (these are not automatically system defects):\n'
    /usr/bin/awk -F '\t' 'NR>1 {n++;if($2!=0)e++;if($3==1)t++} END{printf "Commands/files captured: %d\nNonzero command exits: %d\nTruncated captures: %d\n",n,e,t}' "$DATA/command-status.tsv"
    printf '\nSee command-status.tsv and README.txt for limits and excluded data.\n'
    printf 'Collection finished UTC: %s\n' "$(/usr/bin/date -u '+%FT%TZ')"
} >> "$DATA/SUMMARY.txt" || fatal 'Cannot complete summary.'
(
    cd "$DATA" || exit 1
    /usr/bin/find . -type f ! -name SHA256SUMS -print0 | /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/sha256sum > SHA256SUMS
) || fatal 'Cannot create the archive content manifest.'
STAMP=$(/usr/bin/date -u '+%Y%m%dT%H%M%SZ')
ARCHIVE=$(/usr/bin/mktemp "$OUT_DIR/billspi-diagnostics-$STAMP-XXXXXXXX.tar.gz") || fatal 'Cannot create output archive.'
if [[ -x /usr/bin/pigz ]]; then COMPRESS=(/usr/bin/pigz -1 -p 1); else COMPRESS=(/usr/bin/gzip -1); fi
/usr/bin/tar -C "$WORK" -cf - report | "${COMPRESS[@]}" > "$ARCHIVE" || fatal 'Archive creation failed.'
/usr/bin/gzip -t -- "$ARCHIVE" || fatal 'Compressed archive verification failed.'
FINISHED=1
# Retain a verified export even if the output filesystem cannot change owners.
ARCHIVE_OWNER=''
HANDOFF_WARNING=''
if [[ -n "${SUDO_UID:-}${SUDO_USER:-}" && ( "${SUDO_UID:-}" != 0 || "${SUDO_USER:-}" != root ) ]]; then
    if [[ "${SUDO_UID:-}" =~ ^[1-9][0-9]*$ && -n "${SUDO_USER:-}" ]]; then
        ARCHIVE_OWNER=$(/usr/bin/awk -F: -v expected_uid="$SUDO_UID" \
            '$1 == ENVIRON["SUDO_USER"] && ("u" $3) == ("u" expected_uid) && $4 ~ /^[0-9]+$/ {print $3 ":" $4; exit}' /etc/passwd)
    fi
    [[ -n "$ARCHIVE_OWNER" ]] || HANDOFF_WARNING='The sudo user could not be matched to a local account; ownership was not changed.'
fi
if [[ -n "$ARCHIVE_OWNER" ]] && ! /usr/bin/chown --no-dereference -- "$ARCHIVE_OWNER" "$ARCHIVE"; then
    HANDOFF_WARNING='The output filesystem rejected the archive ownership change.'
fi
ARCHIVE_METADATA=$(/usr/bin/stat -c '%u:%g %a' -- "$ARCHIVE") || ARCHIVE_METADATA=''
if [[ "${ARCHIVE_METADATA##* }" != 600 || ( -n "$ARCHIVE_OWNER" && "${ARCHIVE_METADATA% *}" != "$ARCHIVE_OWNER" ) ]]; then
    HANDOFF_WARNING="${HANDOFF_WARNING:+$HANDOFF_WARNING }Private permissions or requested ownership could not be verified; the filesystem may ignore them."
fi
if [[ -n "$HANDOFF_WARNING" ]]; then
    printf 'WARNING: %s Verified archive retained: %s\n' "$HANDOFF_WARNING" "$ARCHIVE" >&2
fi
printf '\nDiagnostic archive ready:\n%s\n\nSHA-256:\n' "$ARCHIVE"
/usr/bin/sha256sum -- "$ARCHIVE"
printf '\nIf the path above is on your USB stick, the export is already there.\n'
printf 'Otherwise use sudo cp to copy this single archive onto the mounted stick.\n'
printf 'If access is denied, run this as your regular user to make a private copy (adjust the source path if moved):\n'
printf 'sudo install -m 600 -o "$(id -u)" -g "$(id -g)" -- %q "$HOME"/%q\n' "$ARCHIVE" "private-${ARCHIVE##*/}"
printf 'Exit 0 confirms collection, not a clean bill of health.\n'
exit 0

#!/usr/bin/env bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
# Ubuntu-only preparation automation for Dean's BillsPi test card.
# Usage: bash PrepareBillsPi.sh billspi-1.0.0.53.zip
# Reuses account settings from the already-edited .53 PrepBill.sh by default.
# This is a separate host tool; it does not modify the release ZIP.
set +x
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset LD_PRELOAD LD_LIBRARY_PATH
umask 077

KNOWN_IP=192.168.2.12
ACCOUNT_SOURCE="${BILLSPI_ACCOUNT_SOURCE:-$HOME/Desktop/Pi/billspi-1.0.0.53/PrepBill.sh}"
BOOT_MOUNT=/mnt/pi-boot
ROOT_MOUNT=/mnt/pi-root
CURRENT_DEVICE=/dev/sda
WORK=
OWNS_MOUNTS=0

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '\n[BillsPi preparation] %s\n' "$*"; }

cleanup() {
    local rc=$? target expected actual
    trap - EXIT INT TERM
    if [[ $OWNS_MOUNTS == 1 ]]; then
        sync || true
        for target in "$ROOT_MOUNT" "$BOOT_MOUNT"; do
            if [[ $target == "$ROOT_MOUNT" ]]; then expected="${CURRENT_DEVICE}2"; else expected="${CURRENT_DEVICE}1"; fi
            actual=$(findmnt -rn -o SOURCE --mountpoint "$target" 2>/dev/null || true)
            if [[ $actual == "$expected" ]]; then
                sudo umount "$target" || printf 'Could not unmount %s; inspect it before removal.\n' "$target" >&2
            fi
        done
    fi
    if [[ -n $WORK && -d $WORK ]]; then rm -rf -- "$WORK"; fi
    if (( rc != 0 )); then
        printf '\nPreparation stopped (status %s). Do not boot this card as a completed installation.\n' "$rc" >&2
    fi
    exit "$rc"
}

# Python's standard library provides strict ZIP/JSON and literal-value parsing.
# No archive code is run to inspect account settings or identify a device.
helper() {
    python3 - "$@" <<'PY'
import json, os, pathlib, re, shlex, stat, subprocess, sys, zipfile

def fail(message):
    raise SystemExit('ERROR: ' + message)

def literal(text, name):
    lines = re.findall(r'^\s*' + re.escape(name) + r'=(.*)$', text, re.M)
    if len(lines) != 1:
        fail('Expected one literal ' + name + ' assignment in account settings.')
    s = lines[0].strip()
    if not s or s[0] not in "\"'":
        fail(name + ' must be a single quoted literal, not shell expressions.')
    quote, i, out = s[0], 1, []
    while i < len(s):
        ch = s[i]
        if ch == quote:
            tail = s[i + 1:].strip()
            if tail and not tail.startswith('#'):
                fail('Unsupported text after ' + name + '.')
            return ''.join(out)
        if quote == '"' and ch in '$`':
            fail(name + ' contains shell expansion; use single quotes for a literal value.')
        if quote == '"' and ch == '\\':
            i += 1
            if i >= len(s):
                fail('Unterminated ' + name + '.')
            if s[i] not in '$`"\\':
                out.append('\\')
            out.append(s[i])
        else:
            out.append(ch)
        i += 1
    fail('Unterminated ' + name + '.')

def replace_once(text, pattern, replacement, label):
    matches = list(re.finditer(pattern, text, re.M))
    if len(matches) != 1:
        fail('Unsupported PrepBill layout: expected one ' + label + '. Nothing has been flashed.')
    m = matches[0]
    return text[:m.start()] + replacement + text[m.end():]

def udev(name):
    result = subprocess.run(['udevadm', 'info', '--query=property', '--name', name],
                            text=True, capture_output=True, check=True)
    return dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)

def identity(device):
    props = udev(device['name'])
    return {'model': (device.get('model') or '').strip(), 'size': int(device['size']),
            'serial': (device.get('serial') or props.get('ID_SERIAL_SHORT') or '').strip(),
            'path': props.get('ID_PATH', '')}

def validate_device(d):
    if not re.fullmatch(r'/dev/sd[a-z]+', d['name']) or d.get('type') != 'disk':
        fail('The selected target is not a supported whole USB disk.')
    if d.get('tran') != 'usb' or d.get('ro') not in (False, 0):
        fail('The target is not a writable USB disk.')
    if (d.get('model') or '').strip() != 'SD Transcend' or not 28*1024**3 <= int(d['size']) <= 33*1024**3:
        fail('Target is not the expected approximately 32 GB SD Transcend card.')
    if any(d.get('mountpoints') or []):
        fail('The whole disk has a mountpoint; refusing.')
    user = os.environ['USER']
    allowed = {'/mnt/pi-boot', '/mnt/pi-root'}
    allowed.update(f'{base}/{user}/{label}' for base in ('/run/media', '/media') for label in ('bootfs', 'rootfs'))
    for p in d.get('children', []):
        if p.get('type') != 'part' or p.get('children') or p['name'] not in (d['name']+'1', d['name']+'2'):
            fail('Unexpected partitions or dependent devices on target; refusing.')
        if any(m and m not in allowed for m in p.get('mountpoints') or []):
            fail('Target contains an unexpected/system/swap mountpoint; refusing.')
    # Also reject active swap files whose underlying filesystem is on the card.
    swaps = subprocess.check_output(['swapon', '--show=NAME', '--noheadings', '--raw'], text=True).splitlines()
    target_names = {d['name']} | {p['name'] for p in d.get('children', [])}
    for item in swaps:
        name = re.sub(r'\\x([0-9a-fA-F]{2})', lambda m: chr(int(m.group(1), 16)), item.strip())
        if not name:
            continue
        if name in target_names:
            fail('Target contains active swap; refusing.')
        r = subprocess.run(['findmnt', '-rn', '-o', 'SOURCE', '--target', name], text=True, capture_output=True)
        if r.returncode == 0 and r.stdout.strip().split('[', 1)[0] in target_names:
            fail('An active swap file is on the target; refusing.')

action = sys.argv[1]
if action == 'stage':
    archive, account, work, image_dir = map(pathlib.Path, sys.argv[2:6])
    with zipfile.ZipFile(archive) as z:
        seen, total = set(), 0
        for info in z.infolist():
            name = info.filename
            parts = name.rstrip('/').split('/')
            mode = info.external_attr >> 16
            if (not name or '\\' in name or any(c in name for c in '\x00\r\n') or name.startswith('/')
                    or any(p in ('', '.', '..') for p in parts) or name.rstrip('/') in seen
                    or stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR)
                    or (stat.S_IFMT(mode) == stat.S_IFDIR and not info.is_dir()) or info.flag_bits & 1):
                fail('Unsafe or unsupported ZIP member: ' + repr(name))
            seen.add(name.rstrip('/'))
            total += info.file_size
        if len(seen) > 300 or total > 64*1024**2:
            fail('Archive exceeds the expected BillsPi payload size.')
        required = ['PrepBill.sh', 'billspi-runner', 'billspi-setup.service',
                    'phases/25-ssh-install-and-hardening.sh', 'tools/billspi-diagnostics.sh']
        if not all(name in z.namelist() for name in required):
            fail('Expected .50-style root-level archive layout and logging collector are missing.')
        if z.testzip() is not None:
            fail('ZIP integrity check failed.')
        template = z.read('PrepBill.sh').decode('utf-8')
    user = literal(account.read_text(), 'PI_USER')
    password = literal(account.read_text(), 'PI_PASS_PLAIN')
    if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', user) or user == 'root':
        fail('Unsupported PI_USER in account settings.')
    if not password or password == 'changeme' or '\n' in password or '\r' in password:
        fail('Set a real PI_PASS_PLAIN in the existing account-settings PrepBill.sh before running.')
    hashed = subprocess.check_output(['openssl', 'passwd', '-6', '-stdin'], input=password+'\n', text=True).strip()
    if not hashed.startswith('$6$') or '\n' in hashed:
        fail('Password hashing failed.')
    template = replace_once(template, r'^PI_USER=.*$', 'PI_USER='+shlex.quote(user), 'PI_USER assignment')
    template = replace_once(template, r'^PI_PASS_PLAIN=.*$', "PI_PASS_PLAIN='' # Account password already hashed by host wrapper.", 'password assignment')
    template = replace_once(template, r'^PI_PASS_HASH=.*$', 'PI_PASS_HASH='+shlex.quote(hashed), 'password hash assignment')
    template = replace_once(template, r'^ZIP=.*$', 'ZIP='+shlex.quote(str(archive)), 'ZIP assignment')
    m = re.findall(r'^xzcat (.+) \| sudo dd of=/dev/sda bs=4M status=progress conv=fsync$', template, re.M)
    if len(m) != 1:
        fail('Unsupported image-flashing command in PrepBill.sh.')
    image_words = shlex.split(m[0])
    if len(image_words) != 1 or pathlib.Path(image_words[0]).name != image_words[0] or not image_words[0].endswith('.img.xz'):
        fail('Unsupported image filename in PrepBill.sh.')
    image = image_dir / image_words[0]
    if not image.is_file():
        fail('Image must be beside the ZIP: ' + str(image))
    (work/'image-path').write_text(str(image))
    template = replace_once(template, r'^xzcat .+ \| sudo dd of=/dev/sda bs=4M status=progress conv=fsync$',
                            'xzcat '+shlex.quote(str(image))+' | sudo dd of=/dev/sda bs=4M status=progress conv=fsync', 'image command')
    # The wrapper already unmounted verified card partitions. Repeat that check
    # after partition probing to handle Ubuntu automatic mounts before setup.
    mount_start = '# --- MOUNT & VERIFY (must happen AFTER flashing) ---'
    mount_end = 'sudo mount /dev/sda2 /mnt/pi-root'
    if template.count(mount_start) != 1 or template.count(mount_end) != 1:
        fail('Unsupported PrepBill mount block.')
    a, b = template.index(mount_start), template.index(mount_end) + len(mount_end)
    template = template[:a] + '''# Mount only the already-validated test card.
sudo udevadm settle --timeout=30
for card_part in /dev/sda1 /dev/sda2; do
  if findmnt -rn -S "$card_part" >/dev/null; then sudo umount "$card_part"; fi
done
if mountpoint -q /mnt/pi-boot || mountpoint -q /mnt/pi-root; then
  printf '%s\\n' 'ERROR: preparation mountpoint occupied.' >&2
  exit 1
fi
sudo mkdir -p /mnt/pi-boot /mnt/pi-root
sudo mount /dev/sda1 /mnt/pi-boot
sudo mount /dev/sda2 /mnt/pi-root''' + template[b:]
    template = replace_once(template, r'^set \+e$', 'set -e', 'final strict-mode setting')
    template = replace_once(template, r'^sudo umount /mnt/pi-boot \|\| true$', 'sudo umount /mnt/pi-boot', 'final boot unmount')
    template = replace_once(template, r'^sudo umount /mnt/pi-root \|\| true$', 'sudo umount /mnt/pi-root', 'final root unmount')
    template = replace_once(template, r'^udisksctl power-off -b /dev/sda$', 'sudo udisksctl power-off -b /dev/sda', 'final power-off')
    (work/'PrepBill-staged.sh').write_text(template+'\n')
    (work/'PrepBill-staged.sh').chmod(0o700)
elif action == 'device':
    mode, snapshot, saved = sys.argv[2:5]
    devices = json.loads(pathlib.Path(snapshot).read_text())['blockdevices']
    if mode == 'initial':
        found = [d for d in devices if d['name'] == '/dev/sda']
        if len(found) != 1:
            fail('Expected card at /dev/sda is absent. No disk will be selected automatically for flashing.')
        d = found[0]
        validate_device(d)
        ident = identity(d)
        if not ident['serial'] and not ident['path']:
            fail('Cannot obtain a stable USB identity for card reinsertion.')
        pathlib.Path(saved).write_text(json.dumps(ident))
    else:
        original = json.loads(pathlib.Path(saved).read_text())
        found = []
        for candidate in devices:
            if candidate.get('type') != 'disk' or candidate.get('tran') != 'usb':
                continue
            ident = identity(candidate)
            same = (ident['serial'] == original['serial']) if original['serial'] else (ident['path'] == original['path'])
            if same and ident['model'] == original['model'] and ident['size'] == original['size']:
                found.append(candidate)
        if len(found) != 1:
            fail('Cannot uniquely identify the original card after reinsertion; no further writes made.')
        d = found[0]
        validate_device(d)
    print(d['name'])
elif action == 'edit-ip':
    path, ip = pathlib.Path(sys.argv[2]), sys.argv[3]
    if path.is_symlink() or not path.is_file():
        fail('SSH phase is not a regular file.')
    data = path.read_bytes()
    matches = list(re.finditer(rb'^KNOWN_IP=[^\r\n]*', data, re.M))
    if len(matches) != 1:
        fail('Expected exactly one KNOWN_IP assignment; SSH phase left untouched.')
    m = matches[0]
    old = m.group()
    comment = old.find(b'#')
    new = b'KNOWN_IP="'+ip.encode('ascii')+b'"'
    if comment >= 0:
        new += b'  '+old[comment:]
    path.write_bytes(data[:m.start()]+new+data[m.end():])
else:
    fail('Unknown internal helper action.')
PY
}

snapshot() {
    lsblk --json --bytes --paths --output NAME,TYPE,SIZE,MODEL,SERIAL,TRAN,RO,MOUNTPOINTS,FSTYPE > "$WORK/devices.json"
}

detach_card_mounts() {
    local part
    for part in "${CURRENT_DEVICE}1" "${CURRENT_DEVICE}2"; do
        if findmnt -rn -S "$part" >/dev/null; then sudo umount "$part"; fi
        if findmnt -rn -S "$part" >/dev/null; then die "$part is still mounted."; fi
    done
}

check_destinations() {
    local target
    for target in "$BOOT_MOUNT" "$ROOT_MOUNT"; do
        [[ ! -L $target ]] || die "Mount destination is a symlink: $target"
        if mountpoint -q "$target"; then die "Mount destination already occupied: $target"; fi
    done
}

verify_mounts() {
    [[ $(findmnt -rn -o SOURCE --mountpoint "$BOOT_MOUNT") == "${CURRENT_DEVICE}1" ]] || die 'Boot mount source mismatch.'
    [[ $(findmnt -rn -o SOURCE --mountpoint "$ROOT_MOUNT") == "${CURRENT_DEVICE}2" ]] || die 'Root mount source mismatch.'
}

main() {
    if [[ ${1:-} == --help || ${1:-} == -h ]]; then
        cat <<'HELP'
Usage: bash PrepareBillsPi.sh billspi-1.0.0.53.zip

Run as your normal Ubuntu user, not with sudo. THIS REFLASHES /dev/sda.
It only accepts the expected USB SD Transcend card of approximately 32 GB.
The image named in the ZIP's PrepBill.sh must be beside the ZIP.
Account settings come from ~/Desktop/Pi/billspi-1.0.0.53/PrepBill.sh.
Override that settings file with BILLSPI_ACCOUNT_SOURCE=/absolute/PrepBill.sh.
Your existing ~/.ssh/id_ed25519 and .pub must exist and match.
KNOWN_IP is set to 192.168.2.12; this address must be active on Ubuntu.
After initial sudo/key authentication, the planned pause is for card
removal/reinsertion. Press Space to continue. The ZIP remains unchanged.
HELP
        return
    fi
    [[ $# == 1 ]] || die 'Usage: bash PrepareBillsPi.sh billspi-1.0.0.53.zip'
    (( EUID != 0 )) || die 'Run as your normal Ubuntu user; the script uses sudo where needed.'
    [[ -t 0 && -t 1 ]] || die 'Run this interactively in an Ubuntu terminal.'
    local cmd zip image private_fp public_fp key source selected phase keypress
    for cmd in python3 sudo lsblk findmnt mount umount mountpoint dd xz xzcat partprobe unzip openssl ssh-keygen sync udevadm udisksctl install readlink realpath sha256sum cmp ip swapon awk; do
        command -v "$cmd" >/dev/null || die "Required command missing: $cmd"
    done
    zip=$(realpath -e -- "$1")
    [[ -f $zip && ${zip,,} == *.zip ]] || die 'Parameter must be an existing ZIP file.'
    [[ $zip != *$'\n'* && $zip != *$'\r'* ]] || die 'Unsupported newline in ZIP path.'
    ACCOUNT_SOURCE=$(realpath -e -- "$ACCOUNT_SOURCE")
    [[ -f $ACCOUNT_SOURCE ]] || die 'Configured account-settings PrepBill.sh is missing.'
    key="$HOME/.ssh/id_ed25519"
    [[ -f $key && -s $key.pub ]] || die 'Existing id_ed25519 private/public key pair is required. No keys will be replaced.'
    ip -4 -o address show | awk -v wanted="$KNOWN_IP" '{ split($4,a,"/"); if(a[1]==wanted) ok=1 } END { exit !ok }' \
        || die "Ubuntu does not currently have $KNOWN_IP. Check its LAN address before preparation."
    WORK=$(mktemp -d /tmp/billspi-prepare.XXXXXXXX)
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    cp -- "$zip" "$WORK/payload.zip"
    helper stage "$WORK/payload.zip" "$ACCOUNT_SOURCE" "$WORK" "$(dirname -- "$zip")"
    image=$(cat "$WORK/image-path")
    bash -n "$WORK/PrepBill-staged.sh"
    note 'Checking image integrity before touching the card...'
    xz -t -- "$image"
    note 'Verifying your existing SSH key pair (its passphrase may be requested).'
    private_fp=$(ssh-keygen -y -f "$key" | ssh-keygen -lf - | awk '{print $2}')
    public_fp=$(ssh-keygen -lf "$key.pub" | awk '{print $2}')
    [[ -n $private_fp && $private_fp == "$public_fp" ]] || die 'SSH private/public keys do not match.'
    sudo -v
    snapshot
    CURRENT_DEVICE=$(helper device initial "$WORK/devices.json" "$WORK/identity.json")
    for source in "$zip" "$image" "$ACCOUNT_SOURCE" "$key" "$key.pub"; do
        selected=$(findmnt -rn -o SOURCE --target "$source")
        [[ $selected != "$CURRENT_DEVICE" && $selected != "${CURRENT_DEVICE}1" && $selected != "${CURRENT_DEVICE}2" ]] \
            || die 'An input file is stored on the card being erased.'
    done
    note 'Selected target: /dev/sda, SD Transcend, approximately 32 GB. Its contents will be replaced.'
    lsblk -o NAME,PATH,SIZE,MODEL,TRAN,FSTYPE,MOUNTPOINTS "$CURRENT_DEVICE"
    printf 'Release ZIP: %s\nImage: %s\nAccount settings: %s\nSSH key: %s\nKNOWN_IP: %s\n' "$zip" "$image" "$ACCOUNT_SOURCE" "$public_fp" "$KNOWN_IP"
    sha256sum -- "$zip"
    detach_card_mounts
    check_destinations
    # Recheck device identity after authentication and before the destructive run.
    snapshot
    [[ $(helper device again "$WORK/devices.json" "$WORK/identity.json") == /dev/sda ]] || die 'Target identity changed before flashing.'
    OWNS_MOUNTS=1
    note 'Running the archive preparation workflow once...'
    bash "$WORK/PrepBill-staged.sh"
    OWNS_MOUNTS=0
    check_destinations
    note 'Preparation stage finished and reader powered off.'
    printf 'Remove the MicroSD reader/card, then reinsert THE SAME card (preferably the same USB port).\nWait for Ubuntu to detect it, then press the SPACEBAR to continue.\n'
    while IFS= read -r -s -n 1 keypress; do
        [[ $keypress == ' ' ]] && break
    done
    [[ ${keypress:-} == ' ' ]] || die 'Card reinsertion prompt ended without Space.'
    printf '\n'
    sudo -v
    sudo udevadm settle --timeout=30
    snapshot
    CURRENT_DEVICE=$(helper device again "$WORK/devices.json" "$WORK/identity.json")
    [[ -b ${CURRENT_DEVICE}1 && -b ${CURRENT_DEVICE}2 ]] || die 'Reinserted card partitions are missing.'
    note "Reidentified card as $CURRENT_DEVICE. Completing SSH and logging checks..."
    detach_card_mounts
    check_destinations
    sudo mkdir -p "$BOOT_MOUNT" "$ROOT_MOUNT"
    OWNS_MOUNTS=1
    sudo mount "${CURRENT_DEVICE}1" "$BOOT_MOUNT"
    sudo mount "${CURRENT_DEVICE}2" "$ROOT_MOUNT"
    verify_mounts
    phase="$ROOT_MOUNT/usr/local/lib/billspi/phases/25-ssh-install-and-hardening.sh"
    sudo test -s "$phase"
    # Read/write the phase through a private copy, preserving all other bytes and mode.
    sudo cat "$phase" > "$WORK/ssh-phase.sh"
    helper edit-ip "$WORK/ssh-phase.sh" "$KNOWN_IP"
    bash -n "$WORK/ssh-phase.sh"
    sudo tee "$phase" < "$WORK/ssh-phase.sh" >/dev/null
    sudo bash -n "$phase"
    sudo cp -- "$key.pub" "$BOOT_MOUNT/id_rsa.pub"
    sudo cmp -- "$key.pub" "$BOOT_MOUNT/id_rsa.pub"
    sudo test -x "$ROOT_MOUNT/usr/local/sbin/billspi-runner"
    sudo test -f "$ROOT_MOUNT/etc/systemd/system/billspi-setup.service"
    [[ $(sudo readlink "$ROOT_MOUNT/etc/systemd/system/multi-user.target.wants/billspi-setup.service") == /etc/systemd/system/billspi-setup.service ]] \
        || die 'Setup service enable link is incorrect.'
    sudo test -f "$ROOT_MOUNT/usr/local/lib/billspi/tools/billspi-diagnostics.sh"
    sudo grep -qx 'Storage=persistent' "$ROOT_MOUNT/etc/systemd/journald.conf.d/99-billspi-install.conf"
    sudo grep -qx 'SystemMaxUse=200M' "$ROOT_MOUNT/etc/systemd/journald.conf.d/99-billspi-install.conf"
    for selected in 'StandardOutput=journal+console' 'StandardError=journal+console' 'LogRateLimitIntervalSec=0'; do
        sudo grep -Fxq "$selected" "$ROOT_MOUNT/etc/systemd/system/billspi-setup.service"
    done
    sudo grep -n '^KNOWN_IP=' "$phase"
    verify_mounts
    sync
    sudo umount "$ROOT_MOUNT"
    sudo umount "$BOOT_MOUNT"
    OWNS_MOUNTS=0
    sudo udisksctl power-off -b "$CURRENT_DEVICE"
    note 'READY: key, SSH address, runner, service and persistent logging checks passed.'
    printf 'Remove the card, insert it into the powered-off Pi, then boot the Pi.\n'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi

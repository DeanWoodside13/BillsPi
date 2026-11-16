#!/usr/bin/python3
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
"""BillsPi offline diagnostics 1.3: run on Ubuntu, never execute card files.
Usage: sudo /usr/bin/python3 -I billspi-offline-diagnostics.py ROOT BOOT OUTPUT_DIR
Example: sudo /usr/bin/python3 -I billspi-offline-diagnostics.py /mnt/pi-root /mnt/pi-boot "$PWD"
Requires Python 3.9+ standard library; journalctl is optional. Mounts must already
be read-only; ext4 must also use noload/norecovery. Output stays on Ubuntu.
"""
import argparse
import collections
import datetime
import fnmatch
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time

VERSION = '1.3'
FILE_LIMIT = 8 * 1024 * 1024
TOTAL_LIMIT = 64 * 1024 * 1024
MAX_ENTRIES = 12000
MAX_HASH_SIZE = 128 * 1024 * 1024


def utc():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def mount_table():
    def unescape(s):
        return re.sub(r'\\([0-7]{3})', lambda m: chr(int(m[1], 8)), s)
    result = []
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        a, b = line.split(' - ', 1)
        left, right = a.split(), b.split()
        result.append(dict(target=unescape(left[4]), options=left[5].split(','),
                           fstype=right[0], source=unescape(right[1]),
                           super_options=right[2].split(',')))
    return result


def sensitive(path):
    parts = Path(path).parts
    name = Path(path).name
    return (name in ('PrepBill.sh', 'firstrun.sh') or '.ssh' in parts
            or path.startswith(('/etc/shadow', '/etc/gshadow', '/etc/ssl/private/',
                                '/etc/NetworkManager/system-connections/', '/etc/apt/auth.conf'))
            or ('/etc/ssh/' in path and name.startswith('ssh_host_') and name.endswith('_key')))


class Card:
    """Resolve target absolute symlinks inside the card, not against Ubuntu /."""
    def __init__(self, root, boot):
        self.root, self.boot = Path(root), Path(boot)

    def physical(self, parts):
        if parts[:2] == ['boot', 'firmware']:
            return self.boot.joinpath(*parts[2:])
        return self.root.joinpath(*parts)

    def resolve(self, path, follow_final=True):
        if not path.startswith('/'):
            raise ValueError('Card paths must be absolute')
        pending, done, links = collections.deque(path.split('/')), [], 0
        while pending:
            part = pending.popleft()
            if part in ('', '.'):
                continue
            if part == '..':
                if not done:
                    raise ValueError('Path escapes card root')
                done.pop()
                continue
            candidate = self.physical(done + [part])
            mode = candidate.lstat().st_mode
            if stat.S_ISLNK(mode) and (pending or follow_final):
                links += 1
                if links > 40:
                    raise ValueError('Symlink loop')
                target = os.readlink(candidate)
                if target.startswith('/'):
                    done = []
                pending.extendleft(reversed(target.split('/')))
            else:
                done.append(part)
        return self.physical(done), '/' + '/'.join(done)

    def glob(self, pattern):
        choices = ['/']
        for component in pattern.strip('/').split('/'):
            following = []
            for parent in choices:
                try:
                    physical, _ = self.resolve(parent)
                    with os.scandir(physical) as entries:
                        names = sorted(e.name for e in entries if fnmatch.fnmatchcase(e.name, component))
                    following.extend(parent.rstrip('/') + '/' + n for n in names)
                except (OSError, ValueError):
                    continue
            choices = following[:MAX_ENTRIES]
        return choices

    def walk(self, path, depth):
        """List directories without following symlink entries; bounded traversal."""
        pending = [(path, 0)]
        count = 0
        while pending and count < MAX_ENTRIES:
            current, level = pending.pop()
            yield current
            count += 1
            try:
                physical, _ = self.resolve(current, follow_final=False)
                if level < depth and stat.S_ISDIR(physical.lstat().st_mode):
                    with os.scandir(physical) as entries:
                        names = sorted(e.name for e in entries)
                    pending.extend((current.rstrip('/') + '/' + n, level + 1) for n in reversed(names))
            except (OSError, ValueError):
                continue


def redact(data):
    text = data.decode('utf-8', errors='replace')
    lines, private = [], False
    cred = re.compile(r'authorization["\']?\s*:|pi_pass_plain|(password|passwd|passphrase|psk|secret|token|api[_-]?key)["\']?\s*[:=]|[?&](token|key|password|secret)=|--?(password|passphrase|token|secret)(\s|=)', re.I)
    crypt = re.compile(r'\$(y|gy|[156]|2[aby]?)\$[A-Za-z0-9./]')
    url = re.compile(r'([A-Za-z][A-Za-z0-9+.-]*://)[^/\s"<>]*@')
    for line in text.splitlines():
        if re.search(r'-----BEGIN .*PRIVATE KEY-----', line):
            private = True
            lines.append('[PRIVATE KEY BLOCK REDACTED]')
            continue
        if private:
            if re.search(r'-----END .*PRIVATE KEY-----', line):
                private = False
            continue
        if cred.search(line) or crypt.search(line):
            lines.append('[POSSIBLE CREDENTIAL LINE REDACTED]')
        else:
            lines.append(url.sub(r'\1[REDACTED]@', line) if '://' in line else line)
    return ('\n'.join(lines) + '\n').encode()


class Report:
    def __init__(self, work, card):
        self.data = Path(work) / 'report'
        (self.data / 'evidence').mkdir(parents=True)
        self.card = card
        self.index, self.meta, self.seen = [], [], set()
        self.stored = 0

    def put(self, source, data, status='OK', limit=FILE_LIMIT):
        allowance = max(0, min(limit, TOTAL_LIMIT - self.stored))
        if not allowance:
            self.index.append(dict(source=source, status='SKIPPED_TOTAL_LIMIT'))
            return
        clean = redact(data)
        truncated = len(clean) > allowance
        clean = clean[:allowance]
        name = 'evidence/%04d.txt' % (len(self.index) + 1)
        (self.data / name).write_bytes(clean)
        self.stored += len(clean)
        self.index.append(dict(source=source, file=name, status=status,
                               output_truncated=truncated, stored_bytes=len(clean)))

    def metadata(self, path):
        if path in self.seen:
            return
        self.seen.add(path)
        row = dict(path=path)
        try:
            p, canonical = self.card.resolve(path, follow_final=False)
            s = p.lstat()
            row.update(mode=stat.filemode(s.st_mode), octal=oct(stat.S_IMODE(s.st_mode)),
                       uid=s.st_uid, gid=s.st_gid, size=s.st_size, mtime_ns=s.st_mtime_ns)
            if p.is_symlink():
                row['symlink_target'] = os.readlink(p)
            row['xattrs'] = {}
            for name in ('system.posix_acl_access', 'system.posix_acl_default', 'security.capability'):
                try:
                    row['xattrs'][name] = os.getxattr(p, name, follow_symlinks=False).hex()
                except OSError:
                    pass
        except (OSError, ValueError) as e:
            row['error'] = str(e)
        self.meta.append(row)

    def text(self, path, limit=1048576, tail=False):
        self.metadata(path)
        try:
            p, canonical = self.card.resolve(path)
            if sensitive(path) or sensitive(canonical):
                self.index.append(dict(source=path, status='EXCLUDED_CONTENT_AND_HASH'))
                return
            if not stat.S_ISREG(p.stat().st_mode):
                return
            with p.open('rb') as f:
                if tail:
                    f.seek(max(0, p.stat().st_size - limit))
                data = f.read(limit + 1)
            status = 'INPUT_TRUNCATED' if len(data) > limit or (tail and p.stat().st_size > limit) else 'OK'
        except (OSError, ValueError) as e:
            self.index.append(dict(source=path, status='UNAVAILABLE', error=str(e)))
            return
        # Output failures must abort, not be mistaken for missing card input.
        self.put(path, data[:limit], status, limit)

    def digest(self, path, algorithm='sha256'):
        p, canonical = self.card.resolve(path)
        if sensitive(path) or sensitive(canonical):
            return dict(status='EXCLUDED_CONTENT_AND_HASH')
        s = p.stat()
        if not stat.S_ISREG(s.st_mode) or s.st_size > MAX_HASH_SIZE:
            return dict(status='SKIPPED_TYPE_OR_SIZE')
        h = hashlib.new(algorithm)
        start = time.monotonic()
        with p.open('rb') as f:
            for block in iter(lambda: f.read(1024 * 1024), b''):
                h.update(block)
                if time.monotonic() - start > 20:
                    return dict(status='HASH_TIME_LIMIT')
        return dict(status='OK', algorithm=algorithm, digest=h.hexdigest(), canonical=canonical)

    def host_command(self, args, timeout=30, limit=2097152):
        # Only fixed Ubuntu binaries are passed here; never target executables.
        source = 'HOST READER: ' + ' '.join(args)
        if not Path(args[0]).is_file():
            self.index.append(dict(source=source, status='OPTIONAL_HOST_TOOL_MISSING'))
            return
        data, truncated, timed_out = bytearray(), False, False
        env = dict(PATH='/usr/sbin:/usr/bin:/sbin:/bin', LC_ALL='C',
                   SYSTEMD_PAGER='cat', SYSTEMD_COLORS='0')
        try:
            p = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, start_new_session=True, env=env)
        except OSError as e:
            self.index.append(dict(source=source, status='OPTIONAL_HOST_TOOL_UNAVAILABLE', error=str(e)))
            return
        with p, selectors.DefaultSelector() as selector:
            try:
                selector.register(p.stdout, selectors.EVENT_READ)
                deadline = time.monotonic() + timeout
                while selector.get_map():
                    if time.monotonic() > deadline and not timed_out:
                        timed_out = True
                        try:
                            os.killpg(p.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    for key, _ in selector.select(0.1):
                        block = os.read(key.fd, 65536)
                        if not block:
                            selector.unregister(key.fileobj)
                            continue
                        room = max(0, limit - len(data))
                        data.extend(block[:room])
                        truncated |= len(block) > room
                # EOF does not imply process exit: apply the same deadline here.
                try:
                    rc = p.wait(timeout=max(0, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    timed_out = True
                    try:
                        os.killpg(p.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    rc = p.wait()
            finally:
                # Also clean up the reader on Ctrl-C or an unexpected read error.
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                p.wait()
        self.put(source, bytes(data), 'timeout=%s exit=%s input_truncated=%s' % (timed_out, rc, truncated), limit)


def validate(root, boot, output):
    mounts = mount_table()
    for path, fstype in ((root, 'ext4'), (boot, 'vfat')):
        matching = [m for m in mounts if m['target'] == str(path)]
        if len(matching) != 1:
            raise ValueError('%s must be a distinct mounted partition' % path)
        m = matching[0]
        if m['fstype'] != fstype or 'ro' not in m['options']:
            raise ValueError('%s must be mounted read-only as %s' % (path, fstype))
        if fstype == 'ext4' and not {'noload', 'norecovery'}.intersection(m['options'] + m['super_options']):
            raise ValueError('Root mount must include noload/norecovery')
        if any(Path(x['target']) != path and path in Path(x['target']).parents for x in mounts):
            raise ValueError('Unexpected nested mount below %s; use separate root and boot mountpoints' % path)
    if root == boot or root in boot.parents or boot in root.parents or root == Path('/'):
        raise ValueError('Root and boot mountpoints must be distinct and separate')
    if not output.is_dir() or any(p == output or p in output.parents for p in (root, boot)):
        raise ValueError('Output must be an existing Ubuntu directory outside both card mounts')
    out_mount = max((m for m in mounts if Path(m['target']) == output or Path(m['target']) in output.parents),
                    key=lambda m: len(m['target']))
    sources = {m['source'] for m in mounts if m['target'] in (str(root), str(boot))}
    if out_mount['source'] in sources or 'rw' not in out_mount['options']:
        raise ValueError('Output must be writable and on a different filesystem from the card')
    if shutil.disk_usage(output).free < 256 * 1024 * 1024:
        raise ValueError('At least 256 MiB free in the output filesystem is required')
    card = Card(root, boot)
    p, _ = card.resolve('/usr/local/lib/billspi/billspi-runner')
    if not p.is_file():
        raise ValueError('BillsPi runner not found on the selected card')
    return mounts


def collect(report):
    card = report.card
    print('[1/6] Installation transcript, configuration and generated services', flush=True)
    # Export the normal-sized transcript in full before spending the evidence budget.
    report.metadata('/var/log/billspi')
    report.text('/var/log/billspi/install.log', 32 * 1024 * 1024)
    for path in ('/etc/os-release', '/etc/rpi-issue', '/etc/fstab', '/etc/timezone',
                 '/etc/sysctl.conf', '/etc/systemd/journald.conf', '/etc/logrotate.conf',
                 '/etc/apt/billspi-pi-unattended.conf',
                 '/var/lib/dpkg/status', '/var/lib/dpkg/diversions', '/var/lib/dpkg/statoverride',
                 '/var/lib/dpkg/triggers/Unincorp', '/var/lib/dpkg/triggers/File', '/var/lib/apt/extended_states',
                 '/etc/audit/auditd.conf', '/etc/ufw/ufw.conf', '/etc/ufw/user.rules', '/etc/ufw/user6.rules',
                 '/etc/ufw/sysctl.conf', '/etc/default/zramswap', '/etc/default/network_optimize',
                 '/boot/firmware/config.txt', '/boot/firmware/cmdline.txt'):
        report.text(path, FILE_LIMIT if path == '/var/lib/dpkg/status' else 1048576)
    # No arbitrary /etc archive; explicit diagnostic trees and suffixes only.
    for tree, depth in (('/etc/systemd/system', 3), ('/etc/systemd/journald.conf.d', 1),
                        ('/etc/logrotate.d', 1), ('/etc/aide', 2), ('/etc/sysctl.d', 1),
                        ('/etc/modprobe.d', 1), ('/etc/modules-load.d', 1), ('/etc/apt/apt.conf.d', 1),
                        ('/etc/rpi/swap.conf.d', 1), ('/etc/tmpfiles.d', 1)):
        for path in card.walk(tree, depth):
            report.metadata(path)
            if path.endswith(('.service', '.timer', '.conf')) or tree in ('/etc/logrotate.d', '/etc/aide', '/etc/apt/apt.conf.d'):
                report.text(path, 262144)
    for pattern in ('/usr/local/bin/*.sh', '/usr/local/sbin/*.sh', '/usr/local/bin/gunzip',
                    '/usr/local/sbin/apt-fast', '/usr/local/lib/billspi/billspi-runner',
                    '/usr/local/lib/billspi/billspi-setup.service', '/usr/local/lib/billspi/phases/*.sh'):
        for path in card.glob(pattern):
            report.text(path, 524288)
    for path in card.walk('/var/lib/billspi', 1):
        report.text(path, 262144)
    # Inventory even if helpers no longer exist after cleanup.
    for tree in ('/usr/local/bin', '/usr/local/sbin', '/var/lib/billspi'):
        for path in card.walk(tree, 1):
            report.metadata(path)

    print('[2/6] Sensitive-path permissions (metadata only)', flush=True)
    for path in ('/etc/shadow', '/etc/shadow-', '/etc/gshadow', '/etc/gshadow-', '/etc/sudoers',
                 '/etc/sudoers.d', '/etc/ssh', '/var/log/sudo.log', '/var/log/journal',
                 '/tmp', '/var/tmp', '/var/lib/aide', '/var/log/aide', '/var/lib/dpkg'):
        report.metadata(path)
    for pattern in ('/etc/sudoers.d/*', '/etc/ssh/ssh_host_*', '/etc/NetworkManager/system-connections/*',
                    '/var/lib/aide/aide.db*', '/home/*', '/home/*/.ssh', '/home/*/.ssh/*',
                    '/root/.ssh', '/root/.ssh/*', '/lib/netplan/*', '/etc/netplan/*'):
        for path in card.glob(pattern):
            report.metadata(path)

    print('[3/6] Boot and kernel/module inventory', flush=True)
    kernel_hashes = []
    for path in card.walk('/boot', 1):
        report.metadata(path)
    for path in card.walk('/boot/firmware', 2):
        report.metadata(path)
    for pattern in ('/boot/config-*', '/usr/lib/modules/*/build/.config', '/usr/lib/modules/*/config'):
        for path in card.glob(pattern):
            report.text(path, 1048576)
    for pattern in ('/boot/vmlinuz-*', '/boot/initrd.img-*', '/boot/firmware/kernel*.img', '/boot/firmware/initramfs*'):
        for path in card.glob(pattern):
            try:
                kernel_hashes.append(dict(path=path, **report.digest(path)))
            except (OSError, ValueError) as e:
                kernel_hashes.append(dict(path=path, error=str(e)))
    for path in card.glob('/usr/lib/modules/*'):
        report.metadata(path)
        for name in ('modules.dep', 'modules.alias', 'modules.builtin', 'modules.builtin.modinfo', 'modules.softdep'):
            report.text(path + '/' + name, 2097152)
    report.put('Kernel file SHA-256', json.dumps(kernel_hashes, indent=2).encode())

    print('[4/6] Selected package-file consistency', flush=True)
    selected = {'libc-bin', 'man-db', 'initramfs-tools', 'initramfs-tools-core', 'coreutils', 'grep',
                'findutils', 'tar', 'gzip', 'apt', 'dpkg', 'sudo', 'openssh-server', 'ufw', 'systemd',
                'zram-tools', 'systemd-zram-generator', 'rpi-swap', 'aide', 'aide-common', 'auditd',
                'raspi-firmware', 'unattended-upgrades'}
    checks, checked = [], 0
    package_deadline = time.monotonic() + 180
    manifests = sorted(card.glob('/var/lib/dpkg/info/*.md5sums'),
                       key=lambda p: (Path(p).name.startswith('linux-image-'), p))
    for path in manifests:
        package = Path(path).name[:-8].split(':', 1)[0]
        if package not in selected and not package.startswith('linux-image-'):
            continue
        report.text(path, 2097152)
        for suffix in ('.conffiles', '.list'):
            report.text(path[:-8] + suffix, 2097152)
        try:
            p, canonical = card.resolve(path)
            if (sensitive(path) or sensitive(canonical) or not stat.S_ISREG(p.stat().st_mode)
                    or p.stat().st_size > 2097152):
                continue
            with p.open('rb') as f:
                manifest_data = f.read(2097153)
        except (OSError, ValueError) as e:
            report.index.append(dict(source=path, status='MANIFEST_UNAVAILABLE', error=str(e)))
            continue
        if len(manifest_data) > 2097152:
            continue
        for line in manifest_data.decode(errors='replace').splitlines():
            if checked >= 5000 or time.monotonic() > package_deadline:
                checks.append(dict(status='STOPPED_PACKAGE_CHECK_LIMIT',
                                   limit='5000 files or 180 seconds'))
                break
            match = re.match(r'^([0-9a-fA-F]{32})\s+(.+)$', line)
            if not match:
                continue
            expected, name = match.groups()
            target = '/' + name.lstrip('/')
            checked += 1
            row = dict(package=package, path=target, expected_md5=expected)
            try:
                result = report.digest(target, 'md5')
                row.update(result)
                if result.get('status') == 'OK':
                    row['status'] = 'MATCH' if result['digest'].lower() == expected.lower() else 'DIFFERENT'
            except (OSError, ValueError) as e:
                row.update(status='UNAVAILABLE', error=str(e))
            checks.append(row)
        if checked >= 5000 or time.monotonic() > package_deadline:
            break
    report.put('Selected package MD5 comparison (differences require interpretation)', json.dumps(checks, indent=2).encode())

    print('[5/6] Retained file logs and persistent journal', flush=True)
    for path in ('/var/log/aide/aide-check.log', '/var/log/aide/aide.log', '/var/log/ssh_setup.log',
                 '/var/log/ssh_perf_setup.log', '/var/log/auto-update-script.log',
                 '/var/log/billspi-monthly-upgrade.log', '/var/log/apt/history.log', '/var/log/apt/term.log'):
        report.text(path, 2097152, tail=True)
    for path in card.glob('/var/log/unattended-upgrades/*.log'):
        report.text(path, 2097152, tail=True)
    for path in card.glob('/var/log/journal/*'):
        if not re.fullmatch(r'[0-9a-f]{32}', Path(path).name):
            continue
        try:
            directory, canonical = card.resolve(path)
            if not canonical.startswith('/var/log/journal/'):
                report.index.append(dict(source=path, status='SKIPPED_JOURNAL_OUTSIDE_ALLOWLIST'))
                continue
            # Reject symlink journal entries rather than letting a host reader follow them.
            journal_files = list(directory.iterdir())
            if any(p.is_symlink() or not p.is_file() for p in journal_files):
                report.index.append(dict(source=path, status='SKIPPED_UNEXPECTED_JOURNAL_ENTRY'))
                continue
        except (OSError, ValueError):
            continue
        cmd = ['/usr/bin/journalctl', '--directory=' + str(directory), '--no-pager']
        report.host_command(cmd + ['--list-boots'])
        report.host_command(cmd + ['-o', 'short-iso-precise', '-u', 'billspi-setup.service'],
                            timeout=60, limit=8 * 1024 * 1024)
        report.host_command(cmd + ['-o', 'short-iso-precise', '-t', 'billspi-runner', '-t', 'billspi'],
                            timeout=60, limit=4 * 1024 * 1024)
        report.host_command(cmd + ['-o', 'short-iso-precise', '-p', 'warning'],
                            timeout=60, limit=8 * 1024 * 1024)
        report.host_command(cmd + ['-o', 'short-iso-precise', '-n', '5000', '-u', 'aide-initialize.service',
                                  '-u', 'aide-check.service', '-u', 'dailyaidecheck.service',
                                  '-u', 'network_optimize.service', '-u', 'ufw.service',
                                  '-u', 'systemd-sysctl.service', '-u', 'systemd-journald.service'])
    return checks


README = '''BillsPi OFFLINE diagnostic snapshot 1.3
This is collected by Ubuntu readers against already-mounted read-only Pi
partitions. No Pi binaries/scripts, AIDE scans, package scripts, chroot, repairs,
network requests, mount changes or service changes are run. No files are written
to the card. Only a private staging directory and result archive on Ubuntu are
written. Target absolute symlinks are resolved inside the card; /boot/firmware
maps to the separately supplied boot mount.

Read SUMMARY.txt, index.json, metadata.json and evidence/*.txt. Missing optional
files/tools are observations, not automatically defects. File reads, stored
output and command runtime are bounded; indexes record skips/truncation/errors.
The installation transcript is collected first, up to 32 MiB, from its
beginning; its complete original remains unchanged on the card. index.json marks
INPUT_TRUNCATED if the transcript exceeds this limit. Configuration content is
capped per input, normally 256 KiB–2 MiB, maximum 8 MiB.
Stored evidence is capped at 64 MiB; metadata traversal at 12000 entries per tree;
selected package checking at 5000 files or 180 seconds, 128 MiB/file and 20 seconds/hash.
Kernel-image packages are checked after the selected userspace packages. Host journal
commands for setup, runner and warning journals cover all retained boots with
60-second and 4–8 MiB limits, explicitly recorded on truncation. Other host journal
commands are capped at 30 seconds and 2 MiB; selected service excerpts retain
5000 entries. Journal files are read by Ubuntu journalctl, never by card binaries.
An I/O call blocked inside the kernel cannot be interrupted by a Python deadline.
The card must remain mounted and connected until completion.

Package MD5 checks compare with records on this same installation, not an
independent authenticated repository. A mismatch can reflect intentional local
configuration, a diversion or other legitimate change. Kernel hashes identify
files, not their trustworthiness. Conffile records are supplied for review;
this collector does not automatically judge every conffile modification.
AIDE database contents are not exported; presence/size/ownership alone do not
prove integrity checks work. Offline files cannot establish current runtime
firewall rules, swap activity or hardware behavior. Earlier lost RAM journals
cannot be recovered. FAT boot modes/ownership reflect Ubuntu mount policy.

Private keys, authorized_keys, shadow/gshadow contents, Wi-Fi connection profiles,
APT credentials and PrepBill.sh/firstrun.sh contents AND hashes are excluded.
Metadata may include their filenames, sizes and numeric ownership. ACL/capability
xattrs only are collected. Logs/configuration receive best-effort credential
redaction; it is not a guarantee against arbitrary secrets. Hostnames, addresses,
usernames and package/file paths remain. Review before public sharing.
Exit 0 means the archive was produced, not that the installation is defect-free.
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('root', type=Path)
    parser.add_argument('boot', type=Path)
    parser.add_argument('output', type=Path, help='Existing Ubuntu output directory, outside card')
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('Run with sudo /usr/bin/python3 -I')
    os.umask(0o077)
    root, boot, output = (x.resolve(strict=True) for x in (args.root, args.boot, args.output))
    mounts = validate(root, boot, output)
    archive = None
    success = False
    try:
        with tempfile.TemporaryDirectory(prefix='.billspi-offline-work-', dir=output) as work:
            report = Report(work, Card(root, boot))
            report.put('Ubuntu mount evidence for card', json.dumps([m for m in mounts if m['target'] in (str(root), str(boot))], indent=2).encode())
            started = utc()
            checks = collect(report)
            print('[6/6] Verifying and packaging the export', flush=True)
            summary = ('BillsPi offline diagnostic collector %s\nStarted UTC: %s\nFinished UTC: %s\n'
                       'Root: %s\nBoot: %s\nPackage comparison records (including limits): %d\n'
                       'Package files MATCH: %d\nPackage files DIFFERENT: %d\n'
                       'Other package results: %d\nMetadata records: %d\nEvidence index entries: %d\n'
                       'Stored evidence bytes: %d\n\nInspect index.json for missing files, errors and limits.\n'
                       'Read README.txt for interpretation. No corrections were applied.\n') % (
                       VERSION, started, utc(), root, boot, len(checks),
                       sum(c.get('status') == 'MATCH' for c in checks),
                       sum(c.get('status') == 'DIFFERENT' for c in checks),
                       sum(c.get('status') not in ('MATCH', 'DIFFERENT') for c in checks),
                       len(report.meta), len(report.index), report.stored)
            (report.data / 'SUMMARY.txt').write_text(summary)
            (report.data / 'README.txt').write_text(README)
            (report.data / 'index.json').write_text(json.dumps(report.index, indent=2))
            (report.data / 'metadata.json').write_text(json.dumps(report.meta, indent=2))
            manifest = []
            for path in sorted(report.data.rglob('*')):
                if path.is_file():
                    manifest.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.relative_to(report.data).as_posix())
            (report.data / 'SHA256SUMS').write_text('\n'.join(manifest) + '\n')
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
            fd, filename = tempfile.mkstemp(prefix='billspi-offline-diagnostics-' + stamp + '-', suffix='.tar.gz', dir=output)
            os.close(fd)
            archive = Path(filename)
            with tarfile.open(archive, 'w:gz', compresslevel=1) as tar:
                tar.add(report.data, arcname='report')
            with gzip.open(archive, 'rb') as f:
                while f.read(1024 * 1024):
                    pass
            # Keep the verified export even when a filesystem rejects handoff.
            success = True
            sudo_uid = os.environ.get('SUDO_UID', '')
            sudo_user = os.environ.get('SUDO_USER', '')
            owner = None
            try:
                if (sudo_uid or sudo_user) and (sudo_uid, sudo_user) != ('0', 'root'):
                    if not re.fullmatch(r'[1-9][0-9]*', sudo_uid) or not sudo_user:
                        raise ValueError('The sudo user could not be matched to a local account')
                    with open('/etc/passwd', encoding='utf-8') as accounts:
                        for line in accounts:
                            fields = line.rstrip('\n').split(':')
                            if len(fields) == 7 and fields[0] == sudo_user and fields[2] == sudo_uid:
                                owner = (int(fields[2]), int(fields[3]))
                                break
                    if owner is None:
                        raise ValueError('The sudo user could not be matched to a local account')
                if owner is not None:
                    os.chown(archive, *owner, follow_symlinks=False)
                metadata = archive.stat()
                if (stat.S_IMODE(metadata.st_mode) != 0o600
                        or (owner is not None and (metadata.st_uid, metadata.st_gid) != owner)):
                    raise OSError('The output filesystem did not retain private permissions or requested ownership')
            except (OSError, ValueError) as error:
                print('WARNING: %s. Verified archive retained: %s' % (error, archive), file=sys.stderr)
            print('\nOffline diagnostic archive ready:\n' + str(archive))
            print('SHA-256: ' + hashlib.sha256(archive.read_bytes()).hexdigest())
            print('Upload this .tar.gz file. The mounted card was not changed.')
            print('If access is denied, run this as your regular user to make a private copy (adjust the source path if moved):')
            print('sudo install -m 600 -o "$(id -u)" -g "$(id -g)" -- %s "$HOME"/%s' %
                  (shlex.quote(str(archive)), shlex.quote('private-' + archive.name)))
        return 0
    finally:
        if not success and archive is not None:
            archive.unlink(missing_ok=True)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, KeyError) as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
    except KeyboardInterrupt:
        print('Interrupted; temporary collection files removed.', file=sys.stderr)
        raise SystemExit(130)

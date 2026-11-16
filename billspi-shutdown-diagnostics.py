#!/usr/bin/python3
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
"""BillsPi .53 shutdown supplement 1.0 — run on Ubuntu, not on the Pi.

sudo /usr/bin/python3 -I billspi-shutdown-diagnostics.py \
    --root /mnt/pi-root --device /dev/sda2 --output "$HOME/Desktop/Pi"

Requires only Python 3.9+ and Ubuntu's journalctl. The Pi root must already be
mounted ext4 ro,noload (shown as ro,norecovery). No mounting, unmounting,
package changes, service actions, network access or execution of card files.
Creates its own temporary directory and one owner-readable .tar.gz on Ubuntu.
"""
import argparse
import collections
import datetime
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time

VERSION = '1.0'
JOURNALCTL = '/usr/bin/journalctl'
FILE_LIMIT = 2 * 1024 * 1024
COMMAND_LIMIT = 16 * 1024 * 1024
COMMAND_TIMEOUT = 90
UNITS = (
    'zramswap.service', 'dev-zram0.swap', 'systemd-zram-setup@zram0.service',
    'rpi-zram-writeback.service', 'rpi-zram-writeback.timer',
    'rpi-setup-loop@var-swap.service', 'rpi-resize-swap-file.service',
    'watchdog.service', 'wd_keepalive.service',
)
UNIT_FILES = UNITS + ('systemd-zram-setup@.service', 'rpi-setup-loop@.service')
PACKAGES = ('zram-tools', 'watchdog', 'systemd', 'kmod', 'util-linux',
            'rpi-swap', 'systemd-zram-generator')


def utc():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def under(path, parent):
    return path == parent or parent in path.parents


def mounts():
    def unescape(s):
        return re.sub(r'\\([0-7]{3})', lambda m: chr(int(m[1], 8)), s)
    result = []
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        a, b = line.split(' - ', 1)
        left, right = a.split(), b.split()
        result.append(dict(target=unescape(left[4]), source=unescape(right[1]),
                           device=left[2], fsroot=unescape(left[3]),
                           fstype=right[0], options=left[5].split(','),
                           super_options=right[2].split(',')))
    return result


def validate_mount(root, output, expected, rows):
    if root == Path('/') or under(output, root) or under(root, output):
        raise ValueError('Use a separate Ubuntu output directory, outside the Pi mount.')
    matches = [r for r in rows if Path(r['target']) == root]
    if len(matches) != 1:
        raise ValueError(f'{root} must be an existing, unambiguous mountpoint.')
    card = matches[0]
    if card['fstype'] != 'ext4' or card['fsroot'] != '/':
        raise ValueError('Expected the complete Pi ext4 root partition, not a bind subdirectory.')
    options = set(card['options']) | set(card['super_options'])
    if 'ro' not in card['options'] or not options.intersection({'noload', 'norecovery'}):
        raise ValueError('Pi root must be mounted ro,noload (displayed as ro,norecovery).')
    dev = os.stat(expected)
    if not stat.S_ISBLK(dev.st_mode):
        raise ValueError(f'{expected} is not a block device.')
    device_id = f'{os.major(dev.st_rdev)}:{os.minor(dev.st_rdev)}'
    if card['device'] != device_id:
        raise ValueError(f'{root} is not mounted from the requested device {expected}.')
    host_root = next(r for r in rows if r['target'] == '/')
    if card['device'] == host_root['device']:
        raise ValueError('Refusing the filesystem containing Ubuntu /.')
    if output.stat().st_dev == root.stat().st_dev:
        raise ValueError('Output must not be on the Pi root filesystem, even through another mount.')
    # A separately mounted boot partition beneath root is harmless; all other
    # nested mounts could redirect an evidence read into a different filesystem.
    for row in rows:
        target = Path(row['target'])
        if target != root and under(target, root):
            if target not in (root/'boot', root/'boot/firmware'):
                raise ValueError(f'Unexpected nested mount under Pi root: {target}')
    return card


class Card:
    """Rebase absolute card symlinks inside root; never follow them into Ubuntu."""
    def __init__(self, root):
        self.root = root

    def resolve(self, logical):
        if not logical.startswith('/'):
            raise ValueError('Card paths must be absolute.')
        pending, done, links = collections.deque(logical.split('/')), [], 0
        while pending:
            item = pending.popleft()
            if item in ('', '.'):
                continue
            if item == '..':
                if not done:
                    raise ValueError('Symlink attempts to escape card root.')
                done.pop()
                continue
            target = self.root.joinpath(*done, item)
            mode = target.lstat().st_mode
            if stat.S_ISLNK(mode):
                links += 1
                if links > 40:
                    raise ValueError('Too many symlinks.')
                dest = os.readlink(target)
                if dest.startswith('/'):
                    done = []
                pending.extendleft(reversed(dest.split('/')))
            else:
                done.append(item)
        physical = self.root.joinpath(*done)
        if physical.stat().st_dev != self.root.stat().st_dev:
            raise ValueError('Resolved path leaves the Pi root filesystem.')
        return physical, '/' + '/'.join(done)

    def read(self, logical):
        path, canonical = self.resolve(logical)
        if (canonical.startswith(('/etc/shadow', '/etc/gshadow', '/root/', '/home/',
                                  '/etc/ssl/private/', '/etc/NetworkManager/system-connections/',
                                  '/etc/apt/auth.conf')) or
                (canonical.startswith('/etc/ssh/ssh_host_') and not canonical.endswith('.pub'))):
            raise ValueError('Refusing sensitive/unrelated symlink target.')
        if not stat.S_ISREG(path.stat().st_mode):
            raise ValueError('Not a regular file (possibly a masked unit).')
        with path.open('rb') as f:
            raw = f.read(FILE_LIMIT + 1)
        return raw[:FILE_LIMIT], canonical, len(raw) > FILE_LIMIT, path.stat()

    def confs(self, logical):
        try:
            path, _ = self.resolve(logical)
            if not path.is_dir():
                return []
            names = sorted(p.name for p in path.iterdir() if p.name.endswith('.conf'))
            if len(names) > 256:
                raise ValueError(f'Too many configuration files in {logical}.')
            return [logical.rstrip('/') + '/' + n for n in names]
        except FileNotFoundError:
            return []


def redact(data):
    # Preserve commands and service settings; suppress obvious credentials only.
    text, private, out = data.decode('utf-8', errors='replace'), False, []
    credential = re.compile(r'authorization["\']?\s*:|'
                            r'(password|passwd|passphrase|psk|secret|token|api[_-]?key)["\']?\s*[:=]|'
                            r'\$(y|gy|[156]|2[aby]?)\$[A-Za-z0-9./]', re.I)
    for line in text.splitlines():
        if re.search(r'-----BEGIN .*PRIVATE KEY-----', line):
            private = True
            out.append('[PRIVATE KEY BLOCK REDACTED]')
        elif private:
            if re.search(r'-----END .*PRIVATE KEY-----', line):
                private = False
        elif credential.search(line):
            out.append('[POSSIBLE CREDENTIAL LINE REDACTED]')
        else:
            out.append(re.sub(r'([A-Za-z][A-Za-z0-9+.-]*://)[^/\s"<>]*@',
                              r'\1[REDACTED]@', line))
    return ('\n'.join(out) + '\n').encode()


def journal_files(card):
    base, _ = card.resolve('/var/log/journal')
    found = []
    # Regular files only; no symlinked directories or files passed to journalctl.
    for directory, dirs, files in os.walk(base, followlinks=False):
        dirs[:] = sorted(n for n in dirs if not (Path(directory)/n).is_symlink())
        if len(Path(directory).relative_to(base).parts) >= 2:
            dirs[:] = []
        for name in sorted(files):
            p = Path(directory)/name
            s = p.lstat()
            if (name.endswith(('.journal', '.journal~')) and stat.S_ISREG(s.st_mode)
                    and s.st_dev == card.root.stat().st_dev):
                found.append(p)
    if not found:
        raise ValueError('No persistent journal files found on the Pi card.')
    if len(found) > 256:
        raise ValueError('More than 256 journal files; stop rather than silently omit files.')
    return found


def capture(args):
    """Bound journal reads; record truncation/timeouts instead of hiding them."""
    environment = dict(PATH='/usr/sbin:/usr/bin:/sbin:/bin', LANG='C.UTF-8',
                       LC_ALL='C.UTF-8', TZ='UTC', SYSTEMD_COLORS='0',
                       SYSTEMD_PAGERSECURE='1')
    begin = time.monotonic()
    result = dict(command=args, started_utc=utc(), timed_out=False, truncated=False)
    buf = bytearray()
    with subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, env=environment,
                          start_new_session=True) as proc:
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(proc.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    if time.monotonic() - begin > COMMAND_TIMEOUT:
                        result['timed_out'] = True
                        break
                    for key, _ in selector.select(timeout=0.25):
                        block = os.read(key.fileobj.fileno(), 65536)
                        if not block:
                            selector.unregister(key.fileobj)
                            continue
                        available = COMMAND_LIMIT - len(buf)
                        buf.extend(block[:available])
                        if len(block) > available:
                            result['truncated'] = True
                            break
                    if result['truncated']:
                        break
            if result['timed_out'] or result['truncated']:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            remaining = max(0.1, COMMAND_TIMEOUT - (time.monotonic() - begin))
            try:
                proc.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                result['timed_out'] = True
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait()
        finally:
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait()
        result['exit_status'] = proc.returncode
    result['ended_utc'] = utc()
    result['captured_bytes'] = len(buf)
    return bytes(buf), result


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--root', default='/mnt/pi-root')
    parser.add_argument('--device', default='/dev/sda2')
    parser.add_argument('--output', required=True, help='Existing output directory on Ubuntu')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise ValueError('Run with sudo /usr/bin/python3 -I so protected Pi journals can be read.')
    os.umask(0o077)
    root = Path(args.root).resolve(strict=True)
    output = Path(args.output).resolve(strict=True)
    if not output.is_dir():
        raise ValueError('Output must be an existing directory on Ubuntu.')
    owner_uid = int(os.environ.get('SUDO_UID', os.getuid()))
    owner = pwd.getpwuid(owner_uid)
    owner_gid = owner.pw_gid
    home = Path(owner.pw_dir).resolve(strict=True)
    if not under(output, home) or output.stat().st_dev != home.stat().st_dev:
        raise ValueError('Choose an output folder within your Ubuntu home directory, '
                         'on the same filesystem (for example ~/Desktop/Pi).')
    mount = validate_mount(root, output, args.device, mounts())
    card = Card(root)
    # Verify an installed BillsPi payload rather than an unrelated ext4 volume.
    card.read('/usr/local/lib/billspi/billspi-runner')
    card.read('/var/lib/billspi/setup.done')
    if not os.access(JOURNALCTL, os.X_OK):
        raise ValueError('Ubuntu /usr/bin/journalctl is missing or not executable.')
    journals = journal_files(card)
    print(f'Validated read-only Pi root: {root} ({mount["source"]})', flush=True)
    print(f'Reading {len(journals)} existing journal files. No card code will run.', flush=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    work = Path(tempfile.mkdtemp(prefix=f'billspi-53-shutdown-{stamp}-', dir=output))
    report = work/'report'
    report.mkdir()
    (report/'config').mkdir()
    archive = output/(work.name + '.tar.gz')
    index, commands = [], []
    try:
        paths = ['/etc/os-release', '/etc/machine-id', '/etc/default/zramswap',
                 '/etc/default/watchdog', '/etc/default/wd_keepalive', '/etc/watchdog.conf',
                 '/usr/sbin/zramswap', '/etc/fstab', '/etc/systemd/system.conf',
                 '/etc/systemd/journald.conf', '/etc/systemd/zram-generator.conf',
                 '/usr/lib/systemd/zram-generator.conf', '/etc/ld.so.preload',
                 '/etc/rpi/swap.conf', '/var/lib/dpkg/status',
                 '/usr/local/lib/billspi/phases/45-swap-zram-and-mglru.sh']
        dirs = ['/etc/systemd/system.conf.d', '/usr/lib/systemd/system.conf.d',
                '/etc/systemd/journald.conf.d', '/usr/lib/systemd/journald.conf.d',
                '/etc/systemd/zram-generator.conf.d', '/usr/lib/systemd/zram-generator.conf.d',
                '/etc/modules-load.d', '/etc/modprobe.d', '/usr/lib/modprobe.d',
                '/etc/rpi/swap.conf.d']
        for base in ('/etc/systemd/system', '/run/systemd/system',
                     '/usr/local/lib/systemd/system', '/usr/lib/systemd/system'):
            for unit in UNIT_FILES:
                paths.append(base+'/'+unit)
                dirs.append(base+'/'+unit+'.d')
            dirs.append(base+'/service.d')
            dirs.append(base+'/swap.d')
        for package in ('zram-tools', 'watchdog'):
            for suffix in ('', ':arm64'):
                for extension in ('.list', '.md5sums', '.conffiles'):
                    paths.append('/var/lib/dpkg/info/'+package+suffix+extension)
        for directory in dirs:
            try:
                paths.extend(card.confs(directory))
            except (OSError, ValueError) as error:
                index.append(dict(source=directory, status='DIRECTORY_UNAVAILABLE', error=str(error)))
        for logical in dict.fromkeys(paths):
            row = dict(source=logical)
            try:
                data, canonical, clipped, metadata = card.read(logical)
            except (OSError, ValueError) as error:
                row.update(status='UNAVAILABLE', error=str(error))
            else:
                filename = 'config/%03d.txt' % (len(index)+1)
                selected = data
                if logical == '/var/lib/dpkg/status':
                    selected = b'\n\n'.join(block for block in data.split(b'\n\n')
                                           if any(b'Package: '+p.encode() in block.splitlines()
                                                  for p in PACKAGES)) + b'\n'
                    row['selection'] = list(PACKAGES)
                (report/filename).write_bytes(redact(selected))
                row.update(status='TRUNCATED' if clipped else 'OK', file=filename,
                           canonical=canonical, size=metadata.st_size,
                           mode=oct(stat.S_IMODE(metadata.st_mode)),
                           uid=metadata.st_uid, gid=metadata.st_gid,
                           sha256_of_captured_input=hashlib.sha256(data).hexdigest())
            index.append(row)
        base = [JOURNALCTL, '--no-pager', '--utc', '--all', '-o', 'short-iso-precise']
        for path in journals:
            base.append('--file='+str(path))
        unit_args = [item for unit in UNITS for item in ('-u', unit)]
        jobs = [('retained-boots.txt', ['--list-boots']),
                ('shutdown-services.txt', unit_args),
                ('system-manager.txt', ['_PID=1']),
                ('shutdown-manager.txt', ['SYSLOG_IDENTIFIER=systemd-shutdown']),
                ('kernel-all-boots.txt', ['_TRANSPORT=kernel'])]
        for filename, extra in jobs:
            print('Collecting '+filename+' ...', flush=True)
            raw, status = capture(base+extra)
            status['file'] = filename
            (report/filename).write_bytes(redact(raw))
            commands.append(status)
        (report/'file-index.json').write_text(json.dumps(index, indent=2)+'\n')
        (report/'command-status.json').write_text(json.dumps(commands, indent=2)+'\n')
        (report/'collection.json').write_text(json.dumps(dict(
            collector='BillsPi .53 shutdown supplement', version=VERSION, collected_utc=utc(),
            root=str(root), mount=mount, journal_files=[str(p.relative_to(root)) for p in journals],
            note='Read-only offline evidence. /run contents are unavailable after shutdown.'
        ), indent=2)+'\n')
        incomplete = any(x['exit_status'] != 0 or x['timed_out'] or x['truncated'] for x in commands)
        incomplete = incomplete or any(x['status'] == 'TRUNCATED' for x in index)
        (report/'README.txt').write_text(
            'BillsPi .53 supplementary shutdown diagnostics\n'
            'Ubuntu reads the mounted Pi; no Pi executables are run.\n'
            'Includes all retained boots/priorities for selected services, PID1 and kernel.\n'
            'No -k, -b, warning-only filter or tail limit was used.\n'
            'Each command has a 90-second/16-MiB limit; any limit is recorded.\n'
            'Configuration files are capped at 2 MiB and individually indexed.\n'
            'Absent optional configs, /run state and unit overrides are expected.\n'
            'Absolute symlinks are resolved within the card; special files are not read.\n'
            'Obvious credential lines are redacted. Network addresses/hostnames may remain.\n'
            'The archive contains text reports, not raw journal databases or private keys.\n'
            f'Collection has command errors or truncated output: {incomplete}\n')
        sums = []
        for p in sorted(report.rglob('*')):
            if p.is_file():
                sums.append(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(report)))
        (report/'SHA256SUMS').write_text('\n'.join(sums)+'\n')
        # Exclusive creation: never overwrite an existing archive or Ubuntu file.
        with archive.open('xb') as raw:
            with tarfile.open(fileobj=raw, mode='w:gz') as tar:
                tar.add(report, arcname='report', recursive=True)
            raw.flush()
            os.fsync(raw.fileno())
        os.chown(archive, owner_uid, owner_gid)
        os.chmod(archive, 0o600)
    except BaseException:
        print(f'Collection stopped. Evidence retained in: {work}', file=sys.stderr)
        if archive.exists():
            print(f'Archive may be incomplete; do not assume success: {archive}', file=sys.stderr)
        raise
    else:
        # Delete only the new, private temporary directory created by this run.
        shutil.rmtree(work)
        print('\nArchive created'+(' WITH COLLECTION WARNINGS' if incomplete else '')+':', flush=True)
        print(archive, flush=True)
        print('Upload this .tar.gz. It is owned by the user who invoked sudo.', flush=True)
        print('The Pi card remains mounted read-only; no existing Ubuntu files were edited.', flush=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print('STOP: '+str(error), file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print('Stopped by user.', file=sys.stderr)
        sys.exit(130)

#!/usr/bin/env python3
"""Install the plugin while preserving existing bar placement and settings."""
import errno
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
from datetime import datetime

def access_acl(path):
    try:
        return os.getxattr(path, 'system.posix_acl_access')
    except OSError as error:
        if error.errno not in (errno.ENODATA, errno.ENOTSUP):
            raise
        return None


def private_backup(source, destination):
    # Create exclusively with 0600 before copying any private content.
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'wb') as output, source.open('rb') as original:
            os.fchmod(output.fileno(), 0o600)
            shutil.copyfileobj(original, output)
    except BaseException:
        destination.unlink(missing_ok=True)
        raise


def atomic_config_write(path, settings):
    # Respect symlinked configurations and create the replacement beside its target.
    target = path.resolve() if path.is_symlink() else path
    original = target.stat() if target.exists() else None
    acl = access_acl(target) if original else None
    fd, filename = tempfile.mkstemp(prefix='shell.json.ddev-', dir=target.parent)
    temporary = Path(filename)
    try:
        with os.fdopen(fd, 'w') as output:
            os.fchmod(output.fileno(), 0o600)
            output.write(json.dumps(settings, indent=2) + '\n')
            output.flush()
            os.fsync(output.fileno())
            if original:
                current = os.fstat(output.fileno())
                if (current.st_uid, current.st_gid) != (original.st_uid, original.st_gid):
                    os.fchown(output.fileno(), original.st_uid, original.st_gid)
                # Do not inherit a directory ACL that grants different users access.
                if acl is not None:
                    os.setxattr(output.fileno(), 'system.posix_acl_access', acl)
                else:
                    try:
                        os.removexattr(output.fileno(), 'system.posix_acl_access')
                    except OSError as error:
                        if error.errno not in (errno.ENODATA, errno.ENOTSUP):
                            raise
                os.fchmod(output.fileno(), stat.S_IMODE(original.st_mode))
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)


source = Path(__file__).resolve().parent
manifest = json.loads((source / 'manifest.json').read_text())
plugin_id = manifest['id']
config_home = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config'))
omarchy = config_home / 'omarchy'
config = omarchy / 'shell.json'
destination = omarchy / 'plugins' / plugin_id
stamp = datetime.now().strftime('%Y%m%d-%H%M%S-%f')
# Validate the existing configuration and source before changing either.
settings = json.loads(config.read_text()) if config.exists() else {'version': 1}
runtime_files = ('backend.py', 'notifications.py', 'Monitoring.js', 'ddev.svg', 'DDEV-LOGO-LICENSE', manifest['entryPoints']['barWidget'], 'manifest.json')
for filename in runtime_files:
    if not (source / filename).is_file():
        raise SystemExit('Missing plugin file: ' + filename)

layout = settings.setdefault('bar', {}).setdefault('layout', {})
if not layout:
    defaults = Path('/usr/share/omarchy/config/omarchy/shell.json')
    if defaults.exists():
        layout.update(json.loads(defaults.read_text())['bar']['layout'])
# Keep one bar slot when reinstalling the same plugin.
existing = None
for section, entries in layout.items():
    if not isinstance(entries, list):
        continue
    kept = []
    for entry in entries:
        if isinstance(entry, dict) and entry.get('id') == plugin_id:
            if existing is not None:
                existing.update(entry)
                continue
            existing = entry
        kept.append(entry)
    layout[section] = kept
if existing is None:
    right = layout.setdefault('right', [])
    position = next((i + 1 for i, entry in enumerate(right) if isinstance(entry, dict) and entry.get('id') == 'omarchy.tray'), 0)
    right.insert(position, {'id': plugin_id})
omarchy.mkdir(parents=True, exist_ok=True)
if config.exists():
    backup = config.with_name('shell.json.bak.ddev-' + stamp)
    private_backup(config, backup)
    print('Config backup:', backup)
if destination.exists() and destination.resolve() != source:
    backup_dir = omarchy / 'plugin-backups' / (plugin_id + '-' + stamp)
    backup_dir.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(destination, backup_dir)
destination.mkdir(parents=True, exist_ok=True)
for filename in runtime_files:
    target = destination / filename
    if (source / filename).resolve() != target.resolve():
        shutil.copy2(source / filename, target)
atomic_config_write(config, settings)
print('Installed:', destination)
print('Configured bar widget:', plugin_id)

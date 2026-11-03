import errno
import io
from contextlib import redirect_stdout
import json
import struct
import os
import runpy
import stat
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config_home = Path(self.temp.name)
        self.omarchy = self.config_home / 'omarchy'
        self.omarchy.mkdir()
        self.config = self.omarchy / 'shell.json'
        self.installer = Path(__file__).parent / 'install.py'

    def install(self, umask=0o022):
        env = dict(os.environ, XDG_CONFIG_HOME=str(self.config_home))
        subprocess.run([sys.executable, str(self.installer)], env=env, check=True, capture_output=True, text=True, umask=umask)
        return json.loads(self.config.read_text())

    def test_clean_install_has_root_manifest_and_runtime_files(self):
        self.config.write_text(json.dumps({'bar': {'layout': {'right': [{'id': 'omarchy.tray'}]}}}))
        config = self.install()
        plugin = self.omarchy / 'plugins/ianzano.ddev'
        self.assertEqual(json.loads((plugin / 'manifest.json').read_text())['id'], 'ianzano.ddev')
        self.assertTrue((plugin / 'Panel.qml').is_file())
        self.assertTrue((plugin / 'backend.py').is_file())
        self.assertTrue((plugin / 'notifications.py').is_file())
        self.assertTrue((plugin / 'Monitoring.js').is_file())
        self.assertTrue((plugin / 'ddev.svg').is_file())
        self.assertTrue((plugin / 'DDEV-LOGO-LICENSE').is_file())
        self.assertEqual(config['bar']['layout']['right'][1]['id'], 'ianzano.ddev')

    def test_reinstall_preserves_placement_settings_and_other_config(self):
        previous = {'version': 1, 'bar': {'layout': {'left': [{'id': 'ianzano.ddev', 'refreshIntervalSec': 35}], 'right': [{'id': 'omarchy.tray'}]}}, 'plugins': [], 'idle': {'lock': 300}}
        self.config.write_text(json.dumps(previous))
        self.install()
        self.assertEqual(self.install(), previous)
        self.assertTrue(any(self.omarchy.glob('shell.json.bak.ddev-*')))
        self.assertTrue(any((self.omarchy / 'plugin-backups').glob('ianzano.ddev-*/files/manifest.json')))

    def test_reinstall_deduplicates_bar_slots(self):
        self.config.write_text(json.dumps({'bar': {'layout': {'left': [{'id': 'ianzano.ddev', 'refreshIntervalSec': 30}], 'right': [{'id': 'ianzano.ddev'}]}}}))
        self.install()
        config = self.install()
        entries = [e for section in config['bar']['layout'].values() for e in section if e.get('id') == 'ianzano.ddev']
        self.assertEqual(entries, [{'id': 'ianzano.ddev', 'refreshIntervalSec': 30}])

    def test_private_config_and_backups_stay_private_with_permissive_umask(self):
        self.omarchy.chmod(0o755)
        self.config.write_text(json.dumps({'private': 'fixture-only', 'bar': {'layout': {'right': []}}}))
        self.config.chmod(0o600)
        expected_owner = (self.config.stat().st_uid, self.config.stat().st_gid)
        self.install(umask=0o022)
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)
        self.assertEqual((self.config.stat().st_uid, self.config.stat().st_gid), expected_owner)
        self.assertEqual(json.loads(self.config.read_text())['private'], 'fixture-only')
        for backup in self.omarchy.glob('shell.json.bak.ddev-*'):
            self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o600)
        self.assertFalse(list(self.omarchy.glob('shell.json.ddev-*')))

    def test_existing_modes_are_preserved(self):
        for mode in (0o600, 0o640, 0o644):
            with self.subTest(mode=mode):
                self.config.write_text('{}')
                self.config.chmod(mode)
                self.install()
                self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), mode)
        self.assertTrue(all(stat.S_IMODE(p.stat().st_mode) == 0o600 for p in self.omarchy.glob('shell.json.bak.ddev-*')))

    def test_new_config_is_private_regardless_of_umask(self):
        self.install(umask=0)
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)

    def test_symlink_config_retains_link_and_target_permissions(self):
        target = self.config_home / 'actual-settings.json'
        target.write_text('{}')
        target.chmod(0o600)
        self.config.symlink_to(target)
        self.install()
        self.assertTrue(self.config.is_symlink())
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        self.assertIn('bar', json.loads(target.read_text()))

    def test_private_temporary_and_backup_files_before_content_write(self):
        self.config.write_text('{}')
        self.config.chmod(0o600)
        copy = __import__('shutil').copyfileobj
        replace = Path.replace
        mkstemp = tempfile.mkstemp
        checked = []
        def check_create(*args, **kwargs):
            fd, name = mkstemp(*args, **kwargs)
            self.assertEqual(os.fstat(fd).st_mode & 0o077, 0)
            if kwargs.get('prefix', '').startswith('shell.json.ddev-'):
                checked.append('created-private')
            return fd, name
        def check_copy(original, output, *args):
            if Path(original.name) == self.config:
                self.assertEqual(stat.S_IMODE(os.fstat(output.fileno()).st_mode), 0o600)
                checked.append('backup')
            return copy(original, output, *args)
        def check_replace(temporary, destination):
            if destination != self.config:
                return replace(temporary, destination)
            self.assertEqual(stat.S_IMODE(temporary.stat().st_mode), 0o600)
            self.assertTrue(any(e.get('id') == 'ianzano.ddev' for e in json.loads(temporary.read_text())['bar']['layout']['right']))
            checked.append('replacement')
            return replace(temporary, destination)
        with redirect_stdout(io.StringIO()), patch.dict(os.environ, {'XDG_CONFIG_HOME': str(self.config_home)}), patch('shutil.copyfileobj', side_effect=check_copy), patch.object(Path, 'replace', check_replace), patch('tempfile.mkstemp', side_effect=check_create):
            runpy.run_path(str(self.installer))
        self.assertEqual(checked, ['backup', 'created-private', 'replacement'])

    def test_failed_replace_keeps_original_private_and_removes_temporary(self):
        original = '{"private": "fixture-only"}'
        self.config.write_text(original)
        self.config.chmod(0o600)
        replace = Path.replace
        def fail_config_replace(temporary, destination):
            if destination == self.config:
                raise OSError('simulated failure')
            return replace(temporary, destination)
        with redirect_stdout(io.StringIO()), patch.dict(os.environ, {'XDG_CONFIG_HOME': str(self.config_home)}), patch.object(Path, 'replace', fail_config_replace):
            with self.assertRaises(OSError):
                runpy.run_path(str(self.installer))
        self.assertEqual(self.config.read_text(), original)
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)
        self.assertFalse(list(self.omarchy.glob('shell.json.ddev-*')))

    def acl(self, named_uid, directory=False):
        return struct.pack('<I', 2) + b''.join(struct.pack('<HHI', tag, permissions, identifier) for tag, permissions, identifier in (
            (1, 7 if directory else 6, 0xffffffff), (2, 4, named_uid), (4, 0, 0xffffffff), (16, 4, 0xffffffff), (32, 0, 0xffffffff)))

    def set_acl(self, path, name, value):
        try:
            os.setxattr(path, name, value)
        except OSError as error:
            if error.errno in (errno.ENOTSUP, errno.EPERM):
                self.skipTest('Filesystem does not support POSIX ACL tests')
            raise

    def test_existing_access_acl_is_preserved(self):
        self.config.write_text('{}')
        original_acl = self.acl(os.getuid() + 1)
        self.set_acl(self.config, 'system.posix_acl_access', original_acl)
        self.set_acl(self.omarchy, 'system.posix_acl_default', self.acl(os.getuid() + 2, directory=True))
        self.install()
        self.assertEqual(os.getxattr(self.config, 'system.posix_acl_access'), original_acl)
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o640)

    def test_directory_acl_is_not_added_to_previously_unshared_config(self):
        self.config.write_text('{}')
        self.config.chmod(0o640)
        self.set_acl(self.omarchy, 'system.posix_acl_default', self.acl(os.getuid() + 1, directory=True))
        self.install()
        with self.assertRaises(OSError) as failure:
            os.getxattr(self.config, 'system.posix_acl_access')
        self.assertEqual(failure.exception.errno, errno.ENODATA)
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o640)

    def test_predictable_old_temporary_path_is_not_followed(self):
        unrelated = self.config_home / 'unrelated.json'
        unrelated.write_text('untouched')
        (self.omarchy / 'shell.json.ddev-tmp').symlink_to(unrelated)
        self.install()
        self.assertEqual(unrelated.read_text(), 'untouched')

    def test_plugin_backup_is_private_and_does_not_follow_external_symlinks(self):
        self.install()
        plugin = self.omarchy / 'plugins/ianzano.ddev'
        private = plugin / 'private-settings.json'
        private.write_text('{"private":"fixture-only"}')
        private.chmod(0o600)
        external = self.config_home / 'outside'
        external.mkdir()
        (external / 'private.txt').write_text('keep outside')
        (plugin / 'external-link').symlink_to(external, target_is_directory=True)
        self.install()
        backups = list((self.omarchy / 'plugin-backups').iterdir())
        self.assertEqual(len(backups), 1)
        self.assertEqual(stat.S_IMODE(backups[0].stat().st_mode), 0o700)
        self.assertTrue((backups[0] / 'files/external-link').is_symlink())
        self.assertEqual(stat.S_IMODE((backups[0] / 'files/private-settings.json').stat().st_mode), 0o600)
        self.assertEqual((external / 'private.txt').read_text(), 'keep outside')

    def test_runtime_destination_symlink_cannot_overwrite_another_file(self):
        self.install()
        plugin = self.omarchy / 'plugins/ianzano.ddev'
        external = self.config_home / 'unrelated.txt'
        external.write_text('keep unrelated data')
        (plugin / 'backend.py').unlink()
        (plugin / 'backend.py').symlink_to(external)
        self.install()
        self.assertEqual(external.read_text(), 'keep unrelated data')
        self.assertFalse((plugin / 'backend.py').is_symlink())
        self.assertEqual((plugin / 'backend.py').read_bytes(), (self.installer.parent / 'backend.py').read_bytes())

    def test_invalid_config_is_not_changed(self):
        self.config.write_text('invalid JSON')
        with self.assertRaises(subprocess.CalledProcessError):
            self.install()
        self.assertEqual(self.config.read_text(), 'invalid JSON')
        self.assertFalse((self.omarchy / 'plugins').exists())


if __name__ == '__main__':
    unittest.main()

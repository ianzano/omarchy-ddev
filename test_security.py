"""Security regressions use only synthetic files and isolated helper processes."""
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from test_backend import backend


class SecurityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.project = {'name': 'demo', 'approot': str(self.root / 'project'), 'status': 'running'}
        self.snapshots = Path(self.project['approot']) / '.ddev/db_snapshots'
        self.snapshots.mkdir(parents=True)
        (self.snapshots.parent / 'config.yaml').write_text('name: demo\n')
        for mock in (patch.object(backend, 'projects', return_value=[self.project]),
                     patch.object(backend, 'discovered_commands', return_value=[]),
                     patch.dict(os.environ, {'XDG_CONFIG_HOME': str(self.root / 'config')})):
            mock.start()
            self.addCleanup(mock.stop)

    def save(self):
        return backend.change_shortcut(self.project, json.dumps({'label': 'Example', 'command': 'exec echo example'}))

    def test_shortcut_temp_symlink_cannot_clobber_another_file(self):
        path = backend.shortcut_file(self.project)
        path.parent.mkdir(parents=True)
        unrelated = self.root / 'unrelated.txt'
        unrelated.write_text('keep this file')
        old_tmp = path.with_suffix('.tmp')
        old_tmp.symlink_to(unrelated)
        self.save()
        self.assertEqual(unrelated.read_text(), 'keep this file')
        self.assertTrue(old_tmp.is_symlink())
        self.assertFalse(path.is_symlink())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_symlink_lock_and_shortcut_config_are_rejected(self):
        path = backend.shortcut_file(self.project)
        path.parent.mkdir(parents=True)
        unrelated = self.root / 'unrelated.txt'
        unrelated.write_text('keep this file')
        lock = path.with_suffix('.lock')
        lock.symlink_to(unrelated)
        with self.assertRaises(OSError):
            self.save()
        lock.unlink()
        path.symlink_to(unrelated)
        with self.assertRaises(OSError):
            backend.shortcuts(self.project)
        self.assertEqual(unrelated.read_text(), 'keep this file')

    def test_shortcuts_reject_other_account_writable_storage(self):
        path = backend.shortcut_file(self.project)
        path.parent.mkdir(parents=True)
        path.parent.chmod(0o777)
        with self.assertRaises(ValueError):
            self.save()
        path.parent.chmod(0o700)
        self.save()
        path.chmod(0o666)
        with self.assertRaises(ValueError):
            backend.shortcuts(self.project)

    def test_failed_shortcut_replace_cleans_up_unique_temporary(self):
        self.save()
        path = backend.shortcut_file(self.project)
        original = path.read_bytes()
        with patch.object(Path, 'replace', side_effect=OSError('fixture failure')):
            with self.assertRaises(OSError):
                self.save()
        self.assertEqual(path.read_bytes(), original)
        self.assertFalse(list(path.parent.glob('*.tmp')))

    def test_directory_swap_cannot_redirect_snapshot_deletion(self):
        snapshot = self.snapshots / 'before.sql.gz'
        snapshot.write_bytes(b'intended snapshot')
        outside = self.root / 'outside'
        outside.mkdir()
        victim = outside / snapshot.name
        victim.write_bytes(b'keep unrelated file')
        moved = self.root / 'moved-snapshots'
        unlink = os.unlink
        swapped = []
        def swap_then_unlink(path, *args, **kwargs):
            if not swapped and Path(path).name == snapshot.name:
                self.snapshots.rename(moved)
                self.snapshots.symlink_to(outside, target_is_directory=True)
                swapped.append(True)
            return unlink(path, *args, **kwargs)
        with patch.object(backend.os, 'unlink', side_effect=swap_then_unlink):
            backend.delete_snapshot(self.project, str(snapshot))
        self.assertEqual(victim.read_bytes(), b'keep unrelated file')
        self.assertFalse((moved / snapshot.name).exists())
        self.assertTrue(swapped)

    def test_private_request_validation(self):
        args = ['save-command', 'private-project', '{"command":"private-value"}']
        self.assertEqual(backend.request_args(['request'], io.StringIO(json.dumps(args))), args)
        for value in ('not json', '{}', '["stop", 3]', '["stop", "x\\u0000y"]', '[' * 10000, 'x' * 1048577):
            with self.subTest(size=len(value)), self.assertRaisesRegex(ValueError, 'Invalid request payload'):
                backend.request_args(['request'], io.StringIO(value))
        self.assertEqual(backend.request_args(['list'], io.StringIO('')), ['list'])

    def test_private_request_values_do_not_appear_in_helper_argv(self):
        script = 'import backend,sys,signal; backend.request_args(["request"],sys.stdin); print("READY",flush=True); signal.pause()'
        process = subprocess.Popen([sys.executable, '-c', script], cwd=Path(__file__).parent,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            process.stdin.write(json.dumps(['save-command', 'private-project', 'private-shortcut-payload']))
            process.stdin.close()
            self.assertEqual(process.stdout.readline().strip(), 'READY')
            cmdline = Path('/proc/' + str(process.pid) + '/cmdline').read_bytes()
            self.assertNotIn(b'private-project', cmdline)
            self.assertNotIn(b'private-shortcut-payload', cmdline)
        finally:
            process.terminate()
            process.wait(timeout=3)
            process.stdout.close()
            process.stderr.close()

"""Security regressions use only synthetic files and isolated helper processes."""
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
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
        with patch.object(backend.os, 'replace', side_effect=OSError('fixture failure')):
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

    def test_directory_swap_cannot_redirect_shortcut_replacement(self):
        self.save()
        path = backend.shortcut_file(self.project)
        outside = self.root / 'outside-state'
        outside.mkdir()
        victim = outside / path.name
        victim.write_text('keep unrelated state')
        moved = self.root / 'moved-state'
        replace = os.replace
        swapped = []
        def swap_then_replace(source, target, *args, **kwargs):
            if not swapped:
                path.parent.rename(moved)
                path.parent.symlink_to(outside, target_is_directory=True)
                (outside / Path(source).name).write_text('attacker replacement')
                swapped.append(True)
            return replace(source, target, *args, **kwargs)
        with patch.object(backend.os, 'replace', side_effect=swap_then_replace):
            try:
                self.save()
            except (OSError, ValueError):
                pass
        self.assertTrue(swapped)
        self.assertEqual(victim.read_text(), 'keep unrelated state')

    def test_command_scan_does_not_block_if_regular_file_becomes_fifo(self):
        folder = self.snapshots.parent / 'commands/web'
        folder.mkdir(parents=True)
        os.mkfifo(folder / 'raced-command')
        script = """import backend,sys,json
from pathlib import Path
original = Path.is_file
Path.is_file = lambda path: path.name == 'raced-command' or original(path)
backend.child_environment = lambda: {'DDEV_GLOBAL_DIR': sys.argv[1] + '/global'}
backend.run = lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError('Unexpected command execution'))
assert backend.discovered_commands({'approot':sys.argv[1]}) == []
print('SCAN_PASSED')
"""
        process = subprocess.Popen([sys.executable, '-c', script, self.project['approot']], cwd=Path(__file__).parent,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            out, err = process.communicate(timeout=3)
            self.assertEqual(process.returncode, 0, err)
            self.assertIn('SCAN_PASSED', out)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()
            process.stderr.close()

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


class CaptureSecurityTests(unittest.TestCase):
    def test_large_single_log_line_is_bounded_during_capture(self):
        result = backend.run([sys.executable, '-c', 'import sys; sys.stdout.write("x"*2000000+"TAIL")'],
                             merged=True, capture_limit=24000, keep_tail=True)
        self.assertLessEqual(len(result.stdout), 24000)
        self.assertTrue(result.stdout.endswith('TAIL'))

    def test_metadata_capture_rejects_excessive_output(self):
        with self.assertRaisesRegex(RuntimeError, 'capture limit'):
            backend.run([sys.executable, '-c', 'import sys; sys.stdout.write("x"*1000000)'], capture_limit=4096)

    def test_timeout_stops_descendants_after_parent_has_exited(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / 'child.pid'
            child = 'import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); open(' + repr(str(marker)) + ',"w").write(str(os.getpid())); time.sleep(60)'
            parent = 'import subprocess,sys; subprocess.Popen([sys.executable,"-c",' + repr(child) + '])'
            try:
                with self.assertRaises(subprocess.TimeoutExpired):
                    backend.run([sys.executable, '-c', parent], timeout=0.5, stream=True)
                pid = int(marker.read_text())
                # Reaping may be handled by init; a zombie has already stopped.
                status = Path('/proc/' + str(pid) + '/stat')
                deadline = time.monotonic() + 1
                while status.exists() and not status.read_text().split(') ', 1)[1].startswith('Z') and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(not status.exists() or status.read_text().split(') ', 1)[1].startswith('Z'))
            finally:
                if marker.exists():
                    try: os.kill(int(marker.read_text()), signal.SIGKILL)
                    except ProcessLookupError: pass

    def test_log_cleanup_stops_children_that_ignore_termination(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / 'log-child.pid'
            child = 'import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); open(' + repr(str(marker)) + ',"w").write(str(os.getpid())); time.sleep(60)'
            parent = 'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",' + repr(child) + ']); print("ready",flush=True); time.sleep(60)'
            script = ('import backend,sys; backend.log_services=lambda *args:["web"]; '
                      'backend.log_command=lambda *args,**kw:[sys.executable,"-u","-c",' + repr(parent) + ']; '
                      'backend.follow_project_logs([],{"name":"demo","approot":sys.argv[1]})')
            process = subprocess.Popen([sys.executable, '-u', '-c', script, directory], cwd=Path(__file__).parent,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertIn('ready', process.stdout.readline())
                deadline = time.monotonic() + 2
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(marker.exists())
                process.terminate()
                _, error = process.communicate(timeout=8)
                self.assertEqual(process.returncode, 0, error)
                status = Path('/proc/' + marker.read_text() + '/stat')
                deadline = time.monotonic() + 1
                while status.exists() and not status.read_text().split(') ', 1)[1].startswith('Z') and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(not status.exists() or status.read_text().split(') ', 1)[1].startswith('Z'))
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                if marker.exists():
                    try: os.kill(int(marker.read_text()), signal.SIGKILL)
                    except ProcessLookupError: pass
                process.stdout.close()
                process.stderr.close()

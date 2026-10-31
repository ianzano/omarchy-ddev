import importlib.util
from pathlib import Path
import subprocess
import tempfile
import json
import sys
import io
import os
import socket
from contextlib import redirect_stdout
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('backend', Path(__file__).parent / 'backend.py')
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / '.ddev/db_snapshots').mkdir(parents=True)
        (self.root / '.ddev/config.yaml').write_text('name: demo\n')
        self.project = {'name': 'demo', 'approot': str(self.root), 'primary_url': 'https://demo.ddev.site'}
        mock = patch.object(backend, 'projects', return_value=[self.project])
        mock.start()
        self.addCleanup(mock.stop)

    def test_restart_rejects_non_running_projects(self):
        for status in ('stopped', 'paused', 'unknown', None):
            with self.subTest(status=status), patch.object(backend, 'run') as run:
                self.project['status'] = status
                with self.assertRaisesRegex(ValueError, 'only available for running'):
                    backend.main(['restart', 'demo'])
                run.assert_not_called()

    def test_restart_accepts_running_project(self):
        self.project['status'] = 'running'
        with patch.object(backend, 'run', return_value=subprocess.CompletedProcess([], 0, 'ok', '')) as run:
            self.assertTrue(backend.main(['restart', 'demo'])['ok'])
            self.assertEqual(run.call_args.args[0], ['ddev', 'restart'])

    def test_restart_accepts_active_unhealthy_project(self):
        self.project['status'] = 'unhealthy'
        with patch.object(backend, 'run', return_value=subprocess.CompletedProcess([], 0, 'ok', '')) as run:
            self.assertTrue(backend.main(['restart', 'demo'])['ok'])
            self.assertEqual(run.call_args.args[0], ['ddev', 'restart'])

    def test_stop_never_removes_data(self):
        with patch.object(backend, 'run', return_value=subprocess.CompletedProcess([], 0, 'ok', '')) as run:
            self.assertTrue(backend.main(['stop', 'demo'])['ok'])
            self.assertEqual(run.call_args.args[0], ['ddev', 'stop'])

    def test_poweroff_uses_global_command_without_removing_data(self):
        with patch.object(backend, 'run', return_value=subprocess.CompletedProcess([], 0, 'Stopped all projects', '')) as run:
            self.assertTrue(backend.main(['poweroff'])['ok'])
            self.assertEqual(run.call_args.args[0], ['ddev', 'poweroff'])
            self.assertTrue(run.call_args.kwargs['stream'])
            backend.projects.assert_not_called()

    def test_rejects_restore_outside_snapshot_list(self):
        with patch.object(backend, 'run') as run:
            with self.assertRaises(ValueError):
                backend.main(['restore', 'demo', '/tmp/unrelated.gz'])
            run.assert_not_called()

    def test_restore_handles_symlinked_ddev_and_spaces(self):
        (self.root / '.ddev').rename(self.root / 'ddev-real')
        (self.root / '.ddev').symlink_to(self.root / 'ddev-real', target_is_directory=True)
        snapshot = self.root / '.ddev/db_snapshots/before change-mysql_8.0.zst'
        snapshot.write_bytes(b'fixture')
        with patch.object(backend, 'run', return_value=subprocess.CompletedProcess([], 0, 'ok', '')) as run:
            self.assertTrue(backend.main(['restore', 'demo', str(snapshot.resolve())])['ok'])
            self.assertEqual(run.call_args.args[0], ['ddev', 'snapshot', 'restore', str(snapshot.resolve())])

    def test_rejects_invalid_snapshot_name(self):
        with patch.object(backend, 'run') as run:
            with self.assertRaises(ValueError):
                backend.main(['snapshot', 'demo', '--cleanup'])
            run.assert_not_called()

    def test_propagates_command_failure(self):
        with patch.object(backend, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'Docker unavailable')):
            result = backend.main(['start', 'demo'])
            self.assertFalse(result['ok'])
            self.assertIn('Docker unavailable', result['message'])

    def test_missing_registration_is_rejected(self):
        with self.assertRaises(ValueError):
            backend.main(['stop', 'unregistered'])

    def test_unavailable_docker_does_not_report_stopped(self):
        with patch.object(backend, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'permission denied')):
            result = backend.main(['list'])
            self.assertEqual(result['projects'][0]['status'], 'unknown')
            self.assertIn('permission denied', result['warning'])


class EnvironmentTests(unittest.TestCase):
    def setUp(self):
        backend.child_environment.cache_clear()
        self.addCleanup(backend.child_environment.cache_clear)

    def test_missing_user_variables_are_passed_to_child(self):
        manager = subprocess.CompletedProcess([], 0, json.dumps({'SSH_AUTH_SOCK': '/example/runtime/ssh-agent.socket', 'DDEV_TEST_SESSION': 'ready'}), '')
        with patch.dict(os.environ, {'PATH': '/usr/bin'}, clear=True), patch.object(backend.subprocess, 'run', return_value=manager):
            env = backend.child_environment()
        self.assertEqual(env['SSH_AUTH_SOCK'], '/example/runtime/ssh-agent.socket')
        self.assertEqual(env['DDEV_TEST_SESSION'], 'ready')

    def test_explicit_inherited_values_take_priority(self):
        manager = subprocess.CompletedProcess([], 0, json.dumps({'SSH_AUTH_SOCK': '/other/socket', 'PATH': '/other/bin'}), '')
        with patch.dict(os.environ, {'SSH_AUTH_SOCK': '/chosen/socket', 'PATH': '/usr/bin'}, clear=True), patch.object(backend.subprocess, 'run', return_value=manager):
            env = backend.child_environment()
        self.assertEqual(env['SSH_AUTH_SOCK'], '/chosen/socket')
        self.assertEqual(env['PATH'], '/usr/bin')

    def test_agent_socket_fallback_without_systemd(self):
        with tempfile.TemporaryDirectory() as directory:
            agent = socket.socket(socket.AF_UNIX)
            try:
                path = str(Path(directory) / 'ssh-agent.socket')
                agent.bind(path)
                with patch.dict(os.environ, {'XDG_RUNTIME_DIR': directory}, clear=True), patch.object(backend.subprocess, 'run', side_effect=OSError('unavailable')):
                    self.assertEqual(backend.child_environment()['SSH_AUTH_SOCK'], path)
            finally:
                agent.close()

    def test_regular_file_is_not_used_as_an_agent(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'ssh-agent.socket').write_text('not a socket')
            with patch.dict(os.environ, {'XDG_RUNTIME_DIR': directory}, clear=True), patch.object(backend.subprocess, 'run', side_effect=OSError('unavailable')):
                self.assertNotIn('SSH_AUTH_SOCK', backend.child_environment())


class StreamingTests(unittest.TestCase):
    def test_output_is_delivered_before_process_finishes(self):
        bridge = str(Path(backend.__file__).resolve())
        script = (
            "import importlib.util,sys; "
            "s=importlib.util.spec_from_file_location('bridge',sys.argv[1]); "
            "b=importlib.util.module_from_spec(s); s.loader.exec_module(b); "
            "b.run([sys.executable,'-u','-c',"
            "\"import sys,time; print('starting',flush=True); time.sleep(0.6); print('stderr ready',file=sys.stderr,flush=True)\"],stream=True)"
        )
        proc = subprocess.Popen([sys.executable, '-u', '-c', script, bridge], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            first = json.loads(proc.stdout.readline())
            self.assertEqual(first['event'], 'output')
            self.assertIn('starting', first['text'])
            self.assertIsNone(proc.poll())
            rest, errors = proc.communicate(timeout=5)
            self.assertEqual(proc.returncode, 0, errors)
            self.assertIn('stderr ready', ''.join(json.loads(line)['text'] for line in rest.splitlines()))
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            proc.stdout.close()
            proc.stderr.close()

    def test_streaming_preserves_result_and_failure_code(self):
        output = io.StringIO()
        with redirect_stdout(output):
            result = backend.run([sys.executable, '-c', "import sys; print('✓'); print('problem',file=sys.stderr); sys.exit(2)"], stream=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('✓', result.stdout)
        self.assertIn('problem', result.stdout)
        self.assertTrue(all(json.loads(line)['event'] == 'output' for line in output.getvalue().splitlines()))

    def test_streaming_timeout(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            backend.run([sys.executable, '-c', 'import time; time.sleep(10)'], timeout=0.1, stream=True)


if __name__ == '__main__':
    unittest.main()

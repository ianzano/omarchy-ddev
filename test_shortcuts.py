import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from test_backend import backend


class ShortcutsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.project = {'name': 'demo', 'approot': str(self.root / 'demo'), 'status': 'running'}
        self.folder = Path(self.project['approot']) / '.ddev'
        (self.folder / 'db_snapshots').mkdir(parents=True)
        (self.folder / 'config.yaml').write_text('name: demo\n')
        for mock in (patch.dict(os.environ, {'XDG_CONFIG_HOME': str(self.root / 'config')}),
                     patch.object(backend, 'projects', return_value=[self.project]),
                     patch.object(backend, 'discovered_commands', return_value=[])):
            mock.start()
            self.addCleanup(mock.stop)

    def save(self, **overrides):
        data = dict(label='Clear cache', command='drush cr')
        data.update(overrides)
        return backend.main(['save-command', 'demo', json.dumps(data)])['commands']

    def test_shortcuts_save_edit_remove_and_project_isolation(self):
        item = self.save()[0]
        self.assertEqual(backend.main(['commands', 'demo'])['commands'], [item])
        self.assertEqual(backend.shortcuts(dict(self.project, approot=str(self.root / 'other'))), [])
        edited = self.save(id=item['id'], label='Tests', command='ddev exec phpunit')
        self.assertEqual(len(edited), 1)
        self.assertEqual(edited[0]['command'], 'ddev exec phpunit')
        self.assertEqual(backend.shortcut_file(self.project).stat().st_mode & 0o777, 0o600)
        self.assertEqual(backend.main(['delete-command', 'demo', item['id']])['commands'], [])
        with self.assertRaises(ValueError):
            self.save(id=item['id'])

    def test_run_uses_saved_argv_with_quotes_and_streaming(self):
        item = self.save(command='ddev exec printf "%s" "hello world"')[0]
        with patch.object(backend, 'run', return_value=subprocess.CompletedProcess([], 0, 'hello world', '')) as run:
            self.assertTrue(backend.main(['custom-command', 'demo', item['id']])['ok'])
            self.assertEqual(run.call_args.args[0], ['ddev', 'exec', 'printf', '%s', 'hello world'])
            self.assertTrue(run.call_args.kwargs['stream'])
            self.assertEqual(run.call_args.kwargs['cwd'], self.project['approot'])

    def test_run_rechecks_running_and_unknown_ids(self):
        item = self.save()[0]
        with patch.object(backend, 'run') as run:
            with self.assertRaises(ValueError):
                backend.main(['custom-command', 'demo', 'missing'])
            self.project['status'] = 'stopped'
            with self.assertRaisesRegex(ValueError, 'Start the project'):
                backend.main(['custom-command', 'demo', item['id']])
            self.assertEqual(len(backend.main(['commands', 'demo'])['commands']), 1)
            run.assert_not_called()

    def test_invalid_shortcuts_rejected(self):
        for command in ('', '--project=other stop', 'exec echo yes && ddev stop', 'exec echo hi\nstop', 'exec "unterminated'):
            with self.subTest(command=command), self.assertRaises(ValueError):
                self.save(command=command)
        with self.assertRaises(ValueError):
            self.save(label='')

    def test_snapshot_delete_rejects_foreign_and_refreshes_list(self):
        snapshot = self.folder / 'db_snapshots' / 'before.sql.gz'
        snapshot.write_bytes(b'example')
        foreign = self.root / 'foreign.gz'
        foreign.write_bytes(b'keep')
        with self.assertRaises(ValueError):
            backend.main(['delete-snapshot', 'demo', str(foreign)])
        self.assertTrue(snapshot.exists())
        result = backend.main(['delete-snapshot', 'demo', str(snapshot)])
        self.assertEqual(result['snapshots'], [])
        self.assertFalse(snapshot.exists())
        self.assertTrue(foreign.exists())
        with self.assertRaises(ValueError):
            backend.main(['delete-snapshot', 'demo', str(snapshot)])

    def test_symlink_deletion_keeps_target(self):
        target = self.root / 'external.gz'
        target.write_bytes(b'keep')
        link = self.folder / 'db_snapshots' / 'link.gz'
        link.symlink_to(target)
        backend.main(['delete-snapshot', 'demo', str(target)])
        self.assertTrue(target.exists())
        self.assertFalse(link.is_symlink())

    def test_snapshot_folder_open_works_while_stopped(self):
        self.project['status'] = 'stopped'
        with patch.object(backend, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')) as run:
            self.assertTrue(backend.main(['snapshot-folder', 'demo'])['ok'])
            self.assertEqual(run.call_args.args[0], ['xdg-open', str(self.folder / 'db_snapshots')])
        (self.folder / 'db_snapshots').rmdir()
        with self.assertRaisesRegex(ValueError, 'No snapshot folder'):
            backend.main(['snapshot-folder', 'demo'])

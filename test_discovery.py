import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from test_backend import backend


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.project = {'name': 'demo', 'approot': str(self.root / 'project'), 'status': 'running'}
        self.global_dir = self.root / 'global'
        (Path(self.project['approot']) / '.ddev').mkdir(parents=True)
        (Path(self.project['approot']) / '.ddev/config.yaml').write_text('name: demo\n')
        for mock in (patch.object(backend, 'child_environment', return_value={'DDEV_GLOBAL_DIR': str(self.global_dir)}),
                     patch.object(backend, 'projects', return_value=[self.project]),
                     patch.object(backend, 'shortcut_file', return_value=self.root / 'shortcuts.json')):
            mock.start()
            self.addCleanup(mock.stop)

    def script(self, filename, usage, global_command=False):
        base = self.global_dir if global_command else Path(self.project['approot']) / '.ddev'
        path = base / 'commands/web' / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!/bin/bash\n## Usage: ' + usage + '\n## Description: Example command\nexit 99\n')
        return path

    def help(self, *names):
        return subprocess.CompletedProcess([], 0, json.dumps({'raw': {'Commands': [{'Name': name, 'Description': 'Example description'} for name in names]}}), '')

    def test_usage_names_global_project_symlinks_and_availability(self):
        self.script('different-filename', 'cache-clear [args]')
        self.script('global-command', 'build-assets', True)
        self.script('duplicate', 'cache-clear', True)
        self.script('disabled-on-this-os', 'unavailable')
        self.script('template.example', 'example-only')
        self.script('empty', '""')
        link = self.script('link', 'ignored')
        link.unlink()
        source = self.root / 'shared-script'
        source.write_text('## Usage: linked-command\n')
        link.symlink_to(source)
        with patch.object(backend, 'run', return_value=self.help('cache-clear', 'build-assets', 'linked-command', 'builtin', 'example-only')) as run:
            items = backend.discovered_commands(self.project)
        self.assertEqual([i['command'] for i in items], ['build-assets', 'cache-clear', 'linked-command'])
        self.assertTrue(all(i['source'] == 'ddev' and i['description'] == 'Example description' for i in items))
        self.assertEqual(run.call_args.args[0], ['ddev', 'help', '-j'])
        self.assertEqual(run.call_args.kwargs['cwd'], self.project['approot'])

    def test_catalog_includes_saved_and_discovered_and_preserves_warning(self):
        self.script('cache-clear', 'cache-clear')
        backend.shortcut_file(self.project).write_text(json.dumps([{'id': 'saved', 'label': 'Build', 'command': 'npm run build'}]))
        with patch.object(backend, 'run', return_value=self.help('cache-clear')):
            self.assertEqual(len(backend.main(['commands', 'demo'])['commands']), 2)
        with patch.object(backend, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'Unavailable')):
            result = backend.main(['commands', 'demo'])
            self.assertEqual(len(result['commands']), 1)
            self.assertIn('Could not discover', result['warning'])

    def test_discovered_run_revalidates_and_streams_via_ddev(self):
        self.script('cache-clear', 'cache-clear')
        with patch.object(backend, 'run', side_effect=[self.help('cache-clear'), subprocess.CompletedProcess([], 0, 'Done', '')]) as run:
            self.assertTrue(backend.main(['custom-command', 'demo', 'ddev:cache-clear'])['ok'])
            self.assertEqual(run.call_args.args[0], ['ddev', 'cache-clear'])
            self.assertTrue(run.call_args.kwargs['stream'])
        with patch.object(backend, 'run', return_value=self.help()) as run:
            with self.assertRaises(ValueError):
                backend.main(['custom-command', 'demo', 'ddev:cache-clear'])
            self.assertEqual(run.call_count, 1)

    def test_missing_definition_is_not_executable(self):
        with patch.object(backend, 'run') as run:
            with self.assertRaises(ValueError):
                backend.main(['custom-command', 'demo', 'ddev:delete'])
            run.assert_not_called()

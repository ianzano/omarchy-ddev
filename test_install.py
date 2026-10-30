import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config_home = Path(self.temp.name)
        self.omarchy = self.config_home / 'omarchy'
        self.omarchy.mkdir()
        self.config = self.omarchy / 'shell.json'
        self.installer = Path(__file__).parent / 'install.py'

    def install(self):
        env = dict(os.environ, XDG_CONFIG_HOME=str(self.config_home))
        subprocess.run([sys.executable, str(self.installer)], env=env, check=True, capture_output=True, text=True)
        return json.loads(self.config.read_text())

    def test_clean_install_has_root_manifest_and_runtime_files(self):
        self.config.write_text(json.dumps({'bar': {'layout': {'right': [{'id': 'omarchy.tray'}]}}}))
        config = self.install()
        plugin = self.omarchy / 'plugins/ianzano.ddev'
        self.assertEqual(json.loads((plugin / 'manifest.json').read_text())['id'], 'ianzano.ddev')
        self.assertTrue((plugin / 'Panel.qml').is_file())
        self.assertTrue((plugin / 'backend.py').is_file())
        self.assertEqual(config['bar']['layout']['right'][1]['id'], 'ianzano.ddev')

    def test_reinstall_preserves_placement_settings_and_other_config(self):
        previous = {'version': 1, 'bar': {'layout': {'left': [{'id': 'ianzano.ddev', 'refreshIntervalSec': 35}], 'right': [{'id': 'omarchy.tray'}]}}, 'plugins': [], 'idle': {'lock': 300}}
        self.config.write_text(json.dumps(previous))
        self.install()
        self.assertEqual(self.install(), previous)
        self.assertTrue(any(self.omarchy.glob('shell.json.bak.ddev-*')))
        self.assertTrue(any((self.omarchy / 'plugin-backups').glob('ianzano.ddev-*/manifest.json')))

    def test_reinstall_deduplicates_bar_slots(self):
        self.config.write_text(json.dumps({'bar': {'layout': {'left': [{'id': 'ianzano.ddev', 'refreshIntervalSec': 30}], 'right': [{'id': 'ianzano.ddev'}]}}}))
        self.install()
        config = self.install()
        entries = [e for section in config['bar']['layout'].values() for e in section if e.get('id') == 'ianzano.ddev']
        self.assertEqual(entries, [{'id': 'ianzano.ddev', 'refreshIntervalSec': 30}])

    def test_invalid_config_is_not_changed(self):
        self.config.write_text('invalid JSON')
        with self.assertRaises(subprocess.CalledProcessError):
            self.install()
        self.assertEqual(self.config.read_text(), 'invalid JSON')
        self.assertFalse((self.omarchy / 'plugins').exists())


if __name__ == '__main__':
    unittest.main()

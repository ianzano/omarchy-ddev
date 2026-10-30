#!/usr/bin/env python3
"""Run a concurrency smoke test with simulated projects in real Quickshell."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

project = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='ddev-ui-check-') as directory:
    root = Path(directory)
    for module in ('Ui', 'Commons'):
        (root / module).symlink_to(Path('/usr/share/omarchy/shell') / module, target_is_directory=True)
    (root / 'plugin').mkdir()
    source = (project / 'Panel.qml').read_text()
    # Test-only access to visual descendants, kept out of the installed plugin.
    source = source.replace('    id: root\n', '''    id: root
    function testFind(name, node) {
        node = node || content
        if (node.objectName === name) return node
        for (var i = 0; i < node.children.length; i++) {
            var result = testFind(name, node.children[i])
            if (result) return result
        }
        return null
    }
''', 1)
    (root / 'plugin/Panel.qml').write_text(source)
    shutil.copy2(project / 'tests/concurrency_backend.py', root / 'plugin/backend.py')
    shutil.copy2(project / 'tests/concurrency.qml', root / 'shell.qml')
    env = os.environ.copy()
    env['QT_QPA_PLATFORM'] = 'wayland'
    env['QT_QPA_PLATFORMTHEME'] = ''
    result = subprocess.run(['quickshell', '-p', str(root / 'shell.qml')], env=env,
                            capture_output=True, text=True, timeout=15)
    output = result.stdout + result.stderr
    if result.returncode or 'CONCURRENCY_CHECKS_PASSED' not in output or 'WARN scene:' in output:
        raise SystemExit(output)
    print('Quickshell concurrency checks passed: simultaneous processes, separate logs, isolated failures, per-project controls, job cleanup, and global-action exclusion.')

#!/usr/bin/env python3
"""Run concurrency and container-feature smoke tests with simulated projects in real Quickshell."""
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
    source = source.replace('property bool monitoringEnabled: true', 'property bool monitoringEnabled: false')
    source = source.replace('var follow = opened && view.live', 'var follow = view.live')
    shutil.copy2(project / 'Monitoring.js', root / 'plugin/Monitoring.js')
    # Test-only access to visual descendants, kept out of the installed plugin.
    source = source.replace('    id: root\n', '''    id: root
    property var testAlerts: []
    property var testNotifications: ({})
    property bool testAlertTransport: false
    function testFlushEarly() { announce(Monitoring.flush([], Date.now())) }
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
    source = source.replace('announce(Monitoring.flush(blocked))', 'announce(Monitoring.flush(blocked, Date.now() + 2100))')
    source = source.replace('    function announce(alerts) {', '    function announce(alerts) {\n        testAlerts = testAlerts.concat(alerts)')
    source = source.replace('if (!monitoringEnabled || !alertsEnabled) return', 'if ((!monitoringEnabled && !testAlertTransport) || !alertsEnabled) return')
    source = source.replace('property var payload: []', 'property var payload: []\n            stdout: StdioCollector { onStreamFinished: root.testNotifications = JSON.parse(text) }')
    (root / 'plugin/notifications.py').write_text('import json,sys\ndata=json.load(sys.stdin)\nprint(json.dumps({"alerts":data,"argv":sys.argv[1:]}))\n')
    (root / 'plugin/Panel.qml').write_text(source)
    env = os.environ.copy()
    env['QT_QPA_PLATFORM'] = 'wayland'
    env['QT_QPA_PLATFORMTHEME'] = ''
    for suite, fixture, marker in (('concurrency', 'concurrency', 'CONCURRENCY_CHECKS_PASSED'), ('features', 'features', 'FEATURE_CHECKS_PASSED'), ('log_reentry', 'features', 'LOG_REENTRY_CHECKS_PASSED'), ('domains', 'features', 'DOMAINS_CHECKS_PASSED'), ('tabs', 'features', 'TABS_CHECKS_PASSED'), ('stopped', 'features', 'STOPPED_CHECKS_PASSED'), ('shortcuts', 'shortcuts', 'SHORTCUTS_CHECKS_PASSED'), ('notifications', 'features', 'NOTIFICATIONS_CHECKS_PASSED'), ('startup_alerts', 'features', 'STARTUP_ALERTS_CHECKS_PASSED')):
        if os.environ.get('DDEV_UI_SUITE') and suite not in os.environ['DDEV_UI_SUITE'].split(','):
            continue
        shutil.copy2(project / ('tests/' + fixture + '_backend.py'), root / 'plugin/backend.py')
        shutil.copy2(project / ('tests/' + suite + '.qml'), root / 'shell.qml')
        result = subprocess.run(['quickshell', '-p', str(root / 'shell.qml')], env=env,
                                capture_output=True, text=True, timeout=15)
        output = result.stdout + result.stderr
        if result.returncode or marker not in output or 'WARN scene:' in output:
            raise SystemExit(output)
        print('Quickshell ' + suite + ' checks passed.')

#!/usr/bin/env python3
"""Render the real QML panel with synthetic data, without accessing a desktop."""
import os
from pathlib import Path
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
PREVIEWS = (
    ('overview', PROJECT / 'preview.png'),
    ('snapshots', PROJECT / 'docs/previews/snapshots.png'),
    ('console', PROJECT / 'docs/previews/console.png'),
)

with tempfile.TemporaryDirectory(prefix='omarchy-ddev-preview-') as directory:
    root = Path(directory)
    for module in ('Ui', 'Commons'):
        (root / module).symlink_to(Path('/usr/share/omarchy/shell') / module, target_is_directory=True)
    (root / 'plugin').mkdir()
    (root / 'runtime').mkdir(mode=0o700)
    (root / 'home').mkdir()
    source = (PROJECT / 'Panel.qml').read_text()
    # Keep the actual panel content. Replace only its native layer-shell host
    # so it can render headlessly into an isolated Qt window.
    source = source.replace('    id: root\n', '''    id: root
    readonly property real previewHeight: content.implicitHeight
    readonly property real previewWidth: panel.contentWidth
    component PreviewPanel: Item {
        property var anchorItem
        property var owner
        property var bar
        property bool open
        property Item focusTarget
        property real contentWidth
        property real contentHeight
        width: contentWidth
        height: contentHeight
        function fittedContentWidth(value) { return value }
        function fittedContentHeight(value, maximum) { return value }
    }
''', 1)
    source = source.replace('    KeyboardPanel {', '    PreviewPanel {', 1)
    source = source.replace('if (!listing.running) listing.running = true', 'return // Preview mode never launches a backend')
    source = source.replace('        id: button\n', '        id: button\n        visible: false\n', 1)
    (root / 'plugin/Panel.qml').write_text(source)
    (root / 'shell.qml').write_text((PROJECT / 'tools/preview.qml').read_text())
    env = os.environ.copy()
    env.update({
        'QT_QPA_PLATFORM': 'offscreen',
        'QT_QPA_PLATFORMTHEME': '',
        'QT_QUICK_BACKEND': 'software',
        'HOME': str(root / 'home'),
        'XDG_CONFIG_HOME': str(root / 'home/config'),
        'XDG_RUNTIME_DIR': str(root / 'runtime'),
        'TZ': 'UTC',
    })
    for name, destination in PREVIEWS:
        destination.parent.mkdir(parents=True, exist_ok=True)
        env['DDEV_PREVIEW_SCENE'] = name
        env['DDEV_PREVIEW_OUTPUT'] = str(destination)
        result = subprocess.run(['quickshell', '-p', str(root / 'shell.qml')], env=env,
                                capture_output=True, text=True, timeout=20)
        output = result.stdout + result.stderr
        if result.returncode or 'PREVIEW_SAVED' not in output or 'WARN scene:' in output:
            raise SystemExit(output)
        print('Rendered', destination.relative_to(PROJECT))

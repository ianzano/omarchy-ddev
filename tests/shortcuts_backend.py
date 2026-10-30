import json
from pathlib import Path
import sys
import time

action = sys.argv[1]
project = sys.argv[2] if len(sys.argv) > 2 else ""
extra = sys.argv[3:]
statefile = Path(__file__).with_name('fixture-state.json')
state = json.loads(statefile.read_text()) if statefile.exists() else {'commands': [], 'snapshots': [{'name': 'before.sql.gz', 'path': '/example/demo/.ddev/db_snapshots/before.sql.gz', 'size': 1024, 'modified': 1700000000}]}
result = {'ok': True}
if action == 'list':
    result['projects'] = [{'name': name, 'approot': '/example/' + name, 'status': 'running' if name == 'demo' else 'stopped', 'type': 'php'} for name in ('demo', 'stopped')]
elif action == 'commands':
    result['commands'] = state['commands']
elif action == 'save-command':
    item = json.loads(extra[0])
    if not item.get('id'):
        item['id'] = 'shortcut-demo'
        state['commands'].append(item)
    else:
        state['commands'] = [item if c['id'] == item['id'] else c for c in state['commands']]
    result['commands'] = state['commands']
elif action == 'delete-command':
    state['commands'] = []
    result['commands'] = []
elif action == 'custom-command':
    print(json.dumps({'event': 'output', 'text': 'Example shortcut output\n'}), flush=True)
    time.sleep(0.3)
    result['message'] = 'Example shortcut completed'
elif action == 'snapshots':
    result['snapshots'] = state['snapshots']
elif action == 'delete-snapshot':
    state['snapshots'] = []
    result['snapshots'] = []
    result['message'] = 'Snapshot deleted'
else:
    result['message'] = 'Example action completed'
if action in ('save-command', 'delete-command', 'delete-snapshot'):
    statefile.write_text(json.dumps(state))
print(json.dumps(result), flush=True)

import json
from pathlib import Path
import sys
import time
statefile = Path(__file__).with_name('status-race-state.json')
state = json.loads(statefile.read_text()) if statefile.exists() else {'status': 'running', 'lists': 0}
action = sys.argv[1]
if action == 'list':
    status = state['status']
    state['lists'] += 1
    statefile.write_text(json.dumps(state))
    if state['lists'] > 1:
        time.sleep(1.2)
    result = {'ok': True, 'projects': [{'name': 'demo', 'approot': '/example/demo', 'status': status, 'type': 'php'}]}
elif action == 'stop':
    time.sleep(0.2)
    state = json.loads(statefile.read_text())
    state['status'] = 'stopped'
    statefile.write_text(json.dumps(state))
    result = {'ok': True, 'message': 'Stopped'}
else:
    result = {'ok': True}
print(json.dumps(result), flush=True)

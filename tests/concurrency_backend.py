import json
import sys
import time
act = sys.argv[1]
name = sys.argv[2] if len(sys.argv) > 2 else ''
if act == 'list':
    print(json.dumps({'ok': True, 'projects': [{'name': n, 'approot': '/tmp/' + n, 'status': 'stopped' if n == 'stopped' else 'running', 'type': 'php'} for n in ('demo', 'other', 'spare', 'stopped')]}), flush=True)
else:
    print(json.dumps({'event': 'output', 'text': name + ' ' + act + ' first\n'}), flush=True)
    time.sleep(1.6 if name == 'demo' else 0.8)
    print(json.dumps({'event': 'output', 'text': name + ' ' + act + ' last\n'}), flush=True)
    print(json.dumps({'ok': name != 'other', 'message': name + (' failed deliberately' if name == 'other' else ' completed')}), flush=True)

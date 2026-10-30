import json
import sys
import time

action = sys.argv[1]
if action == 'list':
    result = {'ok': True, 'projects': [{'name': 'demo', 'approot': '/example/demo', 'status': 'running', 'type': 'php'}]}
elif action == 'logs':
    time.sleep(0.15)
    result = {'ok': True, 'logs': '2026-01-01T12:00:00Z Example request accepted\n2026-01-01T12:00:01Z Example response sent\n'}
else:
    time.sleep(0.5)
    result = {'ok': True, 'message': 'Example ' + action + ' completed'}
print(json.dumps(result), flush=True)

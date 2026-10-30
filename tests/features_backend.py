import json
import sys
import time

action = sys.argv[1]
if action == 'list':
    result = {'ok': True, 'projects': [{'name': n, 'approot': '/example/' + n, 'status': 'running' if n == 'demo' else 'stopped', 'type': 'php'} for n in ('demo', 'stopped')]}
elif action == 'snapshots':
    result = {'ok': True, 'snapshots': [{'name': 'example.sql.gz', 'path': 'example.sql.gz', 'size': 1024, 'modified': 1700000000}]}
elif action == 'domains':
    result = {'ok': True, 'domains': [{'url': 'https://demo.example.test', 'host': 'demo.example.test', 'primary': True}, {'url': 'https://admin.example.test', 'host': 'admin.example.test', 'primary': False}]}
elif action == 'logs-follow':
    for service, text in [('web', 'Example request accepted'), ('db', 'Example response sent')]:
        print(json.dumps({'event': 'log', 'text': '[' + service + '] 2026-01-01T12:00:00Z ' + text + '\n'}), flush=True)
    time.sleep(60)
    result = {'ok': True}
elif action == 'logs':
    result = {'ok': True, 'logs': '[web] 2026-01-01T12:00:00Z Example request accepted\n[db] 2026-01-01T12:00:01Z Example response sent\n'}
else:
    time.sleep(0.5)
    result = {'ok': True, 'message': 'Example ' + action + ' completed'}
print(json.dumps(result), flush=True)

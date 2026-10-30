#!/usr/bin/env python3
"""Small JSON bridge to DDEV. Commands use argv arrays, never a shell."""
import json
import codecs
from functools import lru_cache
import stat
import selectors
import signal
import time
import os
from pathlib import Path
import re
import subprocess
import sys


@lru_cache(maxsize=1)
def child_environment():
    """Preserve the desktop environment, filling gaps from the user's manager.

    GUI sessions need not load .zshrc; DDEV's compose files still need the
    user's SSH_AUTH_SOCK and other exported session variables.
    """
    env = os.environ.copy()
    try:
        manager = subprocess.run(
            ['systemctl', '--user', 'show-environment', '--output=json'],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL, timeout=2)
        if manager.returncode == 0:
            values = json.loads(manager.stdout)
            if isinstance(values, dict):
                for key, value in values.items():
                    if isinstance(key, str) and isinstance(value, str):
                        env.setdefault(key, value)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    if not env.get('SSH_AUTH_SOCK'):
        # Omarchy's user ssh-agent service uses this stable socket path.
        runtime = Path(env.get('XDG_RUNTIME_DIR') or f'/run/user/{os.getuid()}')
        candidate = runtime / 'ssh-agent.socket'
        try:
            info = candidate.stat()
            if stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid():
                env['SSH_AUTH_SOCK'] = str(candidate)
        except OSError:
            pass
    return env


def run(argv, cwd=None, timeout=30, stream=False, merged=False):
    if not stream:
        return subprocess.run(argv, cwd=cwd, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT if merged else subprocess.PIPE, timeout=timeout, stdin=subprocess.DEVNULL, env=child_environment())
    # A line is not always complete: DDEV also emits progress with carriage returns.
    proc = subprocess.Popen(argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            stdin=subprocess.DEVNULL, env=child_environment())
    output = ''
    decoder = codecs.getincrementaldecoder('utf-8')(errors='replace')
    deadline = time.monotonic() + timeout
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(proc.stdout, selectors.EVENT_READ)
            while selector.get_map():
                if time.monotonic() >= deadline:
                    raise subprocess.TimeoutExpired(argv, timeout)
                for key, _ in selector.select(timeout=0.2):
                    chunk = os.read(key.fileobj.fileno(), 4096)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    text = decoder.decode(chunk)
                    output = (output + text)[-24000:]
                    print(json.dumps({'event': 'output', 'text': text}), flush=True)
        tail = decoder.decode(b'', final=True)
        if tail:
            output = (output + tail)[-24000:]
            print(json.dumps({'event': 'output', 'text': tail}), flush=True)
        return subprocess.CompletedProcess(argv, proc.wait(timeout=max(0.1, deadline - time.monotonic())), output, '')
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        proc.stdout.close()


def records(output):
    result = []
    for line in output.splitlines():
        try:
            result.append(json.loads(line))
        except ValueError:
            pass
    return result


def projects():
    proc = run(['ddev', 'list', '-j'])
    rows = records(proc.stdout)
    for row in rows:
        if isinstance(row.get('raw'), list):
            return [p for p in row['raw'] if p.get('approot') and p.get('name')]
    raise RuntimeError(proc.stderr.strip() or '\n'.join(r.get('msg', '') for r in rows) or 'DDEV returned no project data')


def snapshots(project):
    folder = Path(project['approot']) / '.ddev' / 'db_snapshots'
    if not folder.is_dir():
        return []
    entries = []
    for path in folder.iterdir():
        if path.is_file() and path.name.endswith(('.gz', '.zst', '.mbstream', '.xbstream')):
            stat = path.stat()
            entries.append({'name': path.name, 'path': str(path.resolve()), 'size': stat.st_size,
                            'modified': stat.st_mtime})
    return sorted(entries, key=lambda s: s['modified'], reverse=True)


# Inspect only fields needed by the UI; never read container environment values.
CONTAINER_FORMAT = (
    '{"id":{{json .Id}},"name":{{json .Name}},'
    '"project":{{json (index .Config.Labels "com.ddev.site-name")}},'
    '"service":{{json (index .Config.Labels "com.docker.compose.service")}},'
    '"state":{{json .State.Status}},"paused":{{json .State.Paused}},'
    '"health":{{if .State.Health}}{{json .State.Health.Status}}{{else}}""{{end}}}'
)


def containers(entries, include_stats=False):
    """Discover only containers labelled for registered DDEV applications."""
    proc = run(['docker', 'ps', '--all', '--quiet', '--no-trunc',
                '--filter', 'label=com.ddev.site-name'], timeout=15)
    if proc.returncode:
        raise RuntimeError(proc.stderr.strip() or 'Docker container discovery failed')
    ids = [item for item in proc.stdout.splitlines() if re.fullmatch(r'[a-f0-9]{12,64}', item)]
    if not ids:
        return [], ''
    proc = run(['docker', 'inspect', '--type', 'container', '--format', CONTAINER_FORMAT, *ids], timeout=15)
    # A container may disappear between discovery and inspect. Keep valid rows.
    rows = records(proc.stdout)
    if proc.returncode and not rows:
        raise RuntimeError(proc.stderr.strip() or 'Docker container inspection failed')
    names = {entry['name'] for entry in entries}
    result = []
    for row in rows:
        if row.get('project') not in names or row.get('id') not in ids:
            continue
        row['name'] = str(row.get('name', '')).lstrip('/')
        row['service'] = row.get('service') or row['name']
        row['state'] = 'paused' if row.get('paused') else row.get('state', 'unknown')
        row['stats'] = None
        result.append(row)
    stats_warning = ''
    active = [row['id'] for row in result if row['state'] == 'running']
    if include_stats and active:
        proc = run(['docker', 'stats', '--no-stream', '--no-trunc', '--format', '{{json .}}', *active], timeout=15)
        metrics = {row.get('ID'): row for row in records(proc.stdout)}
        for row in result:
            metric = metrics.get(row['id'])
            if metric:
                row['stats'] = {
                    'cpu': metric.get('CPUPerc', '—'),
                    'memory': metric.get('MemUsage', '—'),
                    'memoryPercent': metric.get('MemPerc', '—'),
                    'network': metric.get('NetIO', '—'),
                    'disk': metric.get('BlockIO', '—'),
                    'pids': metric.get('PIDs', '—'),
                }
        if proc.returncode:
            stats_warning = proc.stderr.strip() or 'Live statistics are temporarily unavailable'
    return sorted(result, key=lambda row: (row['project'], row['service'])), stats_warning


def selected_container(entries, project, container_id):
    if not re.fullmatch(r'[a-f0-9]{12,64}', container_id):
        raise ValueError('Choose a container from this project')
    inventory, _ = containers(entries)
    container = next((item for item in inventory
                      if item['project'] == project and item['id'] == container_id), None)
    if not container:
        raise ValueError('Container is no longer part of this registered DDEV project; refresh the list')
    return container


def container_event(event):
    """Reduce Docker events to project/service state, without exporting labels."""
    if event.get('Type', 'container') != 'container':
        return None
    actor = event.get('Actor') or {}
    attrs = actor.get('Attributes') or {}
    project = attrs.get('com.ddev.site-name')
    action = event.get('Action') or event.get('status', '')
    if not project or action not in ('start', 'die', 'health_status: healthy', 'health_status: unhealthy'):
        return None
    return {'project': project, 'service': attrs.get('com.docker.compose.service') or attrs.get('name', 'container'),
            'id': actor.get('ID') or event.get('id', ''), 'action': action}


def watch_events():
    command = ['docker', 'events', '--filter', 'type=container', '--filter', 'label=com.ddev.site-name',
               '--filter', 'event=start', '--filter', 'event=die', '--filter', 'event=health_status',
               '--format', '{{json .}}']
    proc = subprocess.Popen(command, text=True, stdout=subprocess.PIPE, stderr=sys.stderr,
                            stdin=subprocess.DEVNULL, env=child_environment())
    def shutdown(signum, frame):
        if proc.poll() is None:
            proc.terminate()
        raise SystemExit(0)
    previous_handlers = {signum: signal.signal(signum, shutdown) for signum in (signal.SIGTERM, signal.SIGINT)}
    try:
        for line in proc.stdout:
            try:
                event = container_event(json.loads(line))
                if event:
                    print(json.dumps({'event': 'container', **event}), flush=True)
            except (TypeError, ValueError):
                continue
        if proc.wait():
            raise RuntimeError('Docker event monitoring disconnected; reconnecting automatically')
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait()
        proc.stdout.close()
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


def main(args):
    action = args[0] if args else 'list'
    if action == 'poweroff':
        proc = run(['ddev', 'poweroff'], timeout=1800, stream=True)
        output = (proc.stdout + '\n' + proc.stderr).strip()
        return {'ok': proc.returncode == 0, 'message': output[-24000:] or ('Done' if proc.returncode == 0 else 'Command failed')}
    if action == 'watch':
        watch_events()
        return {'ok': True}
    entries = projects()
    if action == 'monitor':
        inventory, warning = containers(entries, include_stats=len(args) > 1 and args[1] == 'stats')
        return {'ok': True, 'containers': inventory, 'warning': warning}
    if action == 'list':
        docker = run(['docker', 'info', '--format', '{{.ServerVersion}}'], timeout=10)
        warning = ''
        if docker.returncode:
            warning = 'Docker is unavailable; project runtime status cannot be verified. ' + docker.stderr.strip()
        return {'ok': True, 'projects': [dict(p, status=p.get('status', 'unknown') if not warning else 'unknown') for p in entries], 'warning': warning}
    if len(args) < 2:
        raise ValueError('Choose a registered project')
    project = next((p for p in entries if p['name'] == args[1]), None)
    if not project:
        raise ValueError('Project is no longer registered; refresh the list')
    if action == 'restart' and project.get('status') != 'running':
        raise ValueError('Restart is only available for running projects. Use Start first.')
    cwd = project['approot']
    if not (Path(cwd) / '.ddev' / 'config.yaml').is_file():
        raise ValueError('Project configuration is missing: ' + cwd)
    if action in ('logs', 'pause', 'resume'):
        if len(args) != 3:
            raise ValueError('Choose a container from this project')
        container = selected_container(entries, project['name'], args[2])
        if action == 'logs':
            proc = run(['docker', 'logs', '--tail', '200', '--timestamps', container['id']], timeout=15, merged=True)
            return {'ok': proc.returncode == 0, 'logs': ((proc.stdout or '') + (proc.stderr or ''))[-24000:],
                    'message': '' if proc.returncode == 0 else (proc.stderr or proc.stdout or '').strip() or 'Could not read container logs'}
        if action == 'pause' and container['state'] != 'running':
            raise ValueError('Only a running container can be paused')
        if action == 'resume' and container['state'] != 'paused':
            raise ValueError('Only a paused container can be resumed')
        command = 'pause' if action == 'pause' else 'unpause'
        proc = run(['docker', command, container['id']], timeout=30, stream=True)
        return {'ok': proc.returncode == 0, 'message': (proc.stdout + proc.stderr).strip() or 'Done'}
    if action == 'snapshots':
        return {'ok': True, 'snapshots': snapshots(project)}
    if action in ('browse', 'mailpit', 'folder'):
        target = cwd if action == 'folder' else project.get('primary_url') or project.get('httpsurl')
        if action == 'mailpit':
            target = project.get('mailpit_https_url') or project.get('mailpit_url')
        if not target or (action != 'folder' and not target.startswith(('https://', 'http://'))):
            raise ValueError('No valid URL is available')
        proc = run(['xdg-open', target], timeout=20)
    else:
        commands = {'start': ['ddev', 'start'], 'stop': ['ddev', 'stop'],
                    'restart': ['ddev', 'restart'], 'snapshot': ['ddev', 'snapshot']}
        if action == 'snapshot' and len(args) > 2 and args[2]:
            if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,100}', args[2]):
                raise ValueError('Use letters, numbers, dots, dashes or underscores for snapshot names')
            commands[action] += ['--name', args[2]]
        if action == 'restore':
            if len(args) != 3 or args[2] not in {s['path'] for s in snapshots(project)}:
                raise ValueError('Choose an existing snapshot from this project')
            commands[action] = ['ddev', 'snapshot', 'restore', args[2]]
        if action not in commands:
            raise ValueError('Unsupported action')
        proc = run(commands[action], cwd=cwd, timeout=1800, stream=True)
    output = (proc.stdout + '\n' + proc.stderr).strip()
    return {'ok': proc.returncode == 0, 'message': output[-24000:] or ('Done' if proc.returncode == 0 else 'Command failed')}


if __name__ == '__main__':
    try:
        result = main(sys.argv[1:])
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
        result = {'ok': False, 'message': str(exc)}
    print(json.dumps(result), flush=True)

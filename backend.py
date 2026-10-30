#!/usr/bin/env python3
"""Small JSON bridge to DDEV. Commands use argv arrays, never a shell."""
import json
import ipaddress
from urllib.parse import urlsplit
from concurrent.futures import ThreadPoolExecutor
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


def log_services(entries, project):
    inventory, _ = containers(entries)
    return sorted({item['service'] for item in inventory if item['project'] == project
                   and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', item['service'])})


def log_command(service, follow=False):
    return ['ddev', 'logs', '--service=' + service, '--tail=200', '--time'] + (['--follow'] if follow else [])


def project_logs(entries, project):
    services = log_services(entries, project['name'])
    if not services:
        return {'ok': True, 'logs': '', 'message': 'No project containers are available yet.'}
    def read(service):
        proc = run(log_command(service), cwd=project['approot'], timeout=20, merged=True)
        output = (proc.stdout or '') + (proc.stderr or '')
        return service, proc.returncode, output
    lines = []
    failures = []
    with ThreadPoolExecutor(max_workers=min(len(services), 8)) as pool:
        for service, code, output in pool.map(read, services):
            if code:
                failures.append(service)
            for line in output.splitlines():
                # Docker timestamps sort lexically; keep the service visible.
                timestamp = line.split(' ', 1)[0] if re.match(r'^\d{4}-\d\d-\d\dT', line) else ''
                lines.append((timestamp, '[' + service + '] ' + line))
    lines.sort(key=lambda row: row[0])
    return {'ok': len(failures) < len(services), 'logs': '\n'.join(line for _, line in lines[-200:])[-24000:],
            'message': 'Could not read logs from: ' + ', '.join(failures) if failures else ''}


def follow_project_logs(entries, project):
    services = log_services(entries, project['name'])
    if not services:
        return {'ok': True, 'logs': '', 'message': 'No project containers are available yet.'}
    followers = []
    previous_handlers = {}
    def shutdown(signum, frame):
        raise SystemExit(0)
    try:
        previous_handlers = {signum: signal.signal(signum, shutdown) for signum in (signal.SIGTERM, signal.SIGINT)}
        with selectors.DefaultSelector() as selector:
            for service in services:
                proc = subprocess.Popen(log_command(service, follow=True), cwd=project['approot'],
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                        stdin=subprocess.DEVNULL, env=child_environment(), start_new_session=True)
                follower = {'process': proc, 'service': service, 'decoder': codecs.getincrementaldecoder('utf-8')(errors='replace'), 'pending': ''}
                followers.append(follower)
                selector.register(proc.stdout, selectors.EVENT_READ, follower)
            while selector.get_map():
                for key, _ in selector.select(timeout=0.5):
                    follower = key.data
                    chunk = os.read(key.fileobj.fileno(), 4096)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        follower['pending'] += follower['decoder'].decode(b'', final=True)
                        if follower['pending']:
                            print(json.dumps({'event': 'log', 'text': '[' + follower['service'] + '] ' + follower['pending'] + '\n'}), flush=True)
                        continue
                    follower['pending'] += follower['decoder'].decode(chunk)
                    while '\n' in follower['pending']:
                        line, follower['pending'] = follower['pending'].split('\n', 1)
                        print(json.dumps({'event': 'log', 'text': '[' + follower['service'] + '] ' + line + '\n'}), flush=True)
                    # A malformed service must not grow an unbounded partial line.
                    if len(follower['pending']) > 4096:
                        print(json.dumps({'event': 'log', 'text': '[' + follower['service'] + '] ' + follower['pending'] + '\n'}), flush=True)
                        follower['pending'] = ''
        return {'ok': True, 'message': 'Project log stream ended; reconnecting when live viewing is enabled.'}
    finally:
        for follower in followers:
            proc = follower['process']
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait()
            proc.stdout.close()
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


def project_domains(project):
    proc = run(['ddev', 'describe', project['name'], '-j'], cwd=project['approot'], timeout=20)
    descriptions = [row['raw'] for row in records(proc.stdout) if isinstance(row.get('raw'), dict)]
    if not descriptions:
        raise RuntimeError(proc.stderr.strip() or 'DDEV could not describe this project; start it and refresh domains')
    description = descriptions[-1]
    primary = description.get('primary_url') or project.get('primary_url') or ''
    candidates = []
    if primary:
        candidates.append(primary)
    for field in ('httpsURLs', 'httpURLs'):
        values = description.get(field)
        if isinstance(values, list):
            candidates.extend(values)
    if len(candidates) <= 1 and isinstance(description.get('urls'), list):
        candidates.extend(description['urls'])
    candidates.extend([description.get('httpsurl'), description.get('httpurl')])
    valid = []
    for value in candidates:
        if not isinstance(value, str) or any(ord(char) < 32 for char in value):
            continue
        try:
            parsed = urlsplit(value)
            host = parsed.hostname
            if parsed.scheme not in ('http', 'https') or not host or '*' in host or parsed.username is not None or parsed.password is not None:
                continue
            parsed.port  # Validate malformed ports before handing a URL to the desktop.
            try:
                loopback = ipaddress.ip_address(host).is_loopback
            except ValueError:
                loopback = host.lower() == 'localhost'
            valid.append({'url': value, 'host': host, 'primary': value == primary, 'loopback': loopback, 'secure': parsed.scheme == 'https'})
        except ValueError:
            continue
    if any(not entry['loopback'] for entry in valid):
        valid = [entry for entry in valid if not entry['loopback'] or entry['primary']]
    valid.sort(key=lambda entry: (not entry['primary'], not entry['secure']))
    result = []
    seen = set()
    for entry in valid:
        host = entry['host'].lower()
        if host in seen:
            continue
        seen.add(host)
        result.append({key: entry[key] for key in ('url', 'host', 'primary')})
    return result


def browse_domains(project, selected=None, all_domains=False):
    domains = project_domains(project)
    if selected is not None:
        domains = [entry for entry in domains if entry['url'] == selected]
        if not domains:
            raise ValueError('Choose a URL reported by DDEV for this project')
    elif not all_domains:
        domains = domains[:1]
    if not domains:
        raise ValueError('DDEV has no concrete HTTP/HTTPS domains to open for this project')
    failed = []
    for entry in domains:
        proc = run(['xdg-open', entry['url']], timeout=20)
        if proc.returncode:
            failed.append(entry['host'])
    return {'ok': not failed, 'message': 'Could not open: ' + ', '.join(failed) if failed else 'Opened ' + str(len(domains)) + ' project domain' + ('s' if len(domains) != 1 else '')}


def main(args):
    action = args[0] if args else 'list'
    if action not in {'list', 'monitor', 'watch', 'poweroff', 'logs', 'logs-follow', 'domains', 'browse', 'browse-all', 'snapshots', 'snapshot', 'restore', 'mailpit', 'folder', 'start', 'stop', 'restart'}:
        raise ValueError('Unsupported action')
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
    if action in ('logs', 'logs-follow'):
        if len(args) != 2:
            raise ValueError('Project logs do not take a container ID')
        return follow_project_logs(entries, project) if action == 'logs-follow' else project_logs(entries, project)
    if action == 'domains':
        return {'ok': True, 'domains': project_domains(project)}
    if action in ('browse', 'browse-all'):
        return browse_domains(project, selected=args[2] if len(args) > 2 else None, all_domains=action == 'browse-all')
    if action == 'snapshots':
        return {'ok': True, 'snapshots': snapshots(project)}
    if action in ('mailpit', 'folder'):
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

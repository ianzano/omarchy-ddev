#!/usr/bin/env python3
"""Small JSON bridge to DDEV. Commands use argv arrays, never a shell."""
import json
import codecs
from functools import lru_cache
import stat
import selectors
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


def run(argv, cwd=None, timeout=30, stream=False):
    if not stream:
        return subprocess.run(argv, cwd=cwd, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=timeout, stdin=subprocess.DEVNULL, env=child_environment())
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


def main(args):
    action = args[0] if args else 'list'
    if action == 'poweroff':
        proc = run(['ddev', 'poweroff'], timeout=1800, stream=True)
        output = (proc.stdout + '\n' + proc.stderr).strip()
        return {'ok': proc.returncode == 0, 'message': output[-24000:] or ('Done' if proc.returncode == 0 else 'Command failed')}
    entries = projects()
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

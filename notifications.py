#!/usr/bin/env python3
"""Send desktop alerts over D-Bus; receive all notification text on stdin."""
import html
import json
import sys


def send_alerts(alerts, connection=None):
    from gi.repository import Gio, GLib

    if not isinstance(alerts, list) or len(alerts) > 64:
        raise ValueError('Invalid alerts')
    messages = []
    for alert in alerts:
        if not isinstance(alert, dict):
            raise ValueError('Invalid alert')
        for key in ('title', 'project', 'kind', 'detail'):
            value = alert.get(key, '')
            if not isinstance(value, str) or len(value) > 4096 or '\x00' in value:
                raise ValueError('Invalid alert')
        body = alert.get('project', '') + (' · ' + alert['detail'] if alert.get('detail') else '')
        messages.append((alert.get('title', ''), html.escape(body, quote=False),
                         2 if alert.get('kind') == 'unhealthy' else 1))
    if not messages:
        return
    connection = connection or Gio.bus_get_sync(Gio.BusType.SESSION, None)
    for title, body, urgency in messages:
        connection.call_sync(
            'org.freedesktop.Notifications', '/org/freedesktop/Notifications',
            'org.freedesktop.Notifications', 'Notify',
            GLib.Variant('(susssasa{sv}i)', ('DDEV Projects', 0, '', title, body, [],
                                          {'urgency': GLib.Variant('y', urgency)}, -1)),
            GLib.VariantType.new('(u)'), Gio.DBusCallFlags.NONE, 3000, None)


def main(stream):
    try:
        # No argv, environment, files, or diagnostics carry the alert payload.
        payload = stream.read(1048577)
        if len(payload) > 1048576:
            raise ValueError('Payload too large')
        send_alerts(json.loads(payload))
    except Exception:
        # D-Bus errors can quote method arguments. Never print their contents.
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.stdin))

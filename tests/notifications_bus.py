"""Exercise the real sender against an isolated notification service."""
import json
from pathlib import Path
import subprocess
import sys
from gi.repository import Gio, GLib

XML = '''<node><interface name="org.freedesktop.Notifications"><method name="Notify">
<arg type="s" direction="in"/><arg type="u" direction="in"/>
<arg type="s" direction="in"/><arg type="s" direction="in"/>
<arg type="s" direction="in"/><arg type="as" direction="in"/>
<arg type="a{sv}" direction="in"/><arg type="i" direction="in"/>
<arg type="u" direction="out"/></method></interface></node>'''
connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
connection.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName', GLib.Variant('(su)', ('org.freedesktop.Notifications', 0)), None, Gio.DBusCallFlags.NONE, 1000, None)
received = []

def notify(conn, sender, path, interface, method, params, invocation):
    received.append(params.unpack())
    # The helper is blocked awaiting this reply: its command line is observable.
    cmdline = Path('/proc/' + str(helper.pid) + '/cmdline').read_bytes()
    assert b'private-project' not in cmdline and b'private-service' not in cmdline
    assert b'notify-send' not in cmdline
    invocation.return_value(GLib.Variant('(u)', (1,)))

connection.register_object('/org/freedesktop/Notifications', Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], notify, None, None)
helper = subprocess.Popen([sys.executable, str(Path(__file__).resolve().parents[1] / 'notifications.py')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
helper.stdin.write(json.dumps([{'project': 'private-project-雪', 'detail': 'private-service', 'title': 'Project unhealthy', 'kind': 'unhealthy'}]))
helper.stdin.close()
loop = GLib.MainLoop()

def check_done():
    if helper.poll() is None:
        return True
    loop.quit()
    return False

GLib.timeout_add(20, check_done)
GLib.timeout_add_seconds(8, lambda: (helper.kill(), loop.quit(), False)[-1])
loop.run()
assert helper.wait(timeout=2) == 0
assert helper.stdout.read() == '' and helper.stderr.read() == ''
assert len(received) == 1 and received[0][4] == 'private-project-雪 · private-service'
assert received[0][6]['urgency'] == 2
print('NOTIFICATION_BUS_CHECKS_PASSED')

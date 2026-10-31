import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch
import notifications


class NotificationTests(unittest.TestCase):
    def alert(self, **changes):
        return dict({'title': 'DDEV project unhealthy', 'project': 'private-demo',
                     'detail': 'web, db', 'kind': 'unhealthy'}, **changes)

    def test_direct_dbus_preserves_details_and_urgency(self):
        connection = Mock()
        notifications.send_alerts([self.alert(), self.alert(kind='started', project='demo <&>')], connection)
        self.assertEqual(connection.call_count, 0)
        calls = connection.call_sync.call_args_list
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0].args[:4], ('org.freedesktop.Notifications', '/org/freedesktop/Notifications', 'org.freedesktop.Notifications', 'Notify'))
        params = calls[0].args[4].unpack()
        self.assertEqual(params[:6], ('DDEV Projects', 0, '', 'DDEV project unhealthy', 'private-demo · web, db', []))
        self.assertEqual(params[6]['urgency'], 2)
        self.assertEqual(calls[1].args[4].unpack()[4], 'demo &lt;&amp;&gt; · web, db')
        self.assertEqual(calls[1].args[4].unpack()[6]['urgency'], 1)

    def test_error_never_prints_private_details_or_uses_fallback(self):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(notifications, 'send_alerts', side_effect=RuntimeError('private-demo web db')), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), patch('subprocess.Popen') as spawn:
            self.assertEqual(notifications.main(io.StringIO(json.dumps([self.alert()]))), 1)
            spawn.assert_not_called()
        self.assertEqual(out.getvalue() + err.getvalue(), '')

    def test_invalid_payload_rejected_before_any_delivery(self):
        for data in ({}, [self.alert(detail=12)], [self.alert(project='bad\x00name')], [self.alert()] * 65):
            connection = Mock()
            with self.subTest(data=type(data).__name__), self.assertRaises(ValueError):
                notifications.send_alerts(data, connection)
            connection.call_sync.assert_not_called()

    def test_empty_batch_needs_no_bus(self):
        connection = Mock()
        notifications.send_alerts([], connection)
        connection.call_sync.assert_not_called()

    def test_private_bus_delivery_and_process_argument_privacy(self):
        result = subprocess.run(['dbus-run-session', '--', sys.executable,
                                 str(Path(__file__).parent / 'tests/notifications_bus.py')],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('NOTIFICATION_BUS_CHECKS_PASSED', result.stdout)

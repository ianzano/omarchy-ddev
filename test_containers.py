import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('container_backend', Path(__file__).parent / 'backend.py')
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)
CID = 'a' * 64
OTHER = 'b' * 64


def completed(stdout='', stderr='', code=0):
    return subprocess.CompletedProcess([], code, stdout, stderr)


def container(cid=CID, project='demo', state='running'):
    return {'id': cid, 'project': project, 'name': '/ddev-demo-web', 'service': 'web',
            'state': state, 'paused': state == 'paused', 'health': 'healthy'}


class InventoryTests(unittest.TestCase):
    def test_inventory_is_scoped_to_registered_projects(self):
        rows = [container(), container(OTHER, 'unregistered')]
        with patch.object(backend, 'run', side_effect=[completed(CID + '\n' + OTHER), completed('\n'.join(json.dumps(row) for row in rows))]) as run:
            result, warning = backend.containers([{'name': 'demo'}])
        self.assertEqual([row['id'] for row in result], [CID])
        self.assertEqual(result[0]['name'], 'ddev-demo-web')
        self.assertEqual(warning, '')
        self.assertIn('label=com.ddev.site-name', run.call_args_list[0].args[0])
        self.assertNotIn('.Config.Env', backend.CONTAINER_FORMAT)

    def test_statistics_only_query_running_scoped_containers(self):
        rows = [container(), container(OTHER, state='paused')]
        metrics = {'ID': CID, 'CPUPerc': '2.5%', 'MemUsage': '32MiB / 8GiB', 'MemPerc': '0.4%', 'NetIO': '1kB / 2kB', 'BlockIO': '0B / 1MB', 'PIDs': '12'}
        with patch.object(backend, 'run', side_effect=[completed(CID + '\n' + OTHER), completed('\n'.join(json.dumps(row) for row in rows)), completed(json.dumps(metrics))]) as run:
            result, warning = backend.containers([{'name': 'demo'}], include_stats=True)
        self.assertEqual(result[0]['stats']['cpu'], '2.5%')
        self.assertIsNone(result[1]['stats'])
        self.assertIn(CID, run.call_args.args[0])
        self.assertNotIn(OTHER, run.call_args.args[0])
        self.assertEqual(warning, '')

    def test_docker_unavailable_does_not_report_empty_success(self):
        with patch.object(backend, 'run', return_value=completed(stderr='Docker offline', code=1)):
            with self.assertRaisesRegex(RuntimeError, 'Docker offline'):
                backend.containers([{'name': 'demo'}])

    def test_stats_failure_preserves_container_inventory(self):
        with patch.object(backend, 'run', side_effect=[completed(CID), completed(json.dumps(container())), completed(stderr='stats unavailable', code=1)]):
            result, warning = backend.containers([{'name': 'demo'}], include_stats=True)
        self.assertEqual(len(result), 1)
        self.assertIsNone(result[0]['stats'])
        self.assertIn('stats unavailable', warning)

    def test_partial_inspect_race_preserves_remaining_containers(self):
        with patch.object(backend, 'run', side_effect=[completed(CID + '\n' + OTHER), completed(json.dumps(container()), stderr='container disappeared', code=1)]):
            result, _ = backend.containers([{'name': 'demo'}])
        self.assertEqual([row['id'] for row in result], [CID])


class ContainerActionsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        (root / '.ddev').mkdir()
        (root / '.ddev/config.yaml').write_text('name: demo\n')
        self.project = {'name': 'demo', 'approot': str(root)}
        project_patch = patch.object(backend, 'projects', return_value=[self.project])
        project_patch.start()
        self.addCleanup(project_patch.stop)

    def test_pause_validated_running_container(self):
        with patch.object(backend, 'containers', return_value=([container()], '')), patch.object(backend, 'run', return_value=completed('paused')) as run:
            self.assertTrue(backend.main(['pause', 'demo', CID])['ok'])
            self.assertEqual(run.call_args.args[0], ['docker', 'pause', CID])

    def test_resume_only_paused_container(self):
        with patch.object(backend, 'containers', return_value=([container(state='paused')], '')), patch.object(backend, 'run', return_value=completed('resumed')) as run:
            self.assertTrue(backend.main(['resume', 'demo', CID])['ok'])
            self.assertEqual(run.call_args.args[0], ['docker', 'unpause', CID])

    def test_wrong_project_container_is_rejected_without_mutation(self):
        with patch.object(backend, 'containers', return_value=([container(project='other')], '')), patch.object(backend, 'run') as run:
            for action in ('pause', 'resume', 'logs'):
                with self.assertRaises(ValueError):
                    backend.main([action, 'demo', CID])
            run.assert_not_called()

    def test_invalid_container_id_cannot_be_a_docker_flag(self):
        with patch.object(backend, 'run') as run:
            with self.assertRaises(ValueError):
                backend.main(['pause', 'demo', '--all'])
            run.assert_not_called()

    def test_invalid_pause_and_resume_states_are_rejected(self):
        for action, state in (('pause', 'paused'), ('pause', 'exited'), ('resume', 'running'), ('resume', 'exited')):
            with self.subTest(action=action, state=state), patch.object(backend, 'containers', return_value=([container(state=state)], '')), patch.object(backend, 'run') as run:
                with self.assertRaises(ValueError):
                    backend.main([action, 'demo', CID])
                run.assert_not_called()

    def test_logs_are_bounded_and_do_not_follow_forever(self):
        with patch.object(backend, 'containers', return_value=([container()], '')), patch.object(backend, 'run', return_value=completed('x' * 30000, None)) as run:
            result = backend.main(['logs', 'demo', CID])
        self.assertEqual(len(result['logs']), 24000)
        self.assertEqual(run.call_args.args[0], ['docker', 'logs', '--tail', '200', '--timestamps', CID])
        self.assertTrue(run.call_args.kwargs['merged'])


class EventTests(unittest.TestCase):
    def test_event_filters_and_reduces_labels(self):
        raw = {'Type': 'container', 'Action': 'health_status: unhealthy', 'Actor': {'ID': CID, 'Attributes': {'com.ddev.site-name': 'demo', 'com.docker.compose.service': 'web', 'private-label': 'not-for-ui'}}}
        event = backend.container_event(raw)
        self.assertEqual(event, {'project': 'demo', 'service': 'web', 'id': CID, 'action': 'health_status: unhealthy'})
        self.assertNotIn('private-label', json.dumps(event))

    def test_unrelated_events_are_ignored(self):
        for raw in ({'Type': 'network'}, {'Type': 'container', 'Action': 'start', 'Actor': {'Attributes': {}}}, {'Type': 'container', 'Action': 'exec_start', 'Actor': {'Attributes': {'com.ddev.site-name': 'demo'}}}):
            self.assertIsNone(backend.container_event(raw))


if __name__ == '__main__':
    unittest.main()

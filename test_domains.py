import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('domain_backend', Path(__file__).parent / 'backend.py')
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)


def description(raw):
    return subprocess.CompletedProcess([], 0, json.dumps({'raw': raw}), '')


class DomainTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        (root / '.ddev').mkdir()
        (root / '.ddev/config.yaml').write_text('name: demo\n')
        self.project = {'name': 'demo', 'approot': str(root), 'primary_url': 'https://demo.example.test', 'status': 'running'}
        self.raw = {'primary_url': 'https://demo.example.test',
                    'httpsURLs': ['https://demo.example.test', 'https://admin.example.test', 'https://127.0.0.1:45678'],
                    'httpURLs': ['http://demo.example.test', 'http://admin.example.test', 'http://127.0.0.1:45677'],
                    'mailpit_https_url': 'https://demo.example.test:8026'}
        project_patch = patch.object(backend, 'projects', return_value=[self.project])
        project_patch.start()
        self.addCleanup(project_patch.stop)

    def test_domains_are_deduplicated_and_prefer_https(self):
        with patch.object(backend, 'run', return_value=description(self.raw)):
            result = backend.main(['domains', 'demo'])
        self.assertEqual([entry['url'] for entry in result['domains']], ['https://demo.example.test', 'https://admin.example.test'])
        self.assertTrue(result['domains'][0]['primary'])

    def test_configured_http_primary_is_preserved(self):
        self.raw['primary_url'] = 'http://demo.example.test'
        with patch.object(backend, 'run', return_value=description(self.raw)):
            entries = backend.project_domains(self.project)
        self.assertEqual(entries[0]['url'], 'http://demo.example.test')
        self.assertTrue(entries[0]['primary'])

    def test_loopback_is_available_when_it_is_the_only_route(self):
        self.raw = {'primary_url': 'http://127.0.0.1:45678', 'httpURLs': ['http://127.0.0.1:45678']}
        with patch.object(backend, 'run', return_value=description(self.raw)):
            entries = backend.project_domains(self.project)
        self.assertEqual(entries[0]['url'], 'http://127.0.0.1:45678')

    def test_generic_url_field_is_supported(self):
        self.raw = {'primary_url': 'https://demo.example.test', 'urls': ['https://demo.example.test', 'https://admin.example.test', 'http://admin.example.test']}
        with patch.object(backend, 'run', return_value=description(self.raw)):
            entries = backend.project_domains(self.project)
        self.assertEqual(len(entries), 2)

    def test_unsafe_or_wildcard_urls_are_not_offered(self):
        self.raw['httpsURLs'] += ['file:///example/path', 'javascript:example()', 'https://*.example.test', 'https://account@private.example.test', 'https://demo.example.test:invalid', 'https://bad\n.example.test']
        with patch.object(backend, 'run', return_value=description(self.raw)):
            entries = backend.project_domains(self.project)
        self.assertEqual(len(entries), 2)

    def test_selected_domain_is_checked_against_ddev(self):
        with patch.object(backend, 'run', side_effect=[description(self.raw), subprocess.CompletedProcess([], 0, '', '')]) as run:
            result = backend.main(['browse', 'demo', 'https://admin.example.test'])
        self.assertTrue(result['ok'])
        self.assertEqual(run.call_args.args[0], ['xdg-open', 'https://admin.example.test'])

    def test_arbitrary_domain_cannot_be_opened(self):
        with patch.object(backend, 'run', return_value=description(self.raw)) as run:
            with self.assertRaises(ValueError):
                backend.main(['browse', 'demo', 'https://unrelated.example.test'])
        self.assertEqual(run.call_count, 1)

    def test_open_all_opens_each_domain_once(self):
        with patch.object(backend, 'run', side_effect=[description(self.raw), subprocess.CompletedProcess([], 0, '', ''), subprocess.CompletedProcess([], 0, '', '')]) as run:
            result = backend.main(['browse-all', 'demo'])
        self.assertTrue(result['ok'])
        self.assertEqual([call.args[0] for call in run.call_args_list[1:]], [['xdg-open', 'https://demo.example.test'], ['xdg-open', 'https://admin.example.test']])

    def test_open_all_reports_partial_failure(self):
        with patch.object(backend, 'run', side_effect=[description(self.raw), subprocess.CompletedProcess([], 1, '', 'failed'), subprocess.CompletedProcess([], 0, '', '')]):
            result = backend.main(['browse-all', 'demo'])
        self.assertFalse(result['ok'])
        self.assertIn('demo.example.test', result['message'])

    def test_describe_failure_does_not_open_anything(self):
        with patch.object(backend, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'Project unavailable')) as run:
            with self.assertRaises(RuntimeError):
                backend.main(['browse-all', 'demo'])
        self.assertEqual(run.call_count, 1)


if __name__ == '__main__':
    unittest.main()

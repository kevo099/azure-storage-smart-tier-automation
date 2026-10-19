#!/usr/bin/env python3
"""Exercise publisher byte preservation and terminal upload gates without Azure."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

FAKE_AZ = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['FAKE_PUBLISH_ROOT'])
args = sys.argv[1:]
case = os.environ['FAKE_PUBLISH_CASE']
def value(flag): return args[args.index(flag) + 1]
with (root / 'az-calls.jsonl').open('a') as f: f.write(json.dumps(args) + '\n')
if args[:2] == ['account', 'get-access-token']:
    print('fixture-token')
elif args[:1] == ['rest']:
    method, url = value('--method'), value('--url')
    if method == 'patch':
        assert (root / 'draft-read').exists(), 'runtime linked before draft byte check'
    elif url.split('?')[0].endswith('/draft/content'):
        data = (root / 'uploaded.ps1').read_bytes()
        if case == 'draft-corrupt': data = data[:-1]
        Path(value('--output-file')).write_bytes(data)
        (root / 'draft-read').touch()
    elif url.split('?')[0].endswith('/content'):
        assert (root / 'published').exists(), 'published content fetched too early'
        Path(value('--output-file')).write_bytes((root / 'uploaded.ps1').read_bytes())
    elif '--query' in args:
        query = value('--query')
        print({'location': 'centralus', 'properties.state': 'Published',
               'properties.runtimeEnvironment': 'PowerShell74-SmartTier'}[query])
elif args[:3] == ['automation', 'runbook', 'publish']:
    assert (root / 'draft-read').exists(), 'published before draft verification'
    (root / 'published').touch()
else:
    raise SystemExit('Unexpected az command: ' + repr(args))
'''

FAKE_CURL = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['FAKE_PUBLISH_ROOT'])
args = sys.argv[1:]
case = os.environ['FAKE_PUBLISH_CASE']
def value(flag): return args[args.index(flag) + 1]
assert not any('fixture-token' in arg for arg in args), 'token exposed in argv'
assert value('--config') == '-'
assert sys.stdin.read() == 'header = "Authorization: Bearer fixture-token"\n'
assert value('--proto') == '=https'
assert '--location' not in args, 'must not follow redirects with authority'
method, url = value('--request'), value('--url')
assert url.startswith('https://management.azure.com/'), 'foreign operation requested'
with (root / 'curl-calls.jsonl').open('a') as f: f.write(json.dumps(args) + '\n')
headers = ['HTTP/1.1 200 OK', 'Retry-After: 0']
body, status = b'', '200'
if method == 'PUT':
    assert '/draft/content?' in url
    assert value('--header') == 'Content-Type: text/plain; charset=utf-8'
    source = value('--data-binary')
    assert source.startswith('@')
    (root / 'uploaded.ps1').write_bytes(Path(source[1:]).read_bytes())
    if case == 'upload-denied': status = '403'
    elif case == 'synchronous': status = '200'
    else:
        status = '202'
        if case != 'missing-operation':
            location = ('https://other.example/operation' if case == 'foreign-operation'
                        else 'https://management.azure.com/test/operation')
            headers.append('Location: ' + location)
            if case in ('async', 'async-failed'):
                headers.append('Azure-AsyncOperation: https://management.azure.com/test/async')
else:
    poll_file = root / 'poll-count'
    count = int(poll_file.read_text()) + 1 if poll_file.exists() else 1
    poll_file.write_text(str(count))
    if case in ('async', 'async-failed'):
        assert url.endswith('/async'), 'Azure-AsyncOperation must take precedence'
        state = 'Failed' if case == 'async-failed' else ('InProgress' if count == 1 else 'Succeeded')
        body = json.dumps({'status': state}).encode()
    else:
        status = '202' if count == 1 else '204'
Path(value('--output')).write_bytes(body)
Path(value('--dump-header')).write_bytes(('\r\n'.join(headers) + '\r\n\r\n').encode())
print(status, end='')
'''


class PublisherTests(unittest.TestCase):
    def run_case(self, case: str, succeeds: bool, message: str = '') -> None:
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            fake_bin = work / 'bin'
            fake_bin.mkdir()
            for name, content in [('az', FAKE_AZ), ('curl', FAKE_CURL),
                                  ('sleep', '#!/bin/sh\nexit 0\n')]:
                tool = fake_bin / name
                tool.write_text(content)
                tool.chmod(0o700)
            # A non-ASCII string, CRLF, and two final LFs catch text/line-ending normalization.
            source_bytes = '# byte fixture: café\r\nWrite-Output "ok"\n\n'.encode()
            source = work / 'source.ps1'
            source.write_bytes(source_bytes)
            env = os.environ.copy()
            env.update(PATH=str(fake_bin) + os.pathsep + env['PATH'],
                       FAKE_PUBLISH_ROOT=str(work), FAKE_PUBLISH_CASE=case,
                       SUBSCRIPTION_ID='test-subscription', RESOURCE_GROUP='test-resource-group',
                       AUTOMATION_ACCOUNT='test-account', RUNBOOK_FILE=str(source), LOCATION='centralus')
            result = subprocess.run(['bash', str(ROOT / 'scripts/publish-runbook.sh')],
                                    env=env, text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)
            self.assertEqual((work / 'uploaded.ps1').read_bytes(), source_bytes)
            self.assertEqual((work / 'published').exists(), succeeds)
            if message:
                self.assertIn(message, result.stdout + result.stderr)
            if case in ('location', 'async'):
                self.assertEqual((work / 'poll-count').read_text(), '2')
            if case == 'foreign-operation':
                self.assertEqual(len((work / 'curl-calls.jsonl').read_text().splitlines()), 1)
            if succeeds:
                self.assertIn('OK: published bytes equal the local file', result.stdout)

    def test_exact_bytes_synchronous(self):
        self.run_case('synchronous', True)

    def test_location_waits_for_terminal_status(self):
        self.run_case('location', True)

    def test_async_operation_precedence_and_terminal_status(self):
        self.run_case('async', True)

    def test_foreign_operation_refused_before_authenticated_request(self):
        self.run_case('foreign-operation', False, 'untrusted draft-operation URL')

    def test_missing_operation_refuses_publish(self):
        self.run_case('missing-operation', False, '202 without an operation URL')

    def test_denied_upload_refuses_publish(self):
        self.run_case('upload-denied', False, 'HTTP 403')

    def test_failed_operation_refuses_publish(self):
        self.run_case('async-failed', False, 'operation Failed')

    def test_draft_byte_mismatch_refuses_publish(self):
        self.run_case('draft-corrupt', False, 'draft bytes differ')


if __name__ == '__main__':
    unittest.main()

"""Testa adoção/restauração de secrets sem credenciais ou chamadas AWS reais."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['FIXTURE'])
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'calls.jsonl').open('a') as f:
    f.write(json.dumps([tool, *args]) + '\n')
def after(flag):
    return args[args.index(flag) + 1]
if tool == 'terraform':
    assert args.pop(0) == '-chdir=foundation'
    if args[0] == 'console':
        assert 'var.name' in sys.stdin.read()
        print(json.dumps(json.dumps({'account_id': '123456789012', 'region': 'sa-east-1', 'name': 'custom'})))
    elif args == ['state', 'list']:
        if os.environ.get('STATE_ERROR'):
            print(os.environ['STATE_ERROR'], file=sys.stderr)
            sys.exit(1)
        print((root / 'state.txt').read_text(), end='')
    elif args == ['state', 'pull']:
        print('{"serial": 1}')
    elif args[0] == 'import':
        if os.environ.get('IMPORT_FAIL'):
            sys.exit(1)
        with (root / 'state.txt').open('a') as f:
            f.write(args[-2] + '\n')
    elif args[0] == 'plan':
        (root / 'planned').touch()
    else:
        raise AssertionError(args)
elif tool == 'aws':
    assert after('--region') == 'sa-east-1'
    if args[:2] == ['sts', 'get-caller-identity']:
        print(os.environ.get('ACCOUNT', '123456789012'))
    else:
        secrets = json.loads((root / 'secrets.json').read_text())
        name = after('--secret-id').split(':secret:')[-1].removesuffix('-ABC123')
        mode = secrets.get(name, 'missing')
        if args[1] == 'describe-secret':
            if mode in ('missing', 'denied', 'network'):
                error = {'missing': '(ResourceNotFoundException)', 'denied': '(AccessDeniedException)', 'network': 'Could not connect to endpoint'}[mode]
                print(error, file=sys.stderr)
                sys.exit(1)
            result = {'Name': name, 'ARN': 'arn:aws:secretsmanager:sa-east-1:123456789012:secret:' + name + '-ABC123'}
            if mode == 'deleted':
                result['DeletedDate'] = '2026-11-01T00:00:00Z'
            print(json.dumps(result))
        elif args[1] == 'restore-secret':
            if os.environ.get('RESTORE_FAIL'):
                sys.exit(1)
            secrets[name] = 'active'
            (root / 'secrets.json').write_text(json.dumps(secrets))
            print('{}')
        else:
            raise AssertionError(args)
'''


class FoundationSecrets(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='loto-secrets-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'foundation').mkdir()
        shutil.copy(ROOT / 'scripts/plan-foundation.sh', self.root / 'scripts')
        binary = self.root / 'bin'
        binary.mkdir()
        for name in ('aws', 'terraform'):
            path = binary / name
            path.write_text(FAKE)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{binary}:{os.environ["PATH"]}', FIXTURE=str(self.root))
        (self.root / 'state.txt').write_text('')

    def run_plan(self, secrets, **env):
        (self.root / 'secrets.json').write_text(json.dumps(secrets))
        return subprocess.run(['bash', 'scripts/plan-foundation.sh'], cwd=self.root,
                              env=dict(self.env, **env), capture_output=True, text=True)

    def calls(self, tool, operation):
        calls = [json.loads(line) for line in (self.root / 'calls.jsonl').read_text().splitlines()]
        return [call for call in calls if call[0] == tool and operation in call]

    def test_missing_secrets_are_left_for_terraform_creation(self):
        result = self.run_plan({})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls('aws', 'describe-secret')), 2)
        self.assertFalse(self.calls('terraform', 'import'))
        self.assertFalse(self.calls('aws', 'restore-secret'))
        self.assertTrue((self.root / 'planned').exists())

    def test_active_secret_is_imported_and_second_run_is_idempotent(self):
        secrets = {'custom/application': 'active'}
        result = self.run_plan(secrets)
        self.assertEqual(result.returncode, 0, result.stderr)
        imports = self.calls('terraform', 'import')
        self.assertEqual(imports[0][-2:], ['aws_secretsmanager_secret.application',
                         'arn:aws:secretsmanager:sa-east-1:123456789012:secret:custom/application-ABC123'])
        self.assertFalse(self.calls('aws', 'restore-secret'))
        result = self.run_plan(secrets)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls('terraform', 'import')), 1)

    def test_first_execution_without_state_can_import_existing_secret(self):
        result = self.run_plan({'custom/application': 'active'}, STATE_ERROR='No state file was found!')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls('terraform', 'import')), 1)
        self.assertTrue((self.root / 'planned').exists())

    def test_backend_error_stops_before_secret_lookup(self):
        result = self.run_plan({}, STATE_ERROR='Error loading state: AccessDenied')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls('aws', 'describe-secret'))
        self.assertFalse((self.root / 'planned').exists())

    def test_deleted_secrets_are_restored_then_imported_with_backup(self):
        (self.root / 'state.txt').write_text('aws_vpc.main\n')
        result = self.run_plan({'custom/application': 'deleted', 'custom/gmail-oauth-token': 'deleted'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls('aws', 'restore-secret')), 2)
        self.assertEqual(len(self.calls('terraform', 'import')), 2)
        backups = list((self.root / '.local').glob('*.tfstate'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(json.loads(backups[0].read_text()), {'serial': 1})
        self.assertTrue((self.root / 'planned').exists())

    def test_already_managed_secret_is_restored_without_reimport(self):
        (self.root / 'state.txt').write_text('aws_secretsmanager_secret.application\n')
        result = self.run_plan({'custom/application': 'deleted'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls('aws', 'restore-secret')), 1)
        self.assertFalse(self.calls('terraform', 'import'))

    def test_permission_and_network_errors_do_not_allow_plan(self):
        for mode in ('denied', 'network'):
            with self.subTest(mode=mode):
                result = self.run_plan({'custom/application': mode})
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / 'planned').exists())
                self.assertFalse(self.calls('terraform', 'import'))

    def test_restore_or_import_failure_stops_before_plan(self):
        for flag in ('RESTORE_FAIL', 'IMPORT_FAIL'):
            with self.subTest(flag=flag):
                result = self.run_plan({'custom/application': 'deleted'}, **{flag: '1'})
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / 'planned').exists())

    def test_wrong_account_stops_before_secret_calls(self):
        result = self.run_plan({}, ACCOUNT='999999999999')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls('aws', 'describe-secret'))
        self.assertFalse((self.root / 'planned').exists())

"""Integração dos scripts com CLIs simuladas; não acessa AWS, Docker ou repositórios reais."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
APPS = ['mail-sender-aws', 'gmail-reader-aws', 'whatsapp-notify', 'loto-bot', 'loto-scheduler-aws']
KEYS = ['mail', 'gmail', 'whatsapp', 'bot', 'scheduler']
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
name = pathlib.Path(sys.argv[0]).name
root = pathlib.Path(os.environ['FIXTURE'])
with (root / 'calls.jsonl').open('a') as f:
    f.write(json.dumps([name, *args]) + '\n')
def after(flag):
    return args[args.index(flag) + 1]
if name == 'aws':
    if args[:2] == ['sts', 'get-caller-identity']:
        print('123456789012')
    elif args[:2] == ['s3api', 'get-bucket-location']:
        print('None')
    elif args[:2] == ['cloudformation', 'describe-stacks']:
        key = 'scheduler' if 'scheduler' in after('--stack-name') else 'mail'
        params = {'MailTo': '****', 'RunBetState': 'ENABLED', 'CheckDrawsState': 'DISABLED', 'DynamoDbTableName': 'existing-table'} if key == 'scheduler' else ({'SesFrom': '****'} if after('--stack-name') == 'mail-sender-aws' else {})
        print(json.dumps({'Stacks': [{'StackStatus': 'UPDATE_COMPLETE', 'Parameters': [{'ParameterKey': k, 'ParameterValue': v} for k,v in params.items()]}]}))
    elif args[:2] == ['cloudformation', 'get-template']:
        print(json.dumps({'TemplateBody': {'Resources': {}}}))
    elif args[:2] == ['lambda', 'get-function-configuration']:
        print(json.dumps({'State': 'Active', 'LastUpdateStatus': 'Successful'}))
    elif args[:2] == ['dynamodb', 'describe-table']:
        print(json.dumps('ACTIVE'))
    elif args[:2] == ['scheduler', 'get-schedule']:
        print(json.dumps({'State': os.environ.get('REMOTE_STATE', 'DISABLED'), 'Timezone': 'America/Sao_Paulo'}))
elif name == 'terraform':
    if args[0] == '-chdir=foundation':
        print((root / 'foundation.json').read_text())
        sys.exit(0)
    state = root / 'state.txt'
    if args[:2] == ['state', 'list']:
        print(state.read_text() if state.exists() else '', end='')
    elif args[:2] == ['state', 'pull']:
        print('{}')
    elif args[0] == 'import':
        with state.open('a') as f:
            f.write(args[1] + '\n')
    elif args[:2] == ['output', '-json']:
        if args[2] == 'scheduler_states':
            print(json.dumps({'RunBetState': 'DISABLED', 'CheckDrawsState': 'DISABLED'}))
        else:
            print(json.dumps({'scheduler': {'FunctionName': 'scheduler', 'ScheduleGroupName': 'group', 'TableName': 'existing-table', 'RunBetScheduleName': 'run', 'CheckDrawsScheduleName': 'check'}}))
elif name == 'git':
    repo = pathlib.Path(after('-C'))
    if 'rev-parse' in args:
        print(str(repo.resolve()) if '--show-toplevel' in args else 'abc123')
    elif 'archive' in args:
        pathlib.Path(next(a.split('=', 1)[1] for a in args if a.startswith('--output='))).write_bytes(b'zip')
elif name == 'sam':
    if args[0] == 'build':
        directory = pathlib.Path(after('--build-dir'))
        (directory / 'SchedulerFunction').mkdir(parents=True, exist_ok=True)
        (directory / 'template.yaml').write_text('Resources: {}\n')
    elif args[0] == 'package':
        shutil = __import__('shutil')
        shutil.copy(after('--template-file'), after('--output-template-file'))
elif name == 'docker' and args[0] == 'run' and os.environ.get('FAIL_ARTIFACT'):
    sys.exit(9)
'''


class ScriptIntegration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='loto-scheduler-test-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.project = self.base / 'project'
        self.project.mkdir()
        shutil.copytree(ROOT / 'scripts', self.project / 'scripts')
        (self.project / 'prepared').mkdir()
        shutil.copytree(ROOT / 'examples', self.project / 'examples')
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        for name in ['aws', 'terraform', 'sam', 'docker', 'git']:
            path = self.bin / name
            path.write_text(FAKE)
            path.chmod(0o755)
        self.sources = self.base / 'sources'
        for app in APPS:
            repo = self.sources / app
            (repo / 'scripts').mkdir(parents=True)
            (repo / 'template.yaml').write_text('Resources: {}\n')
            (repo / 'scripts/check_artifact.py').write_text('')
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}', FIXTURE=str(self.base),
                        AWS_PROFILE='fixture', AWS_REGION='us-east-1', EXPECTED_ACCOUNT_ID='123456789012',
                        SES_FROM='sender@example.com', SCHEDULER_MAIL_TO='receiver@example.com',
                        SOURCE_ROOT=str(self.sources), ARTIFACT_BUCKET='fixture')
        self.config = json.loads((ROOT / 'examples/terraform.tfvars.json').read_text())

    def run_script(self, name, *args, success=True):
        result = subprocess.run(['bash', str(self.project / 'scripts' / name), *args], env=self.env,
                                text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def calls(self, tool):
        return [c[1:] for c in map(json.loads, (self.base / 'calls.jsonl').read_text().splitlines()) if c[0] == tool]

    def write_config(self):
        (self.project / 'terraform.tfvars.json').write_text(json.dumps(self.config))

    def write_foundation(self, **changes):
        foundation = {
            'account_id': '123456789012', 'region': 'us-east-1', 'name': 'fresh',
            'vpc_id': 'vpc-fresh', 'subnet_id': 'subnet-fresh', 'route_table_id': 'rtb-fresh',
            'integration_security_group_id': 'sg-integration', 'lambda_endpoint_sg_id': 'sg-endpoint',
            'artifact_bucket': 'fresh-artifacts', 'key_name': 'fresh-ssh',
            'ssh_ipv6_cidr': '2001:db8::1/128', 'ami_id': 'ami-fresh',
            'application_secret_arn': 'arn:aws:secretsmanager:us-east-1:123456789012:secret:application',
            'gmail_secret_arn': 'arn:aws:secretsmanager:us-east-1:123456789012:secret:gmail',
            'bets_table': 'fresh-bets', 'executions_table': 'fresh-executions',
            'ses_from': 'sender@example.com',
        }
        foundation.update(changes)
        (self.base / 'foundation.json').write_text(json.dumps(foundation))
        return foundation

    def test_configure_new_wires_foundation_and_keeps_jobs_disabled(self):
        f = self.write_foundation()
        self.run_script('configure-new.sh')
        config = json.loads((self.project / 'terraform.tfvars.json').read_text())
        self.assertEqual(config['parameters']['bot']['VpcId'], f['vpc_id'])
        self.assertEqual(config['parameters']['whatsapp']['KeyName'], f['key_name'])
        self.assertEqual(config['parameters']['gmail']['GmailOAuthSecretArn'], f['gmail_secret_arn'])
        self.assertEqual(config['parameters']['bot']['ApplicationSecretArn'], f['application_secret_arn'])
        self.assertEqual(config['parameters']['bot']['DynamoDbTableName'], f['bets_table'])
        scheduler = config['parameters']['scheduler']
        self.assertEqual(scheduler['LambdaEndpointSecurityGroupId'], f['lambda_endpoint_sg_id'])
        self.assertEqual(scheduler['DynamoDbTableName'], f['executions_table'])
        self.assertEqual(scheduler['MailTo'], self.env['SCHEDULER_MAIL_TO'])
        self.assertEqual(config['parameters']['bot']['UseLambdaVpcEndpoint'], 'false')
        self.assertEqual(scheduler['CreateDynamoGateway'], 'false')
        self.assertEqual(config['parameters']['bot']['ConfirmPayment'], 'false')
        self.assertEqual(scheduler['RunBetState'], 'DISABLED')
        self.assertEqual(scheduler['CheckDrawsState'], 'DISABLED')
        self.assertTrue(config['scheduler_paused'])
        self.assertTrue(json.loads((self.project / 'maintenance.auto.tfvars.json').read_text())['scheduler_paused'])
        self.assertNotIn('SUBSTITUA', json.dumps(config))
        self.assertEqual((self.project / 'terraform.tfvars.json').stat().st_mode & 0o777, 0o600)
        self.assertFalse(self.calls('aws'))
        self.assertEqual(self.calls('terraform'), [['-chdir=foundation', 'output', '-json', 'configuration']])

    def test_configure_new_refuses_existing_configuration(self):
        self.write_foundation()
        for name in ['terraform.tfvars.json', 'maintenance.auto.tfvars.json', 'releases.auto.tfvars.json']:
            path = self.project / name
            path.write_text('preserve')
            self.run_script('configure-new.sh', success=False)
            self.assertEqual(path.read_text(), 'preserve')
            path.unlink()

    def test_configure_new_refuses_wrong_account_region_or_incomplete_output(self):
        for changes in [{'account_id': '000000000000'}, {'region': 'sa-east-1'}, {'gmail_secret_arn': None}]:
            self.write_foundation(**changes)
            self.run_script('configure-new.sh', success=False)
            self.assertFalse((self.project / 'terraform.tfvars.json').exists())

    def test_adopts_all_five_and_recovers_noecho(self):
        self.run_script('adopt.sh')
        config = json.loads((self.project / 'terraform.tfvars.json').read_text())
        self.assertEqual(set(config['stack_names']), set(KEYS))
        self.assertEqual(config['parameters']['scheduler']['MailTo'], 'receiver@example.com')
        self.assertEqual(config['parameters']['scheduler']['RunBetState'], 'ENABLED')
        self.assertEqual(len([c for c in self.calls('terraform') if c[0] == 'import']), 5)

    def test_scheduler_only_preserves_existing_config_and_releases(self):
        for key in ['parameters', 'stack_names']:
            del self.config[key]['scheduler']
        self.write_config()
        (self.base / 'state.txt').write_text(''.join(f'aws_cloudformation_stack.{k}\n' for k in KEYS[:-1]))
        release = self.project / 'releases.auto.tfvars.json'
        release.write_text('{"artifact_parameters":{"bot":{"ArtifactKey":"old-release"}}}')
        self.run_script('adopt.sh', '--scheduler-only')
        config = json.loads((self.project / 'terraform.tfvars.json').read_text())
        self.assertEqual(config['parameters']['bot'], self.config['parameters']['bot'])
        self.assertIn('old-release', release.read_text())
        self.assertEqual([c for c in self.calls('terraform') if c[0] == 'import'],
                         [['import', 'aws_cloudformation_stack.scheduler', 'loto-scheduler-aws']])
        self.assertTrue((self.project / '.local/adoption/before-scheduler.tfstate.json').exists())

    def test_missing_noecho_value_stops_before_import(self):
        self.env.pop('SCHEDULER_MAIL_TO')
        self.run_script('adopt.sh', success=False)
        self.assertEqual(self.calls('terraform'), [])

    def test_prepare_checks_artifact_before_packaging_and_uses_runtime(self):
        self.config['parameters']['scheduler']['Runtime'] = 'python3.13'
        self.write_config()
        self.run_script('prepare.sh')
        builds = [c for c in self.calls('sam') if c[0] == 'build']
        self.assertEqual(len(builds), 3)
        self.assertIn('Runtime=python3.13', builds[-1])
        docker = [c for c in self.calls('docker') if c[0] == 'run'][0]
        self.assertIn('public.ecr.aws/sam/build-python3.13:latest', docker)
        calls = list(map(json.loads, (self.base / 'calls.jsonl').read_text().splitlines()))
        checked = next(i for i, c in enumerate(calls) if c[:2] == ['docker', 'run'])
        packaged = next(i for i, c in enumerate(calls)
                        if c[:2] == ['sam', 'package'] and 'loto-scheduler-aws' in ' '.join(c))
        self.assertLess(checked, packaged)
        validations = [c for c in self.calls('aws') if c[:2] == ['cloudformation', 'validate-template']]
        self.assertEqual(len(validations), 5)

    def test_bad_artifact_never_packages_scheduler(self):
        self.write_config()
        self.env['FAIL_ARTIFACT'] = '1'
        self.run_script('prepare.sh', success=False)
        packages = [c for c in self.calls('sam') if c[0] == 'package']
        self.assertFalse(any('loto-scheduler-aws' in ' '.join(c) for c in packages))
        self.assertFalse((self.project / 'releases.auto.tfvars.json').exists())

    def test_scheduler_checks_detect_unexpected_active_schedule(self):
        self.run_script('check-scheduler.sh')
        self.env['REMOTE_STATE'] = 'ENABLED'
        self.run_script('check-scheduler.sh', success=False)
        calls = self.calls('aws')
        self.assertFalse(any('invoke' in c or 'update-schedule' in c for c in calls))


if __name__ == '__main__':
    unittest.main()

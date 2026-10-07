"""Receipt guards plus an isolated dependency-free Cargo feature-union check.

No product Runtime, account store, SDK or device is accessed.
"""
from __future__ import annotations
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name('run-workspace-tests.py')
SPEC = importlib.util.spec_from_file_location('catalog_execution_guards', SCRIPT)
runner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runner
SPEC.loader.exec_module(runner)


class NativeCargoGroupTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('cargo'), 'dependency-free native fixture needs Cargo')
    def test_workspace_feature_union_and_exact_same_name_groups_are_real_cargo_receipts(self):
        with tempfile.TemporaryDirectory(prefix='arkdeck-catalog-group-') as temporary:
            root = Path(temporary).resolve()
            files = {
                'Cargo.toml': '[workspace]\nmembers=["a","b","shared"]\nresolver="2"\n',
                'a/Cargo.toml': '[package]\nname="member-a"\nversion="0.1.0"\nedition="2021"\n[dev-dependencies]\nshared={path="../shared"}\n',
                'a/src/lib.rs': '',
                'a/tests/same.rs': '#[test] fn alpha() { assert!(shared::union()); }\n#[test] fn gamma() { assert!(shared::union()); }\n',
                'b/Cargo.toml': '[package]\nname="member-b"\nversion="0.1.0"\nedition="2021"\n[dependencies]\nshared={path="../shared",features=["from-b"]}\n',
                'b/src/lib.rs': '',
                'b/tests/same.rs': '#[test] fn beta() { assert!(shared::union()); }\n',
                'shared/Cargo.toml': '[package]\nname="shared"\nversion="0.1.0"\nedition="2021"\n[features]\nfrom-b=[]\n',
                'shared/src/lib.rs': 'pub fn union() -> bool { cfg!(feature="from-b") }\n',
            }
            for name, data in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(data, encoding='utf-8')
            environment = {key: value for key, value in os.environ.items()
                           if not key.startswith(('ARKDECK_', 'OHOS_HDC_')) and key not in runner.CFG_ENVIRONMENT}
            environment.update(CARGO_TARGET_DIR=str(root / 'target'), CARGO_BUILD_JOBS='2', CARGO_TERM_COLOR='never')
            def cargo(arguments, expected=0):
                process = subprocess.run(['cargo', *arguments], cwd=root, env=environment,
                                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                         text=True, encoding='utf-8', timeout=120, check=False)
                self.assertEqual(process.returncode, expected, process.stdout)
                return process.stdout
            cargo(['generate-lockfile', '--offline'])
            # The rejected -p pattern genuinely loses this workspace's union.
            cargo(['test', '--locked', '--offline', '-p', 'member-a', '--test', 'same', '--', '--exact', 'alpha'], 101)
            metadata = json.loads(cargo(['metadata', '--no-deps', '--format-version', '1', '--locked', '--offline']))
            command = runner.BASE + ['--offline', '--test', 'same']
            built = cargo(command[1:] + ['--no-run', '--message-format=json'])
            messages = [json.loads(line) for line in built.splitlines() if line.startswith('{')]
            bindings = runner.artifact_bindings(messages, metadata)
            keys = ['member-a/same', 'member-b/same']
            sections = runner.running_sections(cargo(command[1:] + ['--', '--list']), keys, bindings, root)
            names = {key: runner.catalog_views.listed(body) for key, body in sections.items()}
            self.assertEqual(names, {'member-a/same': ['alpha', 'gamma'], 'member-b/same': ['beta']})
            filters = runner.group_filters(names, names)
            actual = runner.running_sections(cargo(command[1:] + ['--', '--exact', *filters]), keys, bindings, root)
            self.assertEqual([runner.catalog_views.verify_execution(actual[key], names[key])['passed']
                              for key in keys], [2, 1])


class CargoTargetReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='arkdeck-cargo-receipt-')
        self.addCleanup(self.temporary.cleanup)
        self.cwd = Path(self.temporary.name) / 'rust'
        self.cwd.mkdir()
        self.metadata = {'workspace_members': ['owner-a', 'owner-b'], 'packages': []}
        self.messages = []
        for package in ['a', 'b']:
            root = self.cwd / 'crates' / package
            root.mkdir(parents=True)
            target = {'kind': ['test'], 'name': 'same', 'test': True,
                      'src_path': str(root / 'tests' / 'same.rs')}
            self.metadata['packages'].append({'id': 'owner-' + package, 'name': package,
                                             'manifest_path': str(root / 'Cargo.toml'), 'targets': [target]})
            self.messages.append({'reason': 'compiler-artifact', 'package_id': 'owner-' + package,
                                  'target': target, 'executable': str(self.cwd / 'target' / (package + '-same.exe'))})
        self.messages.append({'reason': 'build-finished', 'success': True})
        self.bindings = runner.artifact_bindings(self.messages, self.metadata)

    def log(self, package, body='test exact_case ... ok\n'):
        return ('    Running tests/same.rs (' + self.bindings[package + '/same']['executable'] + ')\n' + body)

    def test_same_name_targets_require_their_own_built_executable_receipt(self):
        sections = runner.running_sections(self.log('a') + self.log('b', 'b_case: test\n'),
                                           ['a/same', 'b/same'], self.bindings, self.cwd)
        self.assertEqual(sections['a/same'].strip(), 'test exact_case ... ok')
        self.assertEqual(sections['b/same'].strip(), 'b_case: test')
        relative = os.path.relpath(self.bindings['a/same']['executable'], self.cwd)
        self.assertEqual(runner.running_sections('Running tests/same.rs (' + relative + ')\nreceipt\n',
                                                ['a/same'], self.bindings, self.cwd)['a/same'].strip(), 'receipt')

    def test_wrong_source_executable_duplicate_or_missing_running_refuses(self):
        for log in [self.log('a').replace('tests/same.rs', 'tests/other.rs'),
                    self.log('a').replace('a-same.exe', 'foreign.exe'),
                    self.log('b'), self.log('a') * 2, 'test exact_case ... ok\n']:
            with self.subTest(log=log), self.assertRaises(ValueError):
                runner.running_sections(log, ['a/same'], self.bindings, self.cwd)

    def test_compile_binding_requires_success_and_exact_declared_source(self):
        wrong = copy.deepcopy(self.messages)
        wrong[0]['target']['src_path'] += '.changed'
        duplicate = copy.deepcopy(self.messages)
        duplicate.insert(0, copy.deepcopy(duplicate[0]))
        for value in [wrong, duplicate, self.messages[:-1], self.messages[:-1] + [{'reason':'build-finished','success':False}]]:
            with self.subTest(messages=len(value)), self.assertRaises(ValueError):
                runner.artifact_bindings(value, self.metadata)
        foreign = copy.deepcopy(self.messages)
        foreign[0]['package_id'] = 'foreign-owner'
        bindings = runner.artifact_bindings(foreign, self.metadata)
        with self.assertRaises(ValueError):
            runner.running_sections(self.log('a'), ['a/same'], bindings, self.cwd)

    def test_exact_union_filters_refuse_cross_owner_route_collisions(self):
        names = {'a/same':['shared', 'a_case'], 'b/same':['shared', 'b_case']}
        self.assertEqual(runner.group_filters(names, {'a/same':['a_case'], 'b/same':['b_case']}),
                         ['a_case','b_case'])
        with self.assertRaises(ValueError):
            runner.group_filters(names, {'a/same':['shared'], 'b/same':[]})


class ParityConsumerScopeTests(unittest.TestCase):
    def test_closed_scope_retains_every_same_name_workspace_sibling(self):
        declared = {key: {'name': key.split('/')[1]} for key in (
            'arkdeck-cli/shared', 'arkdeck-contract/contract',
            'arkdeck-hoststore/shared', 'arkdeck-hoststore/private')}
        plan = {'run': [(key.split('/')[0], target) for key, target in declared.items()]}
        self.assertEqual(runner.integration_groups(declared, plan, parity_consumers=True), {
            'contract': ['arkdeck-contract/contract'],
            'shared': ['arkdeck-cli/shared', 'arkdeck-hoststore/shared']})
        self.assertEqual(runner.integration_groups(declared, plan), {
            'contract': ['arkdeck-contract/contract'],
            'private': ['arkdeck-hoststore/private'],
            'shared': ['arkdeck-cli/shared', 'arkdeck-hoststore/shared']})
        self.assertIn('--workspace', runner.BASE)
        self.assertNotIn('--package', runner.BASE)

    def test_unknown_command_scope_is_refused_before_any_cargo_call(self):
        with patch.object(sys, 'argv', ['run-workspace-tests.py', '--packages', 'arkdeck-cli']), \
             patch.object(runner, 'catalog_selected') as selected:
            with self.assertRaisesRegex(ValueError, 'unknown workspace test scope'):
                runner.main()
            selected.assert_not_called()


class CompleteModuleHostCfgTests(unittest.TestCase):
    def exercise(self, platform, key='arkdeck-cli/device_wait', listing='', output=None):
        with tempfile.TemporaryDirectory(prefix='arkdeck-module-host-cfg-') as temporary:
            cwd = Path(temporary) / 'rust'
            cwd.mkdir()
            report = Path(temporary) / 'report'
            report.mkdir()
            package, name = key.split('/')
            target = {'kind': ['test'], 'name': name, 'test': True,
                      'src_path': str(cwd / 'crates' / package / 'tests' / (name + '.rs'))}
            metadata = {'workspace_members': ['owner'], 'packages': [
                {'id': 'owner', 'name': package, 'manifest_path': str(cwd / 'crates' / package / 'Cargo.toml'),
                 'targets': [target]}]}
            executable = str(cwd / 'target' / (name + '.exe'))
            messages = [{'reason': 'compiler-artifact', 'package_id': 'owner', 'target': target,
                         'executable': executable}, {'reason': 'build-finished', 'success': True}]
            row = {'route': 'both', 'functions': {}, 'ignored': [],
                   'modulePlatforms': runner.catalog_views.MODULE_HOST_PLATFORMS.get(key, [])}
            manifest = {'targets': {key: row}}
            manifest_path = cwd / runner.catalog_views.MANIFEST
            manifest_path.parent.mkdir(parents=True)
            manifest_path.write_text(json.dumps(manifest), encoding='utf-8')
            plan = {'run': [(package, target)], 'excluded': [],
                    'commands': [('integrations', runner.BASE + ['--test', name])]}
            calls = []

            def recorded(argv, directory, label, cwd):
                calls.append(argv)
                path = directory / (label + '.log')
                if label == 'compile':
                    text = '\n'.join(json.dumps(message) for message in messages) + '\n'
                elif '--test' in argv:
                    text = 'Running tests/' + name + '.rs (' + executable + ')\n'
                    text += (listing + '\n0 tests, 0 benchmarks\n' if '--list' in argv else
                             output if output is not None else
                             'running 0 tests\ntest result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n')
                else:
                    text = 'built workspace bins\n'
                path.write_text(text, encoding='utf-8')
                return {'name': label, 'argv': argv, 'exitCode': 0, 'log': str(path)}

            with patch.object(runner.subprocess, 'check_output', return_value=json.dumps(metadata)), \
                 patch.object(runner, 'host_cfg', return_value=set()), \
                 patch.object(runner, 'host_plan', return_value=plan), \
                 patch.object(runner, 'recorded', side_effect=recorded), \
                 patch.object(runner.catalog_views, 'load', return_value=manifest), \
                 patch.object(runner.catalog_views, 'catalog', return_value=runner.catalog_views.CURRENT), \
                 patch.object(runner.catalog_views, 'custom_harnesses', return_value={}), \
                 patch.object(runner.sys, 'platform', platform), \
                 patch.dict(os.environ, {'ARKDECK_DEV_SIGNER_THUMBPRINT': 'a' * 40}, clear=True):
                try:
                    result = runner.catalog_selected(cwd, 1, report)
                except ValueError as error:
                    result = str(error)
            return result, calls, json.loads((report / 'catalog-execution.json').read_bytes())

    def test_only_audited_inactive_module_executes_and_reports_zero_coverage(self):
        for platform in ('linux', 'win32'):
            with self.subTest(platform=platform):
                result, calls, report = self.exercise(platform)
                self.assertEqual(result, 0)
                self.assertTrue(report['completed'])
                self.assertEqual(report['targets'][0]['execution'], 'host-cfg-excluded')
                self.assertEqual(report['targets'][0]['passed'], 0)
                self.assertFalse(report['targets'][0]['coverage'])
                actual = [argv for argv in calls if '--test' in argv]
                self.assertEqual(actual, [runner.BASE + ['--test', 'device_wait', '--no-run', '--message-format=json'],
                                          runner.BASE + ['--test', 'device_wait', '--', '--list'],
                                          runner.BASE + ['--test', 'device_wait']])

    def test_active_or_unclassified_empty_module_is_never_an_exclusion(self):
        for platform, key in [('darwin', 'arkdeck-cli/device_wait'), ('linux', 'arkdeck-cli/unreviewed')]:
            with self.subTest(platform=platform, key=key):
                result, _, report = self.exercise(platform, key)
                self.assertEqual(result, 'empty libtest list is not an audited host cfg exclusion')
                self.assertFalse(report['completed'])

    def test_excluded_module_cannot_hide_nonempty_failed_missing_or_duplicate_completion(self):
        invalid = ['', 'test result: FAILED. 0 passed; 1 failed; 0 ignored;\n',
                   'test result: ok. 0 passed; 0 failed; 1 ignored;\n',
                   'test result: ok. 0 passed; 0 failed; 0 ignored;\n' * 2,
                   'test new_case ... ok\ntest result: ok. 1 passed; 0 failed; 0 ignored;\n']
        for output in invalid:
            with self.subTest(output=output):
                result, _, report = self.exercise('linux', output=output)
                self.assertIsInstance(result, str)
                self.assertFalse(report['completed'])
        result, _, report = self.exercise('linux', listing='runtime::new_case: test')
        self.assertEqual(result, 'host-excluded module changed its target or case census')
        self.assertFalse(report['completed'])

    def test_unknown_platform_or_module_declaration_is_refused(self):
        with self.assertRaises(ValueError):
            runner.catalog_views.module_host_cfg_excluded('arkdeck-cli/device_wait',
                                                         {'modulePlatforms': ['linux']}, 'linux')
        with self.assertRaises(ValueError):
            runner.catalog_views.module_host_cfg_excluded('arkdeck-cli/device_wait',
                                                         {'modulePlatforms': ['darwin']}, 'unreviewed')


class CustomHarnessExecutionTests(unittest.TestCase):
    def exercise(self, protocol, output=None):
        with tempfile.TemporaryDirectory(prefix='arkdeck-custom-protocol-') as temporary:
            cwd = Path(temporary) / 'rust'
            cwd.mkdir()
            report = Path(temporary) / 'report'
            report.mkdir()
            name = 'windows_console_secret'
            key = 'arkdeck-platform/' + name
            target = {'kind':['test'], 'name':name, 'test':True,
                      'src_path':str(cwd/'crates/arkdeck-platform/tests'/ (name+'.rs'))}
            metadata = {'workspace_members':['owner'], 'packages':[{'id':'owner','name':'arkdeck-platform',
                        'manifest_path':str(cwd/'crates/arkdeck-platform/Cargo.toml'),'targets':[target]}]}
            executable = str(cwd/'target'/ (name+'.exe'))
            messages = [{'reason':'compiler-artifact','package_id':'owner','target':target,'executable':executable},
                        {'reason':'build-finished','success':True}]
            manifest = {'targets':{key:{'route':'both','functions':{},'ignored':{},
                                       'customCases':{'win32':['real_case']}}}}
            manifest_path = cwd / runner.catalog_views.MANIFEST
            manifest_path.parent.mkdir(parents=True)
            manifest_path.write_text(json.dumps(manifest), encoding='utf-8')
            plan = {'run':[('arkdeck-platform',target)], 'excluded':[],
                    'commands':[('integrations',runner.BASE+['--test',name])]}
            calls = []
            def recorded(argv, directory, label, cwd):
                calls.append(argv)
                path = directory / (label+'.log')
                if label == 'compile':
                    text = '\n'.join(json.dumps(message) for message in messages)+'\n'
                elif '--test' in argv:
                    text = 'Running tests/'+name+'.rs ('+executable+')\n'
                    text += ('real_case: test\n' if '--list' in argv else output if output is not None else
                             'test real_case ... ok\n' + ('' if protocol == 'default-rows' else
                             'test result: ok. 1 passed; 0 failed\n'))
                else:
                    text = 'built workspace bins\n'
                path.write_text(text,encoding='utf-8')
                return {'name':label,'argv':argv,'exitCode':0,'log':str(path)}
            with patch.object(runner.subprocess,'check_output',return_value=json.dumps(metadata)), \
                 patch.object(runner,'host_cfg',return_value=set()), \
                 patch.object(runner,'host_plan',return_value=plan), \
                 patch.object(runner,'recorded',side_effect=recorded), \
                 patch.object(runner.catalog_views,'load',return_value=manifest), \
                 patch.object(runner.catalog_views,'catalog',return_value=runner.catalog_views.CURRENT), \
                 patch.object(runner.catalog_views,'custom_harnesses',return_value={key:(protocol,('win32',))}), \
                 patch.object(runner.sys,'platform','win32'), \
                 patch.dict(os.environ,{'ARKDECK_DEV_SIGNER_THUMBPRINT':'a'*40},clear=True):
                result = runner.catalog_selected(cwd,1,report)
            return result, calls, json.loads((report/'catalog-execution.json').read_bytes())

    def test_default_only_custom_summary_runs_without_listing_or_filters(self):
        result, calls, report = self.exercise('default-summary')
        self.assertEqual(result,0)
        self.assertFalse(any('--list' in argv for argv in calls))
        self.assertFalse(any('--ignored' in argv for argv in calls))
        self.assertFalse(any('--exact' in argv for argv in calls))
        self.assertTrue(report['completed'])
        self.assertEqual(report['targets'][0]['execution'],'actual')
        self.assertEqual(report['targets'][0]['passed'],1)
        self.assertTrue(all('--workspace' in argv for argv in calls))
        self.assertFalse(any('--package' in argv for argv in calls))

    def test_listed_custom_uses_its_listing_protocol_without_ignored_listing(self):
        result,calls,report = self.exercise('listed-summary')
        self.assertEqual(result,0)
        self.assertEqual(sum('--list' in argv for argv in calls),1)
        self.assertFalse(any('--ignored' in argv for argv in calls))
        self.assertTrue(any('--exact' in argv for argv in calls))
        self.assertTrue(report['completed'])
        self.assertTrue(all('--workspace' in argv for argv in calls))

    def test_rows_only_custom_requires_its_exact_successful_rows(self):
        result,calls,report = self.exercise('default-rows')
        self.assertEqual(result,0)
        self.assertFalse(any('--list' in argv for argv in calls))
        self.assertTrue(report['completed'])
        for output in ['', 'test real_case ... FAILED\n', 'test another_case ... ok\n',
                       'test real_case ... ok\ntest result: ok. 1 passed; 0 failed\n']:
            with self.subTest(output=output):
                result,_,report = self.exercise('default-rows',output)
                self.assertEqual(result,1)
                self.assertFalse(report['completed'])

    def test_missing_failed_duplicate_or_uncounted_custom_completion_refuses(self):
        for output in ['', 'test real_case ... ok\n', 'test real_case ... FAILED\ntest result: FAILED. 0 passed; 1 failed\n',
                       'test real_case ... ok\ntest result: ok. 2 passed; 0 failed\n',
                       'test real_case ... ok\ntest real_case ... ok\ntest result: ok. 2 passed; 0 failed\n']:
            with self.subTest(output=output):
                result,_,report = self.exercise('default-summary',output)
                self.assertEqual(result,1)
                self.assertFalse(report['completed'])


if __name__ == '__main__':
    unittest.main()

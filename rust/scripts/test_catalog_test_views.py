"""Guard exact test coverage across Catalog views without running a Runtime."""
from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import catalog_test_views as views

GENERATOR_PATH = Path(__file__).resolve().parents[2] / 'scripts/catalog_gen/generate.py'
GENERATOR_SPEC = importlib.util.spec_from_file_location('catalog_view_guard_generator', GENERATOR_PATH)
GENERATOR = importlib.util.module_from_spec(GENERATOR_SPEC)
GENERATOR_SPEC.loader.exec_module(GENERATOR)


class CoverageReceipts(unittest.TestCase):
    def test_exact_mixed_functions_keep_both_views(self):
        row = {'route': 'mixed', 'functions': {
            'historical_positive': 'historical', 'current_refusal': 'current',
            'shared::guard': 'both'}}
        names = sorted(row['functions'])
        self.assertEqual(views.selected(row, names, views.OLD),
                         ['historical_positive', 'shared::guard'])
        self.assertEqual(views.selected(row, names, views.CURRENT),
                         ['current_refusal', 'shared::guard'])

    def test_new_or_missing_mixed_function_fails_closed(self):
        row = {'route': 'mixed', 'functions': {'old': 'historical'}}
        for names in ([], ['old', 'new']):
            with self.subTest(names=names), self.assertRaises(ValueError):
                views.selected(row, names, views.CURRENT)

    def test_unknown_catalog_has_no_execution_route(self):
        with self.assertRaises(ValueError):
            views.selected({'route': 'both', 'functions': {}}, ['guard'], '0' * 64)

    def test_terminal_listing_supports_windows_and_color(self):
        self.assertEqual(views.listed('\x1b[32mnegative: test\x1b[0m\r\npositive: test\r\n'),
                         ['negative', 'positive'])

    def test_duplicate_listing_is_refused(self):
        with self.assertRaises(ValueError):
            views.listed('a: test\na: test\n')

    @staticmethod
    def receipt(lines, passed=2, failed=0, ignored=0, state='ok'):
        return ('\n'.join(lines) + '\n' +
                f'test result: {state}. {passed} passed; {failed} failed; {ignored} ignored; '
                '0 measured; 0 filtered out; finished in 0.01s\n')

    def test_whole_receipt_requires_the_negative_case_too(self):
        text = self.receipt(['test positive ... ok', 'test negative ... ok'])
        result = views.verify_execution(text, ['negative', 'positive'])
        self.assertEqual(result, {'functions': ['negative', 'positive'],
                                 'passed': 2, 'ignored': 0, 'completed': True})

    def test_windows_receipt_representation_is_accepted(self):
        text = self.receipt(['test positive ... ok', 'test negative ... ok'])
        text = '\x1b[32m' + text.replace('\n', '\r\n') + '\x1b[0m'
        self.assertEqual(views.verify_execution(text, ['negative', 'positive'])['passed'], 2)

    def test_missing_duplicate_or_extra_case_refuses(self):
        for rows in (['test positive ... ok'],
                     ['test positive ... ok', 'test positive ... ok'],
                     ['test positive ... ok', 'test negative ... ok', 'test extra ... ok']):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                views.verify_execution(self.receipt(rows), ['negative', 'positive'])

    def test_zero_or_only_ignored_does_not_count_as_execution(self):
        for rows, names, ignored in (([], [], 0), (['test guard ... ignored'], ['guard'], 1)):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                views.verify_execution(self.receipt(rows, passed=0, ignored=ignored), names)

    def test_ignored_negative_does_not_borrow_the_positive_execution(self):
        text = self.receipt(['test positive ... ok', 'test negative ... ignored'],
                            passed=1, ignored=1)
        with self.assertRaises(ValueError):
            views.verify_execution(text, ['negative', 'positive'])

    def test_only_exact_audited_ignored_names_can_be_reported(self):
        text = self.receipt(['test guard ... ok', 'test known_performance ... ignored'],
                            passed=1, ignored=1)
        result = views.verify_execution(text, ['guard', 'known_performance'],
                                        ignored=['known_performance'])
        self.assertEqual((result['passed'], result['ignored']), (1, 1))

    def test_extra_or_unobserved_audited_ignored_name_refuses(self):
        text = self.receipt(['test guard ... ok'], passed=1)
        with self.assertRaises(ValueError):
            views.verify_execution(text, ['guard'], ignored=['missing'])

    def test_failed_case_and_false_counts_are_refused(self):
        texts = [self.receipt(['test positive ... ok', 'test negative ... FAILED'],
                             passed=1, failed=1, state='FAILED'),
                 self.receipt(['test positive ... ok', 'test negative ... ok'], passed=3)]
        for text in texts:
            with self.subTest(text=text), self.assertRaises(ValueError):
                views.verify_execution(text, ['negative', 'positive'])

    def test_missing_or_second_completion_is_refused(self):
        good = self.receipt(['test guard ... ok'], passed=1)
        for text in ('test guard ... ok\n', good + good.splitlines()[-1] + '\n'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                views.verify_execution(text, ['guard'])

    def test_child_entry_cannot_borrow_its_parent_or_claim_substantive_coverage(self):
        row = {'ignored': [], 'childEntries': ['child']}
        self.assertEqual(views.substantive_cases(row, ['child'], {}), ([], []))
        self.assertEqual(views.substantive_cases(row, ['child', 'parent'], {}), (['parent'], []))

    def test_absent_optional_material_is_reported_without_live_coverage(self):
        row = {'ignored': [], 'optionalMaterial': {'live': ['MATERIAL', 'RECORDING']}}
        for environment in ({}, {'MATERIAL': 'x'}, {'MATERIAL': 'x', 'RECORDING': ''}):
            self.assertEqual(views.substantive_cases(row, ['live', 'guard'], environment),
                             (['guard'], ['live']))
        self.assertEqual(views.substantive_cases(row, ['live'], {'MATERIAL': 'x', 'RECORDING': 'y'}),
                         (['live'], []))


class ClosedSources(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix='arkdeck-test-catalog-views-')).resolve()
        self.assertEqual(self.base.parent, Path(tempfile.gettempdir()).resolve())
        self.rust = self.base / 'rust'
        self.write('rust/crates/demo/tests/positive.rs', b'fn positive() {}\n')
        self.write('rust/crates/demo/Cargo.toml', b'[package]\nname="demo"\n')
        self.write('rust/tests/fixtures/original/cases.json', b'{"case":"original"}\n')
        self.metadata = {'workspace_members': ['demo-id'], 'packages': [{
            'id': 'demo-id', 'name': 'demo',
            'manifest_path': str(self.rust / 'crates/demo/Cargo.toml'), 'targets': [{
                'name': 'positive', 'kind': ['test'], 'test': True}]}]}
        self.manifest = {'schemaVersion': 'arkdeck.catalog-test-views/1',
                         'catalogs': [views.OLD, views.CURRENT],
                         'sources': views.source_inventory(self.rust),
                         'fixtures': views.fixture_inventory(self.rust),
                         'targets': {'demo/positive': {
                             'route': 'both', 'functions': {}, 'ignored': []}}}
        self.save_manifest()

    def tearDown(self):
        # Only ordinary entries of the exact verified task-local directory.
        paths = sorted(self.base.rglob('*'), key=lambda p: len(p.parts), reverse=True)
        for path in paths:
            self.assertTrue(path.resolve().is_relative_to(self.base))
            if path.is_file():
                path.unlink()
            else:
                path.rmdir()
        self.base.rmdir()

    def write(self, name, data):
        path = self.base / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def save_manifest(self):
        self.write('rust/' + views.MANIFEST, json.dumps(self.manifest).encode())

    def load(self):
        with patch.object(views, 'catalog', return_value=views.CURRENT):
            return views.load(self.rust, self.metadata)

    def test_source_crlf_only_is_the_declared_representation(self):
        self.write('rust/crates/demo/tests/positive.rs', b'fn positive() {}\r\n')
        self.assertEqual(self.load(), self.manifest)

    def test_real_source_tamper_and_new_source_are_refused(self):
        for name, data in [('positive.rs', b'fn positive() { panic!(); }\n'),
                           ('new_negative.rs', b'fn new_negative() {}\n')]:
            with self.subTest(name=name):
                path = self.rust / 'crates/demo/tests' / name
                original = path.read_bytes() if path.exists() else None
                path.write_bytes(data)
                with self.assertRaises(ValueError):
                    self.load()
                if original is None:
                    path.unlink()
                else:
                    path.write_bytes(original)

    def test_new_target_is_refused_even_when_existing_sources_match(self):
        self.metadata['packages'][0]['targets'].append(
            {'name': 'new_negative', 'kind': ['test'], 'test': True})
        with self.assertRaises(ValueError):
            self.load()

    def test_original_fixture_byte_changes_are_never_source_normalized(self):
        path = self.rust / 'tests/fixtures/original/cases.json'
        original = path.read_bytes()
        for data in (original.replace(b'\n', b'\r\n'), b'{"case":"tampered"}\n'):
            with self.subTest(data=data):
                path.write_bytes(data)
                with self.assertRaises(ValueError):
                    self.load()
        path.write_bytes(original)
        self.assertEqual(self.load(), self.manifest)

    def test_new_or_missing_fixture_is_refused(self):
        path = self.rust / 'tests/fixtures/original/cases.json'
        original = path.read_bytes()
        path.unlink()
        with self.assertRaises(ValueError):
            self.load()
        path.write_bytes(original)
        self.write('rust/tests/fixtures/original/unclassified.json', b'{}\n')
        with self.assertRaises(ValueError):
            self.load()

    def test_duplicate_target_is_refused(self):
        self.metadata['packages'][0]['targets'] *= 2
        with self.assertRaises(ValueError):
            self.load()

    def test_unknown_schema_catalog_and_route_refuse(self):
        good = copy.deepcopy(self.manifest)
        bad_values = [dict(good, schemaVersion='unknown'),
                      dict(good, catalogs=[views.OLD, '0' * 64]),
                      dict(good, targets={'demo/positive': {
                          'route': 'skip', 'functions': {}, 'ignored': []}}),
                      dict(good, targets={'demo/positive': {
                          'route': 'mixed', 'functions': {}, 'ignored': []}})]
        for bad in bad_values:
            with self.subTest(bad=bad):
                self.manifest = bad
                self.save_manifest()
                with self.assertRaises(ValueError):
                    self.load()

    def tables(self):
        old = {f'operation-{n}@1': {'id': f'operation-{n}', 'version': 1} for n in range(31)}
        old['deploy.native-library.app-owned@1'] = {
            'id': 'deploy.native-library.app-owned', 'version': 1, 'steps': ['old']}
        current = copy.deepcopy(old)
        current['deploy.native-library.app-owned@1']['steps'] = ['new']
        return old, current

    def generated(self, digest, table):
        return GENERATOR.generate_rust(list(table.values()), digest)

    def catalog_view(self, digest, table, generated=None):
        for row in table.values():
            self.write('Catalog/operations/' + row['id'] + '.json', json.dumps(row).encode())
        self.write('rust/crates/arkdeck-contract/src/catalog_generated.rs',
                   (generated or self.generated(digest, table)).encode())
        with patch.object(views, 'catalogs', return_value=self.tables()):
            return views.catalog(self.rust)

    def test_both_exact_complete_catalog_views_are_accepted(self):
        old, current = self.tables()
        self.assertEqual(self.catalog_view(views.OLD, old), views.OLD)
        self.assertEqual(self.catalog_view(views.CURRENT, current), views.CURRENT)
        self.assertEqual(self.catalog_view(views.CURRENT, current,
                                          self.generated(views.CURRENT, current).replace('\n', '\r\n')),
                         views.CURRENT)

    def test_commented_or_other_const_cannot_spoof_the_generated_view(self):
        _, current = self.tables()
        generated = self.generated(views.OLD, current)
        for fake in (f'// CATALOG_DIGEST: &str = "{views.CURRENT}";\n',
                     f'pub const OTHER_CATALOG_DIGEST: &str = "{views.CURRENT}";\n'):
            with self.subTest(fake=fake), self.assertRaises(ValueError):
                self.catalog_view(views.CURRENT, current, fake + generated)

    def test_wrong_generated_descriptor_table_is_refused(self):
        old, current = self.tables()
        with self.assertRaises(ValueError):
            self.catalog_view(views.CURRENT, current, self.generated(views.CURRENT, old))

    def test_block_comment_cannot_replace_active_catalog_declarations(self):
        old, current = self.tables()
        # Legal active Rust declarations differ only in spacing; the exact
        # current declarations exist solely inside a Rust block comment.
        active = self.generated(views.OLD, old).replace('pub const ', 'pub  const ')
        spoof = '/*\n' + self.generated(views.CURRENT, current) + '*/\n' + active
        with self.assertRaises(ValueError):
            self.catalog_view(views.CURRENT, current, spoof)

    def test_wrong_actual_descriptor_is_refused(self):
        _, current = self.tables()
        changed = copy.deepcopy(current)
        changed['operation-0@1']['newField'] = 'unexpected'
        with self.assertRaises(ValueError):
            self.catalog_view(views.CURRENT, changed)


if __name__ == '__main__':
    unittest.main()

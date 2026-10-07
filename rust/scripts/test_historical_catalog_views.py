"""Check immutable c6 test inputs after the published base has become e4."""
from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name('check-contracts.py')
SPEC = importlib.util.spec_from_file_location('historical_catalog_view_guards', SCRIPT)
runner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runner
SPEC.loader.exec_module(runner)
views = runner.catalog_test_views
MATRIX = 'Catalog/generated/effect-authorization-matrix.md'


def blob(data):
    return hashlib.sha1(f'blob {len(data)}\0'.encode() + data).hexdigest()


class HistoricalCatalogInputs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.real_root = runner.ROOT
        cls.current = runner.contract.working_inputs()
        cls.old, cls.new = views.catalogs(cls.real_root / 'rust')
        cls.packet_path = 'rust/tests/fixtures/catalog-lineage-c6-e4/catalogs.json'
        cls.packet = (cls.real_root / cls.packet_path).read_bytes()
        cls.generator = (cls.real_root / 'scripts/catalog_gen/generate.py').read_bytes()
        cls.projection = (cls.real_root / runner.REVIEW_PROJECTION).read_bytes()

    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix='arkdeck-historical-view-')).resolve()
        self.assertEqual(self.base.parent, Path(tempfile.gettempdir()).resolve())
        for name, data in [(self.packet_path, self.packet),
                           ('scripts/catalog_gen/generate.py', self.generator)]:
            path = self.base / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.root_patch = patch.object(runner, 'ROOT', self.base)
        self.root_patch.start()
        self.inputs = copy.deepcopy(self.current)

    def tearDown(self):
        self.root_patch.stop()
        for path in sorted(self.base.rglob('*'), key=lambda p: len(p.parts), reverse=True):
            self.assertTrue(path.resolve().is_relative_to(self.base))
            if path.is_file():
                path.unlink()
            else:
                path.rmdir()
        self.base.rmdir()

    def operation_paths(self, inputs):
        return {path: json.loads(data) for path, data in inputs.files.items()
                if path.startswith('Catalog/operations/') and path.endswith('.json')}

    def test_postmerge_current_inputs_become_the_exact_complete_historical_catalog(self):
        before = copy.deepcopy(self.inputs)
        historical = runner.historical_catalog_inputs(self.inputs)
        operations = self.operation_paths(historical)
        self.assertEqual(len(operations), 32)
        self.assertEqual({f"{row['id']}@{row.get('version', 0)}": row
                          for row in operations.values()}, self.old)
        self.assertEqual(historical.directories, before.directories)
        self.assertEqual(set(historical.files), set(before.files))
        allowed = set(operations) | {MATRIX}
        for path, data in before.files.items():
            if path not in allowed:
                self.assertEqual(historical.files[path], data, path)
                self.assertEqual(historical.blobs[path], before.blobs[path], path)
        for path in allowed:
            self.assertEqual(historical.blobs[path], blob(historical.files[path]), path)
        self.assertEqual(self.inputs, before, 'the caller snapshot must remain immutable')
        actual_info = runner.contract.baseline(historical)
        self.assertEqual(actual_info['catalogDigest'], views.OLD)
        self.assertNotEqual(actual_info['inputDigest'], runner.contract.baseline(before)['inputDigest'])

    def test_historical_matrix_is_the_full_official_generation(self):
        historical = runner.historical_catalog_inputs(self.inputs)
        profiles = [json.loads(data) for path, data in self.inputs.files.items()
                    if path.startswith('Catalog/profiles/') and path.endswith('.json')]
        generator = runner.load_module('historical_catalog_expected_generator',
                                      self.base / 'scripts/catalog_gen/generate.py')
        expected = generator.generate_matrix(list(self.old.values()), profiles, views.OLD).encode()
        self.assertEqual(historical.files[MATRIX], expected)

    def test_a_historical_input_stays_exact_when_the_base_is_already_historical(self):
        historical = runner.historical_catalog_inputs(self.inputs)
        repeated = runner.historical_catalog_inputs(historical)
        self.assertEqual(repeated, historical)

    def test_workspace_coverage_requires_exact_non_catalog_bytes_and_complete_membership(self):
        historical = runner.historical_catalog_inputs(self.inputs)
        published = copy.deepcopy(historical)
        self.assertTrue(runner.historical_workspace_covers(published, historical))
        path = next(path for path in historical.files
                    if not path.startswith('Catalog/') and b'\n' in historical.files[path])
        representation = (historical.files[path].replace(b'\r\n', b'\n')
                          if b'\r\n' in historical.files[path]
                          else historical.files[path].replace(b'\n', b'\r\n'))
        for data in [representation,
                     historical.files[path] + b'changed']:
            changed = copy.deepcopy(published)
            changed.files[path] = data
            self.assertNotEqual(data, historical.files[path])
            self.assertFalse(runner.historical_workspace_covers(changed, historical))
        changed = copy.deepcopy(published)
        del changed.files[path]
        self.assertFalse(runner.historical_workspace_covers(changed, historical))
        changed = copy.deepcopy(published)
        changed.directories.add('unclassified-input-directory')
        self.assertFalse(runner.historical_workspace_covers(changed, historical))
        self.assertFalse(runner.historical_workspace_covers(self.inputs, historical))
        # Only Catalog operation JSON spelling may vary without changing its value.
        operation = sorted(self.operation_paths(historical))[0]
        published.files[operation] = json.dumps(json.loads(published.files[operation]),
                                               separators=(',', ':')).encode()
        self.assertTrue(runner.historical_workspace_covers(published, historical))

    def test_wrong_descriptor_missing_extra_or_duplicate_catalog_refuses(self):
        operations = self.operation_paths(self.inputs)
        first, second = sorted(operations)[:2]
        mutations = []
        changed = copy.deepcopy(self.inputs)
        row = copy.deepcopy(operations[first])
        row['title'] += ' changed'
        changed.files[first] = json.dumps(row).encode()
        mutations.append(changed)
        missing = copy.deepcopy(self.inputs)
        del missing.files[first]
        mutations.append(missing)
        extra = copy.deepcopy(self.inputs)
        extra.files['Catalog/operations/unclassified.json'] = self.inputs.files[first]
        mutations.append(extra)
        duplicate = copy.deepcopy(self.inputs)
        duplicate.files[first] = self.inputs.files[second]
        mutations.append(duplicate)
        for value in mutations:
            with self.subTest(files=len(value.files)), self.assertRaises(ValueError):
                runner.historical_catalog_inputs(value)

    def test_wrong_complete_matrix_refuses(self):
        self.inputs.files[MATRIX] += b'\nUnreviewed matrix change\n'
        with self.assertRaises(ValueError):
            runner.historical_catalog_inputs(self.inputs)

    def test_wrong_frozen_lineage_packet_refuses_before_materialization(self):
        path = self.base / self.packet_path
        path.write_bytes(self.packet + b'\n')
        with self.assertRaises(ValueError):
            runner.historical_catalog_inputs(self.inputs)

    def test_projection_changes_only_its_single_exact_catalog_occurrence(self):
        result = runner.historical_review_projection(self.projection)
        self.assertEqual(result, self.projection.replace(views.CURRENT.encode(), views.OLD.encode()))
        self.assertEqual(result.count(views.OLD.encode()), 1)
        self.assertNotIn(views.CURRENT.encode(), result)
        self.assertEqual(runner.historical_review_projection(result), result)

    def test_unknown_missing_duplicate_or_mixed_projection_catalog_refuses(self):
        for value in [self.projection.replace(views.CURRENT.encode(), b'0' * 64),
                      self.projection.replace(views.CURRENT.encode(), b''),
                      self.projection + views.CURRENT.encode(),
                      self.projection + views.OLD.encode()]:
            with self.subTest(value_length=len(value)), self.assertRaises(ValueError):
                runner.historical_review_projection(value)


if __name__ == '__main__':
    unittest.main()

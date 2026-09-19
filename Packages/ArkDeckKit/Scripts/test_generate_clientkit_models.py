import copy
import importlib.util
import json
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name('generate-clientkit-models.py')
spec = importlib.util.spec_from_file_location('generator', SCRIPT)
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class ClientKitGeneratorTests(unittest.TestCase):
    def setUp(self):
        self.documents = {method: json.loads((generator.ROOT / f'spec/control/methods/{method}.json').read_text()) for method in generator.METHODS}

    def test_committed_output_is_deterministic(self):
        output = generator.render(self.documents)
        self.assertEqual(output, generator.render(dict(reversed(list(self.documents.items())))))
        self.assertEqual(output, (generator.ROOT / generator.DESTINATION).read_text())

    def test_optional_nullable_keeps_three_wire_states(self):
        output = generator.render(self.documents)
        self.assertIn('let sessionId: HistoryWireNullable<String>?', output)
        self.assertIn('fields["sessionId"].map(HistoryWireNullable<String>.decode)', output)
        self.assertIn('fields["sessionId"] = sessionId?.wire', output)
        self.assertIn('Set(fields.keys).isSubset', output)

    def test_unsupported_schema_is_not_erased_to_any(self):
        for child in ({'type': 'integer'}, {'type': 'object', 'additionalProperties': True}, {'type': 'string', 'pattern': 'x'}):
            with self.subTest(child=child):
                documents = copy.deepcopy(self.documents)
                documents['history.filter.save']['$defs']['request']['properties']['search'] = child
                with self.assertRaises(ValueError):
                    generator.render(documents)

    def test_wrong_method_identity_fails(self):
        self.documents['history.filter.list']['x-arkdeck-method'] = 'job.run'
        with self.assertRaises(ValueError):
            generator.render(self.documents)


if __name__ == '__main__':
    unittest.main()

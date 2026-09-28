"""RSS phase evidence must remain adjacent and belong to the owned idle process."""
import json
import pathlib
import subprocess
import unittest
from unittest import mock

from . import clocks, harness, metrics


class ReleaseAdjacencyTests(unittest.TestCase):
    def test_missing_observation_cannot_prove_release(self):
        self.assertEqual(
            metrics.split_at_release([100., 40.], observation_indices=[0, 2]),
            ([100., 40.], [], None),
        )

    def test_real_adjacent_release_after_gap_is_retained(self):
        self.assertEqual(
            metrics.split_at_release([100., 90., 40.], observation_indices=[0, 2, 3]),
            ([100., 90.], [40.], 2),
        )

    def test_invalid_observation_indices_are_rejected(self):
        for indices in ([0], [0, 0], [2, 1], [False, 1], [-1, 0]):
            with self.subTest(indices=indices), self.assertRaises(ValueError):
                metrics.split_at_release([100., 40.], observation_indices=indices)

    def test_archived_formal_series_still_have_no_release(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        path = root / (
            'openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/'
            'TASK-XPA-025/formal-scale-20260927/perf-baseline-2026-09-27.json'
        )
        document = json.loads(path.read_text())
        for run in document['runs']:
            values = [point['bytes'] for point in run['scale']['residentSetRawSamples']]
            self.assertEqual(
                metrics.split_at_release(values, observation_indices=list(range(len(values)))),
                (values, [], None),
            )


class IdleOwnershipTests(unittest.TestCase):
    def execute(self, values, polls=None):
        records = []
        context = metrics.RunContext(
            daemon_executable=pathlib.Path('/daemon'),
            soak_executable=pathlib.Path('/soak'),
            cold_start_samples=0, ipc_samples=0, idle_seconds=5, calibration_samples=0,
            seed_seconds=1, seed_jobs_per_cycle=1,
            capture_recorder=lambda row: records.append(json.loads(json.dumps(row))),
        )
        resources = []
        for value in values:
            item = harness.ProcessResources()
            item.resident_set_bytes = value
            if value is None:
                item.unmeasured['residentSetBytes'] = 'missing test observation'
            resources.append(item)
        ticks = iter(range(100, 100 + len(values) * 2 + 1))
        with mock.patch.object(harness, 'seed_state_directory',
                               return_value=subprocess.CompletedProcess([], 0, '', '')), \
             mock.patch.object(harness, 'IsolatedRuntime') as factory, \
             mock.patch.object(harness, 'sample_process_resources', side_effect=resources) as reader, \
             mock.patch.object(clocks, 'awake_seconds', side_effect=lambda: next(ticks)), \
             mock.patch.object(clocks, 'Deadline') as deadline, \
             mock.patch.object(metrics.time, 'sleep'):
            runtime = factory.return_value
            runtime.process.pid = 12345
            runtime.process.poll.side_effect = polls
            runtime.process.poll.return_value = None
            runtime.start_diagnostics = {'observationVersion': 'startup-observation-v2'}
            runtime.client.return_value.__enter__.return_value.call.return_value = {
                'items': [{'jobId': 'one'}],
            }
            deadline.return_value.expired.side_effect = [False] * len(values) + [True]
            try:
                result = metrics.execute_run(context, pathlib.Path('/state'))
            except metrics.RunFailed:
                result = None
            self.assertGreaterEqual(runtime.stop.call_count, 2)
            return result, records, reader.call_count

    def test_gap_survives_filtering_and_preserves_raw_indices(self):
        (samples, scale), records, _ = self.execute([100., None, 40.])
        self.assertNotIn('daemon.residentSetSteady', samples)
        self.assertEqual(scale['residentSetObservationIndices'], [0, 2])
        self.assertEqual(scale['residentSetMissingSampleCount'], 1)
        self.assertEqual(scale['residentSetPhaseMethod'], 'observed-release-v3')
        idle = [record for record in records if record['kind'] == 'idleResources']
        self.assertEqual([record['observationIndex'] for record in idle], [0, 1, 2])
        self.assertTrue(all(record['processId'] == 12345 and record['ownedProcessAliveAfterSample']
                            for record in idle))
        self.assertIsNone(idle[1]['residentSetBytes'])
        self.assertTrue(any(record['kind'] == 'idleWindow' and record['processId'] == 12345
                            for record in records))

    def test_all_missing_rss_is_not_a_measured_plateau(self):
        (samples, scale), _, _ = self.execute([None, None])
        self.assertNotIn('daemon.residentSetPlateau', samples)
        self.assertIn('daemon.residentSetPlateau', scale['unmeasured'])
        self.assertIn('daemon.residentSetSteady', scale['unmeasured'])

    def test_exit_before_sample_never_reads_reused_pid(self):
        result, records, count = self.execute([100.], polls=[1])
        self.assertIsNone(result)
        self.assertEqual(count, 0)
        invalid = next(record for record in records if record['kind'] == 'idleResources')
        self.assertEqual(invalid['status'], 'INVALID')
        self.assertEqual(invalid['processId'], 12345)

    def test_exit_during_sample_preserves_but_does_not_accept_values(self):
        result, records, count = self.execute([100.], polls=[None, 1])
        self.assertIsNone(result)
        self.assertEqual(count, 1)
        invalid = next(record for record in records if record['kind'] == 'idleResources')
        self.assertEqual(invalid['residentSetBytes'], 100.)
        self.assertEqual(invalid['status'], 'INVALID')
        partial = next(record for record in records if record.get('status') == 'PARTIAL')
        self.assertEqual(partial['samples']['daemon.residentSetPlateau'], [])

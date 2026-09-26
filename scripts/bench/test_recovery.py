import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, patch

from . import clocks, harness, recovery
from .__main__ import build_parser


class RecoveryTests(unittest.TestCase):
    def record(self, root, state="preflight", timeline=None):
        job = root / "jobs-state/jobs/job-recovery-00000"
        job.mkdir(parents=True, exist_ok=True)
        (job / "job-record.json").write_text(json.dumps({
            "jobID": job.name, "state": state, "timeline": timeline or [],
        }))
        return job

    def manifest(self):
        return {"jobCount": 1, "workload": "journal", "journalEventCount": 2}

    def test_actual_input_count_and_sequence_are_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            job = self.record(root)
            journal = job / "journal.jsonl"
            journal.write_text(''.join(json.dumps({"sequence": i, "jobId": job.name}) + '\n' for i in range(2)))
            self.assertEqual(recovery.validate_input(root, self.manifest())["actualJournalEventCount"], 2)
            for data in [journal.read_text()[:-1], journal.read_text().splitlines()[0] + '\n', journal.read_text().replace('"sequence": 1', '"sequence": 9')]:
                journal.write_text(data)
                with self.assertRaises(recovery.RecoveryFailed):
                    recovery.validate_input(root, self.manifest())

    def test_health_and_correct_page_without_recovery_marker_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            self.record(root)
            client = MagicMock()
            client.__enter__.return_value.call.return_value = {
                "items": [{"jobId": "job-recovery-00000", "state": "preflight"}], "nextCursor": None,
            }
            with patch.object(recovery.control, "ControlClient", return_value=client):
                with self.assertRaisesRegex(recovery.RecoveryFailed, "marker"):
                    recovery.verify_completed(MagicMock(), root, self.manifest(), clocks.Deadline(10))
                self.record(root, timeline=["recovered: journal clean"])
                result = recovery.verify_completed(MagicMock(), root, self.manifest(), clocks.Deadline(10))
                self.assertEqual(result["recoveryMarkers"], 1)

    def test_incomplete_duplicate_wrong_state_and_repeated_cursor_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            self.record(root, timeline=["recovered: journal clean"])
            row = {"jobId": "job-recovery-00000", "state": "preflight"}
            for page in [
                {"items": []}, {"items": [row, row]},
                {"items": [{**row, "state": "waitingForRecovery"}]},
                {"items": [row], "nextCursor": "same"},
            ]:
                client = MagicMock()
                client.__enter__.return_value.call.return_value = page
                with patch.object(recovery.control, "ControlClient", return_value=client):
                    with self.assertRaises(recovery.RecoveryFailed):
                        recovery.verify_completed(MagicMock(), root, self.manifest(), clocks.Deadline(10))

    def test_expired_deadline_never_connects(self):
        deadline = MagicMock()
        deadline.expired.return_value = True
        with patch.object(recovery.control, "ControlClient") as client:
            with self.assertRaisesRegex(recovery.RecoveryFailed, "timed out"):
                recovery.verify_completed(MagicMock(), pathlib.Path('/unused'), self.manifest(), deadline)
            client.assert_not_called()

    def test_failed_seed_timeout_start_and_verification_always_clean_up(self):
        for stage, error in [
            ("seed", recovery.RecoveryFailed("bad workload")),
            ("seed", subprocess.TimeoutExpired("seed", 300)),
            ("start", harness.DaemonStartFailed("recovery failed")),
            ("verify", recovery.RecoveryFailed("timeout")),
        ]:
            root = harness.temporary_state_directory()
            runtime = MagicMock()
            runtime.__enter__.return_value = runtime
            with patch.object(harness, "temporary_state_directory", return_value=root), \
                 patch.object(harness, "IsolatedRuntime", return_value=runtime), \
                 patch.object(recovery, "seed", side_effect=error if stage == "seed" else None, return_value=self.manifest()), \
                 patch.object(recovery, "validate_input", return_value={}), \
                 patch.object(recovery, "verify_completed", side_effect=error if stage == "verify" else None):
                if stage == "start":
                    runtime.start.side_effect = error
                with self.assertRaises(type(error)):
                    recovery.measure(pathlib.Path('/daemon'), pathlib.Path('/soak'), "journal")
                self.assertFalse(root.exists())
                if stage in {"start", "verify"}:
                    runtime.__exit__.assert_called_once()

    def test_opt_in_parser_and_invalid_workload(self):
        args = build_parser().parse_args(['capture', '--daemon', '/usr/bin/true', '--soak', '/usr/bin/true', '--out-dir', '/tmp/out', '--runtime-kind', 'rust', '--recovery-only', '--recovery-samples', '5'])
        self.assertEqual(args.recovery_samples, 5)
        for workload, budget in [("other", 1), ("journal", 0), ("journal", float('nan'))]:
            with self.assertRaises(ValueError):
                recovery.measure(None, None, workload, budget)

    def test_quiet_guard_rejects_builds_and_load_four(self):
        with patch.object(harness, "assert_host_is_quiet", return_value=4.0):
            with self.assertRaises(harness.HostTooBusy):
                recovery.assert_quiet_host()
        for command in ['cargo cargo test -p arkdeck-soak', 'rustc rustc foo', 'xcodebuild xcodebuild build', 'python3 python3 scripts/ci/plan.py --run-local']:
            with patch.object(harness, "assert_host_is_quiet", return_value=1.0), \
                 patch.object(recovery.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, command)):
                with self.assertRaises(harness.HostTooBusy):
                    recovery.assert_quiet_host()

    def test_history_requires_unchanged_terminal_records(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            self.record(root, "succeeded", ["recovered: journal clean"])
            client = MagicMock()
            client.__enter__.return_value.call.return_value = {
                "items": [{"jobId": "job-recovery-00000", "state": "succeeded"}], "nextCursor": None,
            }
            with patch.object(recovery.control, "ControlClient", return_value=client):
                with self.assertRaisesRegex(recovery.RecoveryFailed, "unexpectedly"):
                    recovery.verify_completed(MagicMock(), root, {"jobCount": 1, "workload": "history"}, clocks.Deadline(10))

    def test_recovery_scale_changes_are_not_comparable(self):
        from . import compare
        from .test_compare import document
        for field in ['recoverySeedStrategy', 'recoveryFixtureVersion', 'recoveryJournalEventCount',
                      'recoveryHistoryJobCount', 'recoveryPageSize', 'recoveryTimingBoundary']:
            left = document(**{'daemon.warmStartRecovery': 10})
            right = document(**{'daemon.warmStartRecovery': 10})
            left['metrics']['daemon.warmStartRecovery']['scale'] = {field: 1}
            right['metrics']['daemon.warmStartRecovery']['scale'] = {field: 2}
            self.assertFalse(compare.compare(left, right)['passed'])

    def test_recovery_only_archives_each_attempt_and_keeps_failure(self):
        from . import metrics
        context = metrics.RunContext(daemon_executable=pathlib.Path('/daemon'),
            soak_executable=pathlib.Path('/soak'), cold_start_samples=1, ipc_samples=1,
            idle_seconds=1, calibration_samples=1, seed_seconds=1, seed_jobs_per_cycle=1,
            runtime_kind='rust', recovery_samples=2, recovery_only=True,
            recovery_require_quiet=False, recovery_recorder=MagicMock())
        with patch.object(recovery, 'measure', side_effect=[(1.0, {'workload': 'journal'}), recovery.RecoveryFailed('bad history')]), \
             patch.object(harness, 'seed_state_directory') as old_seed, \
             patch.object(recovery.FixtureSet, 'get', return_value=None):
            with self.assertRaises(recovery.RecoveryFailed):
                metrics.execute_run(context, pathlib.Path('/unused'))
            old_seed.assert_not_called()
        attempts = [call.args[0] for call in context.recovery_recorder.call_args_list]
        self.assertEqual([a['status'] for a in attempts], ['MEASURED', 'FAILED'])
        self.assertEqual(attempts[0]['workload'], 'journal')

    def test_seed_failure_and_wrong_manifest_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            with patch.object(recovery.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'bad seed')):
                with self.assertRaisesRegex(recovery.RecoveryFailed, 'seed failed'):
                    recovery.seed(pathlib.Path('/soak'), root, 'journal')
            (root / 'recovery-fixture.json').write_text('{}')
            with patch.object(recovery.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')):
                with self.assertRaisesRegex(recovery.RecoveryFailed, 'workload'):
                    recovery.seed(pathlib.Path('/soak'), root, 'journal')

    def test_template_seed_failure_cleans_registered_root(self):
        root = harness.temporary_state_directory()
        with patch.object(harness, 'temporary_state_directory', return_value=root), \
             patch.object(recovery, 'seed', side_effect=recovery.RecoveryFailed('seed failed')):
            with self.assertRaises(recovery.RecoveryFailed):
                with recovery.FixtureSet('/soak') as fixtures:
                    fixtures.get('journal')
        self.assertFalse(root.exists())

    def test_changed_template_digest_refuses_before_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            template = pathlib.Path(tmp)
            self.record(template, 'succeeded')
            manifest = {'workload': 'history', 'jobCount': 1, 'journalEventCount': 0}
            proof = recovery.validate_input(template, manifest)
            proof['inputSha256'] = '0' * 64
            root = harness.temporary_state_directory()
            with patch.object(harness, 'temporary_state_directory', return_value=root), \
                 patch.object(harness, 'IsolatedRuntime') as runtime:
                with self.assertRaisesRegex(recovery.RecoveryFailed, 'pristine'):
                    recovery.measure('/daemon', '/soak', 'history', fixture=(template, manifest, proof))
                runtime.assert_not_called()
            self.assertFalse(root.exists())

    def test_hardlinked_copy_is_rejected_before_daemon_launch(self):
        import os
        with tempfile.TemporaryDirectory() as tmp:
            template = pathlib.Path(tmp)
            self.record(template, 'succeeded')
            manifest = {'workload': 'history', 'jobCount': 1, 'journalEventCount': 0}
            proof = recovery.validate_input(template, manifest)
            original_copy = recovery.shutil.copytree
            def linked_copy(source, destination, **kwargs):
                with patch.object(recovery.shutil, 'copytree', original_copy):
                    return original_copy(source, destination, copy_function=os.link, **kwargs)
            with patch.object(recovery.shutil, 'copytree', side_effect=linked_copy), \
                 patch.object(harness, 'IsolatedRuntime') as runtime:
                with self.assertRaisesRegex(recovery.RecoveryFailed, 'writable inode'):
                    recovery.measure('/daemon', '/soak', 'history', fixture=(template, manifest, proof))
                runtime.assert_not_called()


class RealDaemonRecoveryTests(unittest.TestCase):
    """Optional integration checks; tiny workloads are correctness, never perf evidence."""
    def setUp(self):
        import os
        self.daemon = os.environ.get('BENCH_TEST_DAEMON')
        self.soak = os.environ.get('BENCH_TEST_SOAK')
        if not self.daemon or not self.soak:
            self.skipTest('set BENCH_TEST_DAEMON and BENCH_TEST_SOAK for real process checks')

    def test_both_workloads_on_real_daemon(self):
        with patch.object(recovery, 'COUNT', 20), recovery.FixtureSet(self.soak) as fixtures:
            for workload in recovery.METRICS:
                fixture = fixtures.get(workload)
                for _ in range(2):
                    elapsed, proof = recovery.measure(self.daemon, self.soak, workload, fixture=fixture)
                    self.assertGreater(elapsed, 0)
                    self.assertEqual(proof['verifiedJobs'], 1 if workload == 'journal' else 20)
                    self.assertEqual(proof['inputSha256'], fixture[2]['inputSha256'])
                    self.assertTrue(proof['copyIsolationVerified'])
                    self.assertTrue(proof['templateUnchanged'])
                self.assertEqual(recovery.validate_input(fixture[0], fixture[1])['inputSha256'], fixture[2]['inputSha256'])
        self.assertTrue(all(not root.exists() for root in fixtures.roots))

    def test_corrupt_journal_cannot_produce_a_sample_and_process_is_reaped(self):
        original_seed = recovery.seed
        captured = []
        original_runtime = harness.IsolatedRuntime
        def corrupt(soak, root, workload):
            manifest = original_seed(soak, root, workload)
            journal = root / 'jobs-state/jobs/job-recovery-00000/journal.jsonl'
            journal.write_text(journal.read_text().replace('"kind":"warning"', '"kind":"invalid"'))
            captured.append(root)
            return manifest
        instances = []
        def runtime(*args, **kwargs):
            result = original_runtime(*args, **kwargs)
            instances.append(result)
            return result
        with patch.object(recovery, 'COUNT', 20), \
             patch.object(recovery, 'seed', side_effect=corrupt), \
             patch.object(harness, 'IsolatedRuntime', side_effect=runtime):
            with self.assertRaises(harness.DaemonStartFailed):
                recovery.measure(self.daemon, self.soak, 'journal', budget_seconds=10)
        self.assertIsNone(instances[0].process)
        self.assertFalse(captured[0].exists())

class RecoveryCaptureDocumentTests(unittest.TestCase):
    def test_measured_recovery_replaces_gap_and_archives_every_run(self):
        from .__main__ import command_capture
        with tempfile.TemporaryDirectory() as tmp:
            args = build_parser().parse_args([
                'capture', '--daemon', '/usr/bin/true', '--soak', '/usr/bin/true',
                '--out-dir', tmp, '--runtime-kind', 'rust', '--recovery-only',
                '--recovery-samples', '1',
            ])
            def execute(context, root):
                context.recovery_recorder({'workload': 'journal', 'milliseconds': 10})
                return {'daemon.warmStartRecovery': [10],
                        'daemon.warmStartRecovery.history': [20],
                        'calibration.busyLoop': [1]}, {
                            'jobStoreRowCount': None, 'recoveryFixtureVersion': recovery.VERSION,
                            'recoveryJournalEventCount': 10000,
                            'recoverySamples': [{'milliseconds': 10}],
                        }
            with patch('bench.metrics.execute_run', side_effect=execute), \
                 patch.object(harness, 'wait_for_quiet_host', return_value=(1, 0)), \
                 patch.object(harness, 'load_average', return_value=(1, 1, 1)):
                self.assertEqual(command_capture(args), 0)
            document = json.loads(next(pathlib.Path(tmp).glob('perf-baseline-*.json')).read_text())
            self.assertEqual(document['metrics']['daemon.warmStartRecovery']['status'], 'MEASURED')
            self.assertEqual(document['metrics']['daemon.coldStart']['status'], 'NOT_MEASURED')
            scale = document['metrics']['daemon.warmStartRecovery']['scale']
            self.assertNotIn('jobStoreRowCount', scale)
            self.assertNotIn('recoverySamples', scale)
            attempts = [json.loads(line) for line in next(pathlib.Path(tmp).glob('recovery-samples-*.jsonl')).read_text().splitlines()]
            self.assertEqual([a['runIndex'] for a in attempts], [0, 1, 2])
            self.assertEqual(len(attempts[0]['toolchain']['daemonSha256']), 64)

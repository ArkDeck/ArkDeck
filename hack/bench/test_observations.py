"""Evidence survives failures without entering measured intervals."""
import hashlib
import json
import pathlib
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from . import __main__ as main
from . import harness, metrics, observations, recovery, clocks


class SeedEvidenceTests(unittest.TestCase):
    def test_process_logs_are_bounded_and_prefix_hash_is_explicit(self):
        records = []
        result = observations.seed_process(
            [sys.executable, '-c', "import sys;sys.stdout.write('x'*100000);sys.stderr.write('bad');sys.exit(3)"],
            10, records.append)
        self.assertEqual(result.returncode, 3)
        self.assertEqual(len(result.stdout), observations.LOG_LIMIT)
        evidence = records[0]
        self.assertEqual(evidence['stdout']['byteCount'], 100000)
        self.assertTrue(evidence['stdout']['truncated'])
        self.assertEqual(evidence['stdout']['hashScope'], 'prefix')
        self.assertEqual(evidence['stderr']['text'], 'bad')

    def test_timeout_records_available_logs_after_child_is_reaped(self):
        records = []
        with self.assertRaises(subprocess.TimeoutExpired):
            observations.seed_process([sys.executable, '-c', 'import time;time.sleep(30)'], .05, records.append)
        self.assertTrue(records[0]['timedOut'])
        self.assertIsNone(records[0]['returnCode'])

    def document(self):
        return {'schemaVersion': 'arkdeck-runtime-soak/v1', 'phase': 'completed',
                'jobStates': {'succeeded': 7, 'cancelled': 3}, 'terminalJobCount': 10,
                'activeJobCount': 0, 'verifiedArtifactEvidenceJobCount': 7,
                'stateFileCount': 22, 'stateByteCount': 1234, 'journalCount': 10, 'journalByteCount': 100}

    def test_actual_counts_and_exact_input_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); raw = json.dumps(self.document()).encode() + b'\n'
            (root/'runtime-soak-metrics.json').write_bytes(raw); records = []
            observations.seed_metrics(root, records.append)
        self.assertEqual(records[0]['text'].encode(), raw)
        self.assertEqual(records[0]['sha256'], hashlib.sha256(raw).hexdigest())
        self.assertEqual(records[1]['observedTotalJobCount'], 10)
        self.assertNotIn('jobStoreRowCount', records[1])

    def test_bad_phase_counts_and_oversize_are_refused(self):
        bad = []
        for key, value in [('phase', 'running'), ('terminalJobCount', 9), ('activeJobCount', 1),
                           ('verifiedArtifactEvidenceJobCount', True)]:
            doc = self.document(); doc[key] = value; bad.append(json.dumps(doc).encode())
        bad.append(b'{"phase":"running","phase":"completed"}')
        bad.append(b'x' * (observations.METRICS_LIMIT + 1))
        for raw in bad:
            with self.subTest(size=len(raw)), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory); (root/'runtime-soak-metrics.json').write_bytes(raw)
                records = []
                with self.assertRaises(ValueError): observations.seed_metrics(root, records.append)
                self.assertEqual(records[-1]['status'], 'FAILED')


class PhaseEvidenceTests(unittest.TestCase):
    def test_partial_ipc_retains_only_measured_values_and_stops(self):
        records = []; inside = False
        def record(entry):
            self.assertFalse(inside, 'recording inside a measurement')
            records.append(json.loads(json.dumps(entry)))
        def calibration():
            nonlocal inside
            inside = True
            inside = False
            return 2.0
        calls = 0
        def timed(*args):
            nonlocal inside, calls
            inside = True; calls += 1
            try:
                if calls == 2: raise OSError('IPC failed')
                return {}, .003
            finally: inside = False
        context = metrics.RunContext(daemon_executable=pathlib.Path('/daemon'), soak_executable=pathlib.Path('/soak'),
            cold_start_samples=0, ipc_samples=3, idle_seconds=1, calibration_samples=2,
            seed_seconds=6, seed_jobs_per_cycle=10, capture_recorder=record)
        with mock.patch.object(harness, 'seed_state_directory', return_value=subprocess.CompletedProcess([],0,'','')), \
             mock.patch.object(harness, 'IsolatedRuntime') as factory, \
             mock.patch.object(metrics, 'calibration_sample', side_effect=calibration):
            runtime = factory.return_value
            client = runtime.client.return_value.__enter__.return_value
            client.call.return_value = {'items': [{'jobId': 'one'}]}
            client.timed_call.side_effect = timed
            with self.assertRaises(OSError): metrics.execute_run(context, pathlib.Path('/state'))
            runtime.stop.assert_called_once()
        partial = records[-1]
        self.assertEqual(partial['status'], 'PARTIAL')
        self.assertFalse(partial['baselineEligible'])
        self.assertEqual(partial['samples']['calibration.busyLoop'], [2.,2.])
        self.assertEqual(partial['samples']['ipc.health'], [3.])
        self.assertEqual(partial['samples']['ipc.jobList'], [])
        self.assertEqual(partial['scale']['jobStoreRowCount'], 1)

    def test_load_refusal_does_not_claim_process_scan(self):
        with mock.patch.object(harness, 'load_average', return_value=(4.48,0,0)), \
             mock.patch.object(harness, 'cpu_count', return_value=8), \
             mock.patch.object(recovery.subprocess, 'run') as scan:
            with self.assertRaises(harness.HostTooBusy) as raised: recovery.assert_quiet_host()
        scan.assert_not_called()
        self.assertEqual(raised.exception.facts['oneMinuteLoad'],4.48)
        self.assertEqual(raised.exception.facts['loadThreshold'],4)
        self.assertFalse(raised.exception.facts['processCheckPerformed'])
        self.assertIsNone(raised.exception.facts['conflictingBuildProcesses'])

    def test_completed_run_survives_later_refusal_with_cleaned_roots(self):
        roots = []; calls = 0
        def execute(context, root):
            nonlocal calls
            roots.append(root); calls += 1
            if calls == 2: raise harness.HostTooBusy('busy', facts={'oneMinuteLoad':4.5})
            return {'ipc.health':[1.]}, {'jobStoreRowCount':7}
        with tempfile.TemporaryDirectory() as directory:
            out = pathlib.Path(directory)
            with mock.patch.object(metrics,'execute_run',side_effect=execute), \
                 mock.patch.object(main,'_toolchain_facts',return_value={}), \
                 mock.patch.object(harness,'wait_for_quiet_host',return_value=(1.,0.)), \
                 mock.patch.object(harness,'load_average',return_value=(1.,1.,1.)):
                code = main.main(['capture','--daemon',main.__file__,'--soak',main.__file__,
                                  '--runtime-kind','rust','--out-dir',str(out)])
            self.assertEqual(code,1)
            self.assertFalse(list(out.glob('perf-baseline-*.json')))
            failure = json.loads(next(out.glob('capture-failed-*.json')).read_text())
            self.assertFalse(failure['baselineEligible'])
            self.assertEqual(len(failure['completedRuns']),1)
            rows = [json.loads(x) for x in next(out.glob('capture-samples-*.jsonl')).read_text().splitlines()]
            checkpoint = next(x for x in rows if x['kind']=='runCheckpoint')
            self.assertEqual(checkpoint['samples']['ipc.health'],[1.])
            self.assertEqual(checkpoint['scale']['jobStoreRowCount'],7)
            self.assertTrue(all(not root.exists() for root in roots))
            self.assertTrue(all(x['rootAbsent'] for x in rows if x['kind']=='stateCleanup'))
            self.assertTrue(all(x['captureObservationVersion']==observations.VERSION for x in rows))


class FailureBoundaryTests(unittest.TestCase):
    def test_metrics_symlink_and_fifo_are_refused_without_blocking(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            target = root/'runtime-soak-metrics.json'
            (root/'other').write_text('{}')
            target.symlink_to(root/'other')
            with self.assertRaises(OSError): observations.seed_metrics(root, lambda e: None)
            target.unlink(); os.mkfifo(target)
            with self.assertRaisesRegex(ValueError, 'regular file'):
                observations.seed_metrics(root, lambda e: None)

    def test_seed_timeout_still_writes_partial_and_removes_state(self):
        with tempfile.TemporaryDirectory() as directory:
            out = pathlib.Path(directory); roots = []
            def seed(soak, root, *args, recorder):
                roots.append(root)
                recorder({'kind':'seedProcess','timedOut':True,'returnCode':None})
                raise subprocess.TimeoutExpired(['soak'],301)
            with mock.patch.object(harness,'seed_state_directory',side_effect=seed), \
                 mock.patch.object(main,'_toolchain_facts',return_value={}), \
                 mock.patch.object(harness,'wait_for_quiet_host',return_value=(1.,0.)), \
                 mock.patch.object(recovery,'assert_quiet_host',return_value={}), \
                 mock.patch.object(metrics,'calibration_sample',return_value=2.), \
                 mock.patch.object(harness,'IsolatedRuntime') as runtime:
                code=main.main(['capture','--daemon',main.__file__,'--soak',main.__file__,
                               '--runtime-kind','rust','--out-dir',str(out)])
            self.assertEqual(code,1);runtime.assert_not_called()
            self.assertTrue(all(not root.exists() for root in roots))
            failure=json.loads(next(out.glob('capture-failed-*.json')).read_text())
            self.assertFalse(failure['baselineEligible'])
            rows=[json.loads(x) for x in next(out.glob('capture-samples-*.jsonl')).read_text().splitlines()]
            partial=next(x for x in rows if x.get('status')=='PARTIAL')
            self.assertEqual(partial['samples']['calibration.busyLoop'],[2.]*200)
            self.assertEqual(partial['samples']['ipc.health'],[])

    def test_admission_refusal_is_recorded_before_any_root_or_measurement(self):
        with tempfile.TemporaryDirectory() as directory:
            out=pathlib.Path(directory)
            error=harness.HostTooBusy('busy',facts={'oneMinuteLoad':4.9,'loadThreshold':4.,'processCheckPerformed':False})
            with mock.patch.object(main,'_toolchain_facts',return_value={}), \
                 mock.patch.object(harness,'wait_for_quiet_host',side_effect=error), \
                 mock.patch.object(harness,'temporary_state_directory') as root, \
                 mock.patch.object(metrics,'execute_run') as run:
                code=main.main(['capture','--daemon',main.__file__,'--soak',main.__file__,'--out-dir',str(out)])
            self.assertEqual(code,1);root.assert_not_called();run.assert_not_called()
            failure=json.loads(next(out.glob('capture-failed-*.json')).read_text())
            self.assertEqual(failure['phase'],'run-admission')
            self.assertEqual(failure['completedRuns'],[])
            self.assertIsNone(failure['quietHostFacts']['conflictingBuildProcesses'])

    def test_seed_log_files_close_even_if_recording_fails(self):
        opened = []; original = tempfile.TemporaryFile
        def open_log():
            stream = original(); opened.append(stream); return stream
        with mock.patch.object(observations.tempfile, 'TemporaryFile', side_effect=open_log):
            with self.assertRaisesRegex(OSError, 'evidence full'):
                observations.seed_process([sys.executable, '-c', 'print("seed")'], 10,
                                          mock.Mock(side_effect=OSError('evidence full')))
        self.assertEqual(len(opened), 2)
        self.assertTrue(all(stream.closed for stream in opened))

    def test_failed_removal_is_not_recorded_as_clean(self):
        import shutil
        roots=[]
        with tempfile.TemporaryDirectory() as directory:
            out=pathlib.Path(directory)
            def execute(context, root):
                roots.append(root)
                raise metrics.RunFailed('seed failed')
            try:
                with mock.patch.object(main,'_toolchain_facts',return_value={}), \
                     mock.patch.object(harness,'wait_for_quiet_host',return_value=(1.,0.)), \
                     mock.patch.object(metrics,'execute_run',side_effect=execute), \
                     mock.patch.object(main.shutil,'rmtree'):
                    code=main.main(['capture','--daemon',main.__file__,'--soak',main.__file__,'--out-dir',str(out)])
                self.assertEqual(code,1)
                rows=[json.loads(x) for x in next(out.glob('capture-samples-*.jsonl')).read_text().splitlines()]
                cleanup=next(x for x in rows if x['kind']=='stateCleanup')
                self.assertFalse(cleanup['rootAbsent'])
            finally:
                for root in roots: shutil.rmtree(root)

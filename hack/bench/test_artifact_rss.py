"""Artifact RSS collection: portable branch rules and native Windows reads."""
import os
import pathlib
import subprocess
import sys
import unittest
from unittest.mock import call, patch

from . import artifact, windows_host


def native_facts(value=4096, threads=1):
    return {'workingSetBytes': value, 'threadCount': threads, 'privateBytes': 999999}


class ArtifactRssRulesTests(unittest.TestCase):
    def sampler(self):
        with patch.object(artifact.os, 'getpid', return_value=202), \
                patch.object(artifact.clocks, 'awake_seconds', return_value=10.):
            return artifact.RssSampler(101)

    def test_windows_reads_both_expected_pids_in_bytes_without_ps(self):
        sampler = self.sampler()
        with patch.object(artifact.harness, 'on_windows', return_value=True), \
                patch.object(windows_host, 'process_resources',
                             side_effect=[native_facts(12345), native_facts(67890)]) as read, \
                patch.object(artifact.subprocess, 'run') as ps, \
                patch.object(artifact.clocks, 'awake_seconds', return_value=10.25):
            sampler.sample()
        self.assertEqual(read.call_args_list, [call(101), call(202)])
        ps.assert_not_called()
        self.assertEqual(sampler.rows, [{'elapsedSeconds': .25, 'daemonBytes': 12345,
                                        'clientBytes': 67890, 'residentSetSource': 'WorkingSetSize'}])

    def test_failed_expected_pid_invalidates_the_complete_sample_and_summary(self):
        for failed_index in (0, 1):
            sampler = self.sampler()
            reads = [native_facts(4096), native_facts(8192)]
            reads[failed_index] = PermissionError('cannot read expected process')
            with self.subTest(failed_index=failed_index), \
                    patch.object(artifact.harness, 'on_windows', return_value=True), \
                    patch.object(windows_host, 'process_resources', side_effect=reads), \
                    patch.object(artifact.subprocess, 'run') as ps:
                sampler.sample()
            ps.assert_not_called()
            self.assertEqual(sampler.rows[0]['unmeasured'], 'PermissionError')
            self.assertEqual(sampler.rows[0]['residentSetSource'], 'WorkingSetSize')
            self.assertNotIn('daemonBytes', sampler.rows[0])
            self.assertNotIn('clientBytes', sampler.rows[0])
            sampler.rows.extend([{'daemonBytes': 4096, 'clientBytes': 8192}])
            summary = artifact.rss_summary(sampler.rows)
            self.assertTrue(all('unmeasured' in summary[key] for key in ('daemonBytes', 'clientBytes')))

    def test_missing_invalid_or_vanished_native_process_is_unmeasured(self):
        candidates = [{}, native_facts(threads=None)]
        candidates.extend(native_facts(value) for value in (None, 0, -1, True, 1.5, '4096'))
        for facts in candidates:
            sampler = self.sampler()
            with self.subTest(facts=facts), \
                    patch.object(artifact.harness, 'on_windows', return_value=True), \
                    patch.object(windows_host, 'process_resources', return_value=facts):
                sampler.sample()
            self.assertIn('unmeasured', sampler.rows[0])
            self.assertNotIn('daemonBytes', sampler.rows[0])
            self.assertNotIn('clientBytes', sampler.rows[0])

    def test_unix_keeps_the_exact_ps_command_kibibytes_and_row_shape(self):
        sampler = self.sampler()
        result = subprocess.CompletedProcess([], 0, '101 12\n202 34\n')
        with patch.object(artifact.harness, 'on_windows', return_value=False), \
                patch.object(artifact.subprocess, 'run', return_value=result) as ps, \
                patch.object(windows_host, 'process_resources') as native, \
                patch.object(artifact.clocks, 'awake_seconds', return_value=10.25):
            sampler.sample()
        ps.assert_called_once_with(['ps', '-o', 'pid=,rss=', '-p', '101,202'],
                                   capture_output=True, text=True, timeout=5, check=True)
        native.assert_not_called()
        self.assertEqual(sampler.rows, [{'elapsedSeconds': .25, 'daemonBytes': 12 * 1024,
                                        'clientBytes': 34 * 1024}])

    def test_unix_missing_pid_and_ps_failure_keep_the_original_unmeasured_shape(self):
        for result in (subprocess.CompletedProcess([], 0, '101 12\n'),
                       subprocess.CalledProcessError(1, 'ps')):
            sampler = self.sampler()
            with self.subTest(result=result), \
                    patch.object(artifact.harness, 'on_windows', return_value=False), \
                    patch.object(artifact.subprocess, 'run', **(
                        {'side_effect': result} if isinstance(result, Exception) else {'return_value': result})), \
                    patch.object(artifact.clocks, 'awake_seconds', return_value=10.25):
                sampler.sample()
            self.assertEqual(sampler.rows, [{'elapsedSeconds': .25,
                                            'unmeasured': 'CalledProcessError' if isinstance(result, Exception) else 'KeyError'}])


@unittest.skipUnless(windows_host.IS_WINDOWS, 'reads native Windows process counters')
class NativeWindowsArtifactRssTests(unittest.TestCase):
    def test_owned_child_and_client_produce_usable_native_rss_then_exit_is_unmeasured(self):
        with subprocess.Popen([sys.executable, '-X', 'utf8', '-c',
                               'import sys; print("ready", flush=True); sys.stdin.buffer.read(1)'],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
            self.assertEqual(child.stdout.readline(), b'ready\r\n')
            sampler = artifact.RssSampler(child.pid)
            sampler.start()
            rows = sampler.stop()
            self.assertFalse(sampler.thread.is_alive())
            self.assertGreaterEqual(len(rows), 1)
            self.assertTrue(all(row.get('daemonBytes', 0) > 0 and row.get('clientBytes', 0) > 0 for row in rows))
            self.assertTrue(all(row['residentSetSource'] == 'WorkingSetSize' for row in rows))
            self.assertTrue(all('unmeasured' not in value for value in artifact.rss_summary(rows).values()))
            child.communicate(input=b'x', timeout=5)
            self.assertEqual(child.returncode, 0)
            sampler.sample()
            self.assertIn('unmeasured', sampler.rows[-1])
            self.assertTrue(all('unmeasured' in value for value in artifact.rss_summary(sampler.rows).values()))

    def test_real_artifact_read_reports_native_daemon_and_client_samples(self):
        daemon = os.environ.get('BENCH_TEST_DAEMON')
        soak = os.environ.get('BENCH_TEST_ARTIFACT_SOAK')
        if not daemon or not soak:
            self.skipTest('set BENCH_TEST_DAEMON and BENCH_TEST_ARTIFACT_SOAK for opt-in 1 MiB integration')
        records = []
        environment = {key: value for key, value in os.environ.items()
                       if not key.upper().startswith(('ARKDECK_', 'OHOS_HDC_'))}
        with patch.dict(os.environ, environment, clear=True):
            elapsed, proof = artifact.measure(pathlib.Path(daemon), pathlib.Path(soak), 1024 * 1024,
                                              records.append, require_quiet=False)
        self.assertGreater(elapsed, 0)
        evidence = proof['artifactEvidence']
        self.assertEqual(evidence['payloadBytes'], 1024 * 1024)
        self.assertEqual(evidence['sha256'], proof['artifactArchiveSha256'])
        samples = evidence['rssSamples']
        self.assertTrue(samples)
        self.assertTrue(all(row['residentSetSource'] == 'WorkingSetSize' for row in samples))
        self.assertTrue(all(row.get('daemonBytes', 0) > 0 and row.get('clientBytes', 0) > 0 for row in samples))
        self.assertTrue(all('unmeasured' not in value for value in evidence['rssSummary'].values()))
        self.assertEqual(next(row['samples'] for row in records if row['kind'] == 'artifactRss'), samples)


if __name__ == '__main__':
    unittest.main()

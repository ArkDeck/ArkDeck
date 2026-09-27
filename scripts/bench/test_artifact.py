"""Small fixture and typed range regressions; never default target-size I/O."""
import base64
import gzip
import hashlib
import io
import pathlib
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import Mock, patch
from . import artifact, artifact_fixture, metrics
from .test_compare import document, scaled
from . import compare


def receipt(data=b'abcd'):
    return {'owner': {'kind': 'import', 'id': 'imp-test'}, 'artifactId': 'ART-fixture',
            'artifactDigest': hashlib.sha256(data).hexdigest()}


def page(data=b'abcd', offset=0, total=4):
    return {'artifactId': 'ART-fixture', 'artifactDigest': receipt()['artifactDigest'],
            'base64': base64.b64encode(data).decode(), 'byteCount': len(data),
            'offset': offset, 'nextOffset': offset+len(data), 'totalByteCount': total,
            'eof': offset+len(data)==total}


class ArtifactFixtureTests(unittest.TestCase):
    def test_small_fixture_exact_stream_digest_and_existing_member_set(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)/'fixture.tar.gz'
            facts = artifact_fixture.generate(path, 1024*1024)
            data = path.read_bytes()
            self.assertEqual(len(data), 1024*1024)
            self.assertEqual(hashlib.sha256(data).hexdigest(), facts['sha256'])
            # Only the 1 MiB correctness scale is decompressed in this test.
            with tarfile.open(fileobj=io.BytesIO(gzip.decompress(data)), mode='r:') as archive:
                self.assertEqual(len(archive.getmembers()), 17)
                self.assertEqual(archive.getmember('userdata.img').size, facts['userdataBytes'])
                self.assertIn(b'const.ohos.fullname=', archive.extractfile('system.img').read())
            with self.assertRaises(FileExistsError):
                artifact_fixture.generate(path, 1024*1024)

    def test_invalid_scale_refuses_before_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)/'fixture.tar.gz'
            with self.assertRaises(ValueError):
                artifact_fixture.generate(path, 1024)
            self.assertFalse(path.exists())

    def test_reserve_includes_three_copies_plus_four_gib(self):
        count = 128*1024*1024
        with patch.object(artifact.shutil, 'disk_usage', return_value=Mock(free=4*1024**3+2*count)):
            with self.assertRaises(ValueError):
                artifact.check_disk('/fixture', count)


class ArtifactRangeTests(unittest.TestCase):
    def test_exact_full_and_partial_ranges(self):
        self.assertEqual(artifact.validate_page(page(), receipt(), 0, 4), b'abcd')
        self.assertEqual(artifact.validate_page(page(b'ab', 0, 4), receipt(), 0, 4), b'ab')

    def test_wrong_identity_digest_offsets_counts_eof_and_encoding_refuse(self):
        changes = [('artifactId','wrong'),('artifactDigest','0'*64),('byteCount',True),
                   ('byteCount',3),('offset',1),('nextOffset',3),('totalByteCount',5),
                   ('eof',False),('eof',1),('base64','not-base64'),('base64','YWJjZA===')]
        for key,value in changes:
            candidate = page(); candidate[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                artifact.validate_page(candidate, receipt(), 0, 4)
        candidate = page(); candidate['extra'] = 1
        with self.assertRaises(ValueError):
            artifact.validate_page(candidate, receipt(), 0, 4)

    def test_missing_rss_does_not_become_zero_or_peak_claim(self):
        result = artifact.rss_summary([{'unmeasured':'ps failed'}])
        self.assertIn('unmeasured', result['daemonBytes'])

    def test_failed_publication_preserves_process_facts_and_cleans_private_root(self):
        record = Mock()
        root = pathlib.Path('/fixture')
        with patch.object(artifact.harness, 'temporary_state_directory', return_value=root), \
             patch.object(artifact, 'check_disk', return_value={}), \
             patch.object(artifact_fixture, 'generate', return_value={'sha256':'a'*64}), \
             patch.object(artifact.subprocess, 'run', return_value=subprocess.CompletedProcess([], 9, '', 'validator refused')), \
             patch.object(artifact.shutil, 'rmtree') as cleanup:
            with self.assertRaises(ValueError):
                artifact.measure('/daemon', '/soak', 1024*1024, record, False)
            cleanup.assert_called_once_with(root)
        entries = [call.args[0] for call in record.call_args_list]
        process = next(e for e in entries if e['kind']=='artifactSeedProcess')
        self.assertEqual(process['returnCode'], 9)
        self.assertEqual(process['stderr']['text'], 'validator refused')
        self.assertEqual(entries[-1]['status'], 'FAILED')

    def test_changed_scale_or_boundary_refuses_comparison(self):
        fields = {'artifactPayloadBytes':128*1024*1024, 'artifactOwnerKind':'import',
                  'artifactImportKind':'flash-bundle', 'artifactPageBytes':4*1024*1024,
                  'artifactTimingBoundary':artifact.TIMING, 'artifactFixtureVersion':artifact_fixture.VERSION,
                  'artifactRssIntervalSeconds':.2, 'artifactCachePolicy':'fresh-owner-first-read-no-OS-cache-eviction'}
        for field in fields:
            other = dict(fields); other[field] = 'different'
            result = compare.compare(scaled(document(a=1), fields), scaled(document(a=1), other))
            self.assertFalse(result['passed'], field)

    def test_default_context_never_enables_large_io(self):
        context = metrics.RunContext(daemon_executable=pathlib.Path('/daemon'),
            soak_executable=pathlib.Path('/soak'), cold_start_samples=1, ipc_samples=1,
            idle_seconds=1, calibration_samples=1, seed_seconds=1, seed_jobs_per_cycle=1)
        self.assertEqual(context.artifact_samples, 0)


class RealArtifactOwnerTests(unittest.TestCase):
    def test_small_real_owner_publication_and_typed_read(self):
        import os
        daemon = os.environ.get('BENCH_TEST_DAEMON')
        soak = os.environ.get('BENCH_TEST_ARTIFACT_SOAK')
        if not daemon or not soak:
            self.skipTest('set BENCH_TEST_DAEMON and BENCH_TEST_ARTIFACT_SOAK for opt-in 1 MiB integration')
        observations = []
        elapsed, proof = artifact.measure(daemon, soak, 1024*1024, observations.append, False)
        self.assertGreater(elapsed, 0)
        self.assertEqual(proof['artifactOwnerKind'], 'import')
        self.assertEqual(proof['artifactEvidence']['payloadBytes'], 1024*1024)
        self.assertEqual(proof['artifactEvidence']['actualPageCount'], 1)
        self.assertTrue(any(row['kind']=='artifactReadComplete' for row in observations))


class ArtifactTransportTests(unittest.TestCase):
    def client(self, chunks, deadline=None):
        from . import control
        client = control.ControlClient('/fixture')
        client._socket = Mock()
        client._socket.recv.side_effect = chunks
        client.configure_measurement(deadline, capture_failure=True)
        return client

    def test_truncated_and_invalid_json_preserve_received_bytes_after_close(self):
        for chunks in ([b'{"id":', b''], [b'not-json\n'], [b'{}\n']):
            client = self.client(chunks)
            with self.assertRaises(Exception):
                client._exchange({'id':'test'})
            client.close()
            raw = b''.join(chunks)
            evidence = client.failure_evidence
            self.assertEqual(evidence['receivedByteCount'], len(raw))
            self.assertEqual(evidence['receivedSha256'], hashlib.sha256(raw).hexdigest())
            self.assertEqual(base64.b64decode(evidence['prefixBase64']), raw)

    def test_progressing_fragments_cannot_extend_total_deadline(self):
        from . import control
        deadline = Mock(budget_seconds=1)
        deadline.remaining_seconds.side_effect = [1., .8, .5, .2, -.1, -.1]
        client = self.client([b'a', b'b', b'never'], deadline)
        with self.assertRaisesRegex(control.ControlError, 'deadline'):
            client._exchange({'id':'test'})
        self.assertEqual(client._socket.recv.call_count, 2)
        self.assertEqual(client.failure_evidence['receivedByteCount'], 2)
        self.assertEqual(client.failure_evidence['phase'], 'receive')

    def test_failure_prefix_is_bounded_but_hash_covers_all_received_bytes(self):
        raw = b'x'*65536+b'y'*65536
        client = self.client([raw[:65536], raw[65536:], b''])
        with self.assertRaises(Exception):
            client._exchange({'id':'test'})
        facts = client.failure_evidence
        self.assertEqual(facts['receivedByteCount'], len(raw))
        self.assertEqual(facts['receivedSha256'], hashlib.sha256(raw).hexdigest())
        self.assertEqual(len(base64.b64decode(facts['prefixBase64'])), 65536)
        self.assertTrue(facts['truncated'])

    def test_transport_timeout_preserves_partial_frame(self):
        client = self.client([b'{', TimeoutError('idle')])
        with self.assertRaises(Exception):
            client._exchange({'id':'test'})
        self.assertEqual(client.failure_evidence['receivedByteCount'], 1)


class ArtifactReadLoopTests(unittest.TestCase):
    def runtime(self, response):
        from unittest.mock import MagicMock
        runtime = Mock()
        client = MagicMock()
        client.__enter__.return_value = client
        client.failure_evidence = None
        client.call.return_value = response
        runtime.client.return_value = client
        return runtime, client

    def test_final_digest_failure_retains_page_and_stops_sampler(self):
        candidate = page(b'zzzz')
        runtime, client = self.runtime(candidate)
        rows = []
        with patch.object(artifact, 'RssSampler') as sampler:
            sampler.return_value.stop.return_value = []
            with self.assertRaisesRegex(ValueError, 'final digest'):
                artifact.read_all(runtime, receipt(), 4, rows.append)
            sampler.return_value.stop.assert_called_once()
        self.assertTrue(any(r['kind']=='artifactPage' for r in rows))
        # Regression for the real second smoke failure: offset is a JSON number.
        self.assertIs(type(client.call.call_args.args[1]['offset']), int)

    def test_expired_budget_sends_no_page_and_stops_sampler(self):
        runtime, client = self.runtime(page())
        with patch.object(artifact, 'RssSampler') as sampler, patch.object(artifact.clocks, 'Deadline') as deadline:
            deadline.return_value.expired.return_value = True
            sampler.return_value.stop.return_value = []
            with self.assertRaises(TimeoutError):
                artifact.read_all(runtime, receipt(), 4, lambda row: None)
            client.call.assert_not_called()
            sampler.return_value.stop.assert_called_once()

    def test_publication_timeout_preserves_partial_output_and_cleans_root(self):
        root = pathlib.Path('/fixture'); rows=[]
        with patch.object(artifact.harness, 'temporary_state_directory', return_value=root), \
             patch.object(artifact, 'check_disk', return_value={}), \
             patch.object(artifact_fixture, 'generate', return_value={'sha256':'a'*64}), \
             patch.object(artifact.subprocess, 'run', side_effect=subprocess.TimeoutExpired('soak',600,output=b'partial',stderr=b'error')), \
             patch.object(artifact.shutil, 'rmtree') as cleanup:
            with self.assertRaises(subprocess.TimeoutExpired):
                artifact.measure('/daemon','/soak',1024*1024,rows.append,False)
            cleanup.assert_called_once_with(root)
        process=next(row for row in rows if row['kind']=='artifactSeedProcess')
        self.assertTrue(process['timedOut'])
        self.assertEqual(process['stdout']['text'],'partial')

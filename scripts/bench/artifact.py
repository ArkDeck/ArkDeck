"""Typed InputArtifact read measurement; includes production per-page verification."""
from __future__ import annotations

import base64
import hashlib
import json
import os
import shutil
import subprocess
import threading

from . import artifact_fixture, clocks, control, harness, journal, recovery

PAGE_BYTES = 4 * 1024 * 1024
RESERVE_BYTES = 4 * 1024 ** 3
READ_BUDGET = 600
TIMING = 'first-read-through-complete-client-digest-v1'
RSS_INTERVAL = .2


def definition(size):
    return ('milliseconds', 'I.2 large Artifact paged base64',
            f'complete {size}-byte flash-bundle InputArtifact read and client digest; includes server verification')


def metric_id(size):
    return 'artifact.pagedRead' if size == 128 * artifact_fixture.MIB else f'artifact.pagedRead.{size // artifact_fixture.MIB}MiB'


DEFINITIONS = {metric_id(size): definition(size) for size in artifact_fixture.SIZES}

def check_disk(root, count):
    # Source + upload staging + immutable publication, conservatively all at once.
    required = RESERVE_BYTES + 3 * count + 64 * 1024 * 1024
    free = shutil.disk_usage(root).free
    if free < required:
        raise ValueError(f'artifact fixture needs {required} free bytes including 4 GiB reserve; found {free}')
    return {'freeBytes': free, 'requiredFreeBytes': required, 'reserveBytes': RESERVE_BYTES}


def validate_page(page, receipt, offset, total, maximum=PAGE_BYTES):
    fields = {'artifactDigest', 'artifactId', 'base64', 'byteCount', 'eof',
              'nextOffset', 'offset', 'totalByteCount'}
    if not isinstance(page, dict) or set(page) != fields:
        raise ValueError('artifact page shape differs')
    if (page['artifactId'] != receipt['artifactId'] or page['artifactDigest'] != receipt['artifactDigest']
            or any(type(page[k]) is not int for k in ('byteCount', 'nextOffset', 'offset', 'totalByteCount'))
            or type(page['eof']) is not bool or not isinstance(page['base64'], str)
            or page['offset'] != offset or page['totalByteCount'] != total
            or not 0 < page['byteCount'] <= maximum
            or page['nextOffset'] != offset + page['byteCount'] or page['nextOffset'] > total
            or page['eof'] != (page['nextOffset'] == total)):
        raise ValueError('artifact range, identity or EOF differs')
    decoded = base64.b64decode(page['base64'], validate=True)
    if len(decoded) != page['byteCount'] or base64.b64encode(decoded).decode('ascii') != page['base64']:
        raise ValueError('artifact base64 count/encoding differs')
    return decoded


class RssSampler:
    """Sampled process RSS, not an exact high-water mark or copy-count proof."""
    def __init__(self, pid):
        self.pids = [pid, os.getpid()]
        self.rows = []
        self.stop_event = threading.Event()
        self.started = clocks.awake_seconds()
        self.thread = None

    def sample(self):
        try:
            result = subprocess.run(['ps', '-o', 'pid=,rss=', '-p', ','.join(map(str, self.pids))],
                                    capture_output=True, text=True, timeout=5, check=True)
            values = {int(pid): int(rss) * 1024 for pid, rss in (line.split() for line in result.stdout.splitlines())}
            row = {'elapsedSeconds': clocks.awake_seconds() - self.started,
                   'daemonBytes': values[self.pids[0]], 'clientBytes': values[self.pids[1]]}
        except (subprocess.SubprocessError, ValueError, KeyError, OSError) as error:
            row = {'elapsedSeconds': clocks.awake_seconds() - self.started, 'unmeasured': type(error).__name__}
        self.rows.append(row)

    def start(self):
        self.sample()
        def loop():
            while not self.stop_event.wait(RSS_INTERVAL):
                self.sample()
        self.thread = threading.Thread(target=loop, daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        if self.thread:
            self.thread.join(timeout=6)
            if self.thread.is_alive():
                raise ValueError('RSS sampler did not stop')
        return self.rows


def rss_summary(rows):
    result = {}
    for key in ('daemonBytes', 'clientBytes'):
        if not rows or key not in rows[0] or any(key not in row for row in rows):
            result[key] = {'unmeasured': 'missing RSS observations; no complete sampled bound'}
        else:
            initial = rows[0][key]
            peak = max(row[key] for row in rows)
            result[key] = {'baselineBytes': initial, 'sampledPeakBytes': peak,
                           'sampledGrowthBytes': peak - initial}
    return result


def read_all(runtime, receipt, total, record, budget=READ_BUDGET):
    deadline = clocks.Deadline(budget)
    pages = []
    failed_page = None
    digest = hashlib.sha256()
    offset = 0
    with runtime.client() as client:
        client.configure_measurement(deadline, capture_failure=True)
        sampler = RssSampler(runtime.process.pid)
        sampler.start()
        started = clocks.awake_seconds()
        try:
            while offset < total:
                if deadline.expired():
                    raise TimeoutError('artifact read deadline')
                client.set_timeout(max(.001, min(30., deadline.remaining_seconds())))
                if pages and len(pages) % 64 == 0:
                    client.close()
                    client.connect()
                    client.verify_contract()
                # ControlClient's socket is already established. Bound every
                # read by the remaining overall continuous budget.
                failed_page = client.call('artifact.read', {'owner': receipt['owner'],
                    'artifactId': receipt['artifactId'], 'offset': offset, 'maxBytes': PAGE_BYTES})
                decoded = validate_page(failed_page, receipt, offset, total)
                digest.update(decoded)
                pages.append({'offset': offset, 'byteCount': len(decoded), 'nextOffset': failed_page['nextOffset'],
                              'eof': failed_page['eof']})
                offset += len(decoded)
                failed_page = None
            actual = digest.hexdigest()
            if actual != receipt['artifactDigest'] or deadline.expired():
                raise ValueError('artifact final digest or deadline differs')
            elapsed = clocks.awake_seconds() - started
        finally:
            rss = sampler.stop()
            if client.failure_evidence is not None:
                record({'kind': 'artifactTransportFailure', **client.failure_evidence})
            # No page report serialization/file writes inside the timing interval.
            for index, page in enumerate(pages):
                record({'kind': 'artifactPage', 'pageIndex': index, **page})
            if failed_page is not None:
                encoded = json.dumps(failed_page, sort_keys=True).encode()
                record({'kind': 'artifactRejectedPage', 'raw': encoded[:8 * 1024 * 1024].decode(errors='replace'),
                        'truncated': len(encoded) > 8 * 1024 * 1024, 'byteCount': len(encoded), 'sha256': hashlib.sha256(encoded).hexdigest()})
            record({'kind': 'artifactRss', 'intervalSeconds': RSS_INTERVAL, 'samples': rss,
                    'limitation': 'sampled lower bound on peak; not copy count or publication RSS'})
    return elapsed * 1000, {'payloadBytes': offset, 'actualPageCount': len(pages), 'sha256': actual,
        'effectiveBytesPerSecond': total / elapsed,
        'effectiveDecimalMBPerSecond': total / elapsed / 1_000_000,
        'effectiveMiBPerSecond': total / elapsed / (1024 * 1024), 'rssSamples': rss,
        'rssSummary': rss_summary(rss)}


def measure(daemon, soak, count, record, require_quiet=True):
    if count not in artifact_fixture.SIZES:
        raise ValueError('unsupported artifact size')
    root = harness.temporary_state_directory(prefix='adar.')
    def guard():
        if require_quiet:
            record({'kind': 'quietHost', **recovery.assert_quiet_host()})
    def seed_record(entry):
        record({**entry, 'kind': 'artifactSeedProcess' if entry['kind'] == 'journalProcess' else entry['kind']})
    try:
        record({'kind': 'artifactDiskBudget', **check_disk(root, count)})
        guard()
        fixture = artifact_fixture.generate(root / 'fixture.tar.gz', count)
        record({'kind': 'artifactInput', **fixture})
        try:
            result = subprocess.run([str(soak), '--seed-artifact-bench', str(root), str(count), fixture['sha256']],
                                    env=recovery.clean_environment(), capture_output=True, text=True,
                                    timeout=600, check=False)
        except subprocess.TimeoutExpired as error:
            journal.process_evidence(error.stdout, error.stderr, None, True, seed_record)
            raise
        journal.process_evidence(result.stdout, result.stderr, result.returncode, False, seed_record)
        entries = journal.read_attempts(result.stdout, record, allow_partial=result.returncode != 0)
        if result.returncode or not entries or entries[-1].get('kind') != 'artifactReady':
            raise ValueError('Artifact owner publication failed')
        receipt = entries[-1]['receipt']
        if (receipt.get('artifactDigest') != fixture['sha256'] or receipt.get('byteCount') != str(count)
                or receipt.get('owner', {}).get('kind') != 'import'
                or receipt.get('validation') != {'kind': 'flash-bundle', 'deviceProfile': 'dayu200'}):
            raise ValueError('Artifact receipt differs from fixture')
        guard()
        with harness.IsolatedRuntime(daemon, root, runtime_kind='rust') as runtime:
            runtime.start()
            guard()
            elapsed, proof = read_all(runtime, receipt, count, record)
            record({'kind': 'artifactReadComplete', 'milliseconds': elapsed, **proof})
            guard()
        return elapsed, {'artifactFixtureVersion': artifact_fixture.VERSION,
            'artifactArchiveSha256': fixture['sha256'],
            'artifactTemplateSha256': fixture['templateSha256'],
            'artifactOwnerKind': 'import', 'artifactImportKind': 'flash-bundle',
            'artifactPayloadBytes': count, 'artifactPageBytes': PAGE_BYTES,
            'artifactTimingBoundary': TIMING, 'artifactRssIntervalSeconds': RSS_INTERVAL,
            'artifactCachePolicy': 'fresh-owner-first-read-no-OS-cache-eviction',
            'artifactEvidence': {**fixture, **proof}}
    except Exception as error:
        record({'kind': 'artifactRun', 'status': 'FAILED', 'errorType': type(error).__name__})
        raise
    finally:
        shutil.rmtree(root)

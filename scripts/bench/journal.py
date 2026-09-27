"""Opt-in durable append and complete 1k-event drain; not a 1k-row single page."""
from __future__ import annotations

import hashlib
import json
import math
import shutil
import subprocess

from . import clocks, control, harness, recovery

COUNT = 1000
PAGE_SIZE = 1000
VERSION = 'rust-journal-measurement-v1'
DEFINITIONS = {
    'job.journalAppend': ('milliseconds', 'I.2 Job event throughput',
                          'production JournalWriter.append call through durable return, one 1000-event Job'),
    'job.eventsDrain': ('milliseconds', 'I.2 Job event throughput (complete drain)',
                        'all 1000 events over actual bounded pages; not the 1000-row single-page budget'),
}


def process_evidence(stdout, stderr, returncode, timed_out, record):
    def bounded(value, limit):
        data = value if isinstance(value, bytes) else (value or '').encode('utf-8')
        return {'text': data[:limit].decode('utf-8', errors='replace'),
                'byteCount': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                'truncated': len(data) > limit}
    # Bounded originals precede parsing, so an invalid final JSON fragment
    # cannot hide process exit facts or the successful prefix.
    record({'kind': 'journalProcess', 'returnCode': returncode, 'timedOut': timed_out,
            'stdout': bounded(stdout, 1024 * 1024), 'stderr': bounded(stderr, 64 * 1024)})


def read_attempts(output, record, allow_partial=False):
    if isinstance(output, bytes):
        output = output.decode('utf-8', errors='replace')
    entries = []
    malformed = False
    for index, line in enumerate(output.splitlines()):
        try:
            entry = json.loads(line)
            if not isinstance(entry, dict):
                raise ValueError('observation must be an object')
        except (ValueError, TypeError):
            record({'kind': 'malformedJournalOutput', 'lineIndex': index})
            malformed = True
            continue
        record(entry)
        entries.append(entry)
    if malformed and not allow_partial:
        raise ValueError('malformed durable append output')
    return entries


def validate_attempts(entries):
    if len(entries) != COUNT + 1 or entries[-1].get('kind') != 'journalComplete':
        raise ValueError('incomplete durable append output')
    values = []
    for index, entry in enumerate(entries[:-1]):
        value = entry.get('milliseconds')
        if (entry.get('kind') != 'journalAppend' or entry.get('sequence') != index
                or entry.get('status') != 'MEASURED'
                or entry.get('clock') != 'std::time::Instant'
                or entry.get('timingBoundary') != 'JournalWriter.append-call-through-return-v1'
                or isinstance(value, bool) or not isinstance(value, (int, float))
                or not math.isfinite(value) or value < 0):
            raise ValueError('invalid durable append observation')
        values.append(value)
    return values


def validate_row(row, index, row_cursors):
    # Closed published job.events row/data shapes plus this fixture's exact
    # origin. Matching IDs alone does not prove that the requested Job was read.
    kind = 'jobCreated' if index == 0 else 'stateTransition' if index == 1 else 'warning'
    expected_data = {'jobId': 'job-recovery-00000',
                     'sessionId': 'session-job-recovery-00000',
                     'journalKind': kind, 'timestamp': '2026-09-26T00:00:00Z',
                     'attempt': None, 'bindingRevision': None, 'stepId': None}
    if index == 1:
        expected_data.update(fromState='queued', toState='preflight')
    if (not isinstance(row, dict)
            or set(row) != {'cursor', 'data', 'eventId', 'runtimeRevision', 'streamPosition', 'type'}
            or row['eventId'] != f'event-{index:05}'
            or row['streamPosition'] != str(index + 1) or row['runtimeRevision'] != str(COUNT)
            or row['type'] != ('stateChanged' if index == 1 else 'journalEvent')
            or row['data'] != expected_data
            or not isinstance(row['cursor'], str) or not row['cursor']
            or row['cursor'] in row_cursors):
        raise ValueError('event row shape, fixture origin or cursor differs')
    row_cursors.add(row['cursor'])


def drain(runtime, record, budget_seconds=30):
    deadline = clocks.Deadline(budget_seconds)
    ids = set()
    cursors = set()
    row_cursors = set()
    cursor = None
    observed = []
    started = clocks.awake_seconds()
    try:
        while True:
            if deadline.expired():
                raise ValueError('event drain deadline exceeded')
            params = {'jobId': 'job-recovery-00000', 'pageSize': PAGE_SIZE}
            if cursor is not None:
                params['afterCursor'] = cursor
            with control.ControlClient(str(runtime.socket_path), timeout_seconds=max(.001, min(1., deadline.remaining_seconds()))) as client:
                page = client.call('job.events', params)
            observed.append(page)
            if (not isinstance(page, dict)
                    or set(page) != {'hasMore', 'items', 'nextCursor', 'order', 'pageKind', 'schemaVersion', 'snapshotRevision'}
                    or page.get('schemaVersion') != 'arkdeck.cli.page/1'
                    or page.get('pageKind') != 'eventStream' or page.get('order') != 'streamPositionAsc'
                    or type(page.get('hasMore')) is not bool
                    or not isinstance(page.get('nextCursor'), str) or not page['nextCursor']
                    or page['nextCursor'] in cursors
                    or not isinstance(page.get('items'), list) or not page['items']
                    or page.get('snapshotRevision') != str(COUNT)):
                raise ValueError('invalid event page contract or cursor')
            cursors.add(page['nextCursor'])
            for row in page['items']:
                index = len(ids)
                validate_row(row, index, row_cursors)
                ids.add(row['eventId'])
            # Opaque cursors are independently encrypted with random nonces;
            # equivalent positions need not have equal ciphertext strings.
            if page['hasMore'] is False:
                break  # A valid terminal page still carries its resume cursor.
            if len(ids) >= COUNT:
                raise ValueError('event cursor made no progress')
            cursor = page['nextCursor']
        if len(ids) != COUNT or deadline.expired():
            raise ValueError('incomplete or timed-out event drain')
        elapsed = (clocks.awake_seconds() - started) * 1000
    finally:
        # Preserve partial pages even on refusal. All report serialization and
        # disk writes occur after the timing endpoint (or failed attempt).
        projected_bytes = 0
        for index, page in enumerate(observed):
            encoded = json.dumps(page, separators=(',', ':')).encode()
            projected_bytes += len(encoded)
            record({'kind': 'eventsPage', 'pageIndex': index,
                    'rowCount': len(page.get('items', [])) if isinstance(page, dict) and isinstance(page.get('items'), list) else None,
                    'serializedProjectionBytes': len(encoded),
                    'projectionSha256': hashlib.sha256(encoded).hexdigest()})
    return elapsed, {'eventRowCount': len(ids), 'actualPageCount': len(observed),
                     'serializedProjectionBytes': projected_bytes}


def measure(daemon, soak, record, require_quiet=True):
    root = harness.temporary_state_directory(prefix='adjm.')
    def guard():
        if require_quiet:
            record({'kind': 'quietHost', **recovery.assert_quiet_host()})
    try:
        guard()
        try:
            result = subprocess.run([str(soak), '--measure-journal', str(root)],
                                    env=recovery.clean_environment(), capture_output=True,
                                    text=True, timeout=300, check=False)
        except subprocess.TimeoutExpired as error:
            process_evidence(error.stdout, error.stderr, None, True, record)
            read_attempts(error.stdout or '', record, allow_partial=True)
            raise
        process_evidence(result.stdout, result.stderr, result.returncode, False, record)
        entries = read_attempts(result.stdout, record, allow_partial=result.returncode != 0)
        if result.returncode:
            raise ValueError('durable journal measurement failed')
        values = validate_attempts(entries)
        manifest = entries[-1]['manifest']
        if manifest != {'fixtureVersion': VERSION, 'workload': 'journal',
                        'jobCount': 1, 'activeJobCount': 1, 'journalEventCount': COUNT,
                        'seedTimestamp': '2026-09-26T00:00:00Z', 'providerDispatchCount': 0}:
            raise ValueError('journal workload differs')
        proof = recovery.validate_input(root, manifest)
        record({'kind': 'journalInput', 'durability': 'production-append-return-fsync-F_FULLFSYNC', **proof})
        guard()
        with harness.IsolatedRuntime(daemon, root, runtime_kind='rust') as runtime:
            runtime.start()
            guard()
            elapsed, readback = drain(runtime, record)
            record({'kind': 'eventsDrain', 'milliseconds': elapsed, **readback})
            guard()
        data = (root / 'jobs-state/jobs/job-recovery-00000/journal.jsonl').read_bytes()
        if hashlib.sha256(data).hexdigest() != proof['journalSha256']:
            raise ValueError('journal changed during drain')
        return {'job.journalAppend': values, 'job.eventsDrain': [elapsed]}, {
            'journalFixtureVersion': VERSION, 'journalEventCount': COUNT,
            'journalRequestedPageSize': PAGE_SIZE,
            'journalAppendBoundary': 'JournalWriter.append-call-through-return-v1',
            'journalDrainBoundary': 'all-pages-contract-handshakes-readback-v1',
            'journalEvidence': {'durability': 'production-append-return-fsync-F_FULLFSYNC', **proof, **readback},
        }
    except Exception as error:
        record({'kind': 'journalRun', 'status': 'FAILED', 'errorType': type(error).__name__})
        raise
    finally:
        shutil.rmtree(root)

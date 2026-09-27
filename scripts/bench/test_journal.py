"""Bounded journal instrument validation; no production dispatch."""
import json
import pathlib
import subprocess
import unittest
from unittest.mock import patch, Mock
from . import journal, metrics


def attempts():
    return [dict(kind='journalAppend', sequence=i, milliseconds=.1, status='MEASURED',
                 clock='std::time::Instant', timingBoundary='JournalWriter.append-call-through-return-v1')
            for i in range(1000)] + [dict(kind='journalComplete')]


def page(start, end, more, cursor=None):
    items = []
    for i in range(start, end):
        data = dict(jobId='job-recovery-00000', sessionId='session-job-recovery-00000',
                    journalKind='jobCreated' if i == 0 else 'stateTransition' if i == 1 else 'warning',
                    timestamp='2026-09-26T00:00:00Z', attempt=None, bindingRevision=None, stepId=None)
        if i == 1:
            data.update(fromState='queued', toState='preflight')
        items.append(dict(eventId=f'event-{i:05}', streamPosition=str(i+1), runtimeRevision='1000',
                          cursor=f'cursor-{i+1}', data=data,
                          type='stateChanged' if i == 1 else 'journalEvent'))
    next_cursor = cursor or f'cursor-{end}'
    if items:
        items[-1]['cursor'] = next_cursor
    return dict(items=items, snapshotRevision='1000', hasMore=more, nextCursor=next_cursor,
                schemaVersion='arkdeck.cli.page/1', pageKind='eventStream', order='streamPositionAsc')


class JournalTests(unittest.TestCase):
    def test_append_requires_every_successful_finite_observation(self):
        self.assertEqual(len(journal.validate_attempts(attempts())), 1000)
        for field, value in [('sequence', 4), ('milliseconds', float('nan')),
                             ('milliseconds', -1), ('status', 'FAILED')]:
            data = attempts()
            data[0][field] = value
            with self.assertRaises(ValueError):
                journal.validate_attempts(data)
        with self.assertRaises(ValueError):
            journal.validate_attempts(attempts()[:-1])

    def drain(self, pages, record=None):
        with patch.object(journal.control, 'ControlClient') as client:
            client.return_value.__enter__.return_value.call.side_effect = pages
            return journal.drain(Mock(socket_path='/private-test.sock'), record or Mock())

    def test_complete_drain_counts_actual_pages_not_requested_size(self):
        _, proof = self.drain([page(0, 400, True), page(400, 800, True, 'last'), page(800, 1000, False)])
        self.assertEqual(proof['actualPageCount'], 3)
        self.assertEqual(proof['eventRowCount'], 1000)

    def test_truncated_duplicate_missing_and_stalled_pages_refuse(self):
        cases = [[page(0, 400, False)], [page(0, 400, True), page(0, 400, False)],
                 [page(0, 400, True), page(401, 1000, False)],
                 [page(0, 400, True, 'same'), page(400, 800, True, 'same')], [page(0, 0, False)]]
        for pages in cases:
            with self.subTest(pages=len(pages)), self.assertRaises(ValueError):
                self.drain(pages)

    def test_deadline_refuses_before_any_request(self):
        with patch.object(journal.clocks, 'Deadline') as deadline:
            deadline.return_value.expired.return_value = True
            with self.assertRaisesRegex(ValueError, 'deadline'):
                self.drain([])

    def test_seed_failure_or_timeout_keeps_attempt_and_cleans_root(self):
        for failure in (subprocess.CompletedProcess([], 1, '', ''),
                        subprocess.TimeoutExpired([], 300, output=b'')):
            record = Mock()
            with patch.object(journal.harness, 'temporary_state_directory', return_value=pathlib.Path('/fixture')), \
                 patch.object(journal.subprocess, 'run') as run, \
                 patch.object(journal.shutil, 'rmtree') as cleanup:
                if isinstance(failure, Exception):
                    run.side_effect = failure
                else:
                    run.return_value = failure
                with self.assertRaises((ValueError, subprocess.TimeoutExpired)):
                    journal.measure('/daemon', '/soak', record, require_quiet=False)
                cleanup.assert_called_once_with(pathlib.Path('/fixture'))
                self.assertEqual(record.call_args.args[0]['status'], 'FAILED')

    def test_opt_in_requires_rust_and_positive_only_mode(self):
        args = dict(daemon_executable=pathlib.Path('/daemon'), soak_executable=pathlib.Path('/soak'),
                    cold_start_samples=1, ipc_samples=1, idle_seconds=1, calibration_samples=1,
                    seed_seconds=1, seed_jobs_per_cycle=1)
        with self.assertRaises(ValueError):
            metrics.RunContext(**args, journal_samples=1)
        with self.assertRaises(ValueError):
            metrics.RunContext(**args, runtime_kind='rust', journal_only=True)


class JournalEvidenceTests(unittest.TestCase):
    def test_failed_or_timed_out_partial_output_retains_success_and_original_tail(self):
        prefix = json.dumps(attempts()[0]) + '\n'
        output = prefix + '{"kind":'
        for timed_out in (False, True):
            record = Mock()
            with patch.object(journal.harness, 'temporary_state_directory', return_value=pathlib.Path('/fixture')), \
                 patch.object(journal.subprocess, 'run') as run, \
                 patch.object(journal.shutil, 'rmtree') as cleanup:
                if timed_out:
                    run.side_effect = subprocess.TimeoutExpired([], 300, output=output.encode(), stderr=b'append failed')
                else:
                    run.return_value = subprocess.CompletedProcess([], 9, output, 'append failed')
                with self.assertRaises((ValueError, subprocess.TimeoutExpired)):
                    journal.measure('/daemon', '/soak', record, require_quiet=False)
                cleanup.assert_called_once()
            entries = [call.args[0] for call in record.call_args_list]
            process = entries[0]
            self.assertEqual(process['kind'], 'journalProcess')
            self.assertEqual(process['stdout']['text'], output)
            self.assertEqual(process['stderr']['text'], 'append failed')
            self.assertEqual(process['timedOut'], timed_out)
            self.assertEqual(process['returnCode'], None if timed_out else 9)
            self.assertEqual(entries[1]['status'], 'MEASURED')
            self.assertEqual(entries[2]['kind'], 'malformedJournalOutput')
            self.assertEqual(entries[-1]['status'], 'FAILED')

    def test_original_output_is_bounded_with_full_length_and_digest(self):
        record = Mock()
        journal.process_evidence('x' * (1024 * 1024 + 1), 'e' * 65537, 1, False, record)
        entry = record.call_args.args[0]
        self.assertEqual(entry['stdout']['byteCount'], 1024 * 1024 + 1)
        self.assertEqual(len(entry['stdout']['text']), 1024 * 1024)
        self.assertTrue(entry['stdout']['truncated'])
        self.assertTrue(entry['stderr']['truncated'])

    def test_reporting_io_is_outside_drain_timer(self):
        now = [0.0]
        def response(*args):
            now[0] += .125
            return page(0, 1000, False)
        def report(entry):
            now[0] += 10.0
        with patch.object(journal.control, 'ControlClient') as client, \
             patch.object(journal.clocks, 'awake_seconds', side_effect=lambda: now[0]):
            client.return_value.__enter__.return_value.call.side_effect = response
            elapsed, _ = journal.drain(Mock(socket_path='/socket'), report)
        self.assertEqual(elapsed, 125.0)
        self.assertEqual(now[0], 10.125)

    def test_page_contract_and_terminal_cursor_are_checked(self):
        for field, value in [('schemaVersion', 'wrong'), ('pageKind', 'wrong'),
                             ('order', 'wrong'), ('hasMore', 0), ('hasMore', 'false'),
                             ('nextCursor', None), ('nextCursor', ''), ('items', {})]:
            item = page(0, 1000, False)
            item[field] = value
            record = Mock()
            with patch.object(journal.control, 'ControlClient') as client:
                client.return_value.__enter__.return_value.call.return_value = item
                with self.assertRaises(ValueError):
                    journal.drain(Mock(socket_path='/socket'), record)
                self.assertEqual(record.call_args.args[0]['kind'], 'eventsPage')
        # The real terminal-page contract uses a non-null resume cursor.
        JournalTests().drain([page(0, 1000, False, 'terminal-cursor')])


class JournalRowContractTests(unittest.TestCase):
    def test_correct_ids_do_not_hide_missing_or_wrong_row_fields(self):
        mutations = [lambda row, key=key: row.pop(key) for key in ('data', 'cursor', 'type')]
        mutations += [lambda row: row.update(cursor=3), lambda row: row.update(type='wrong'),
                      lambda row: row['data'].update(jobId='other-job'),
                      lambda row: row['data'].update(sessionId='other-session'),
                      lambda row: row['data'].update(journalKind='warning'),
                      lambda row: row['data'].pop('attempt'),
                      lambda row: row['data'].update(bindingRevision=7),
                      lambda row: row.update(unpublished=True)]
        for mutate in mutations:
            item = page(0, 1000, False)
            mutate(item['items'][0])
            with self.subTest(mutation=mutate), self.assertRaises(ValueError):
                JournalTests().drain([item])

    def test_state_transition_matches_fixture_but_cursors_are_opaque(self):
        for field in ('fromState', 'toState'):
            item = page(0, 1000, False)
            item['items'][1]['data'][field] = 'wrong'
            with self.assertRaises(ValueError):
                JournalTests().drain([item])
        item = page(0, 1000, False)
        item['nextCursor'] = 'unrelated-cursor'
        JournalTests().drain([item])

#!/usr/bin/env python3
"""Check real Rust RPC/CLI with same-inode, explicit Swift event fixtures.

The Swift fixture is source-created in a fresh private temporary root. Cursors
bind the original inode, so this one harness intentionally keeps that root in
place. No installed state, recovery decision or device operation is used.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--daemon', type=Path, required=True)
    parser.add_argument('--cli', type=Path, required=True)
    args = parser.parse_args()
    root = args.fixture.resolve(strict=True)
    assert root.is_relative_to(Path('/private/tmp'))
    assert (root / 'fixture-kind').read_text() == 'arkdeck.job-events-interop-fixture/1'
    assert root.stat().st_mode & 0o777 == 0o700
    samples = json.loads((root / 'swift-results.json').read_text())
    assert samples and all(row['method'] == 'job.events' and row['params']['jobId'] == 'job-rust-events' for row in samples)
    protocol = json.loads((Path(__file__).resolve().parents[2] / 'spec/control/methods/health.json').read_text())
    daemon, cli = args.daemon.resolve(strict=True), args.cli.resolve(strict=True)
    endpoint = root / 'control.sock'
    env = {k: v for k, v in os.environ.items() if not k.startswith('ARKDECK_')}
    env.update(ARKDECK_DEVELOPMENT_STATE_ROOT=str(root), ARKDECK_ENDPOINT=str(endpoint))
    journal = root / 'jobs-state/jobs/job-rust-events/journal.jsonl'
    before = journal.read_bytes()
    before_db = (root / 'jobs-state/runtime-jobs.sqlite3').read_bytes()
    before_key = (journal.parent / 'event-cursor-key.v1').read_bytes()

    def start():
        with (root / 'daemon.log').open('ab') as log:
            process = subprocess.Popen([str(daemon)], env=env, stdout=log, stderr=log)
        for _ in range(250):
            if process.poll() is not None: raise AssertionError((root / 'daemon.log').read_text())
            try:
                with socket.socket(socket.AF_UNIX) as probe: probe.connect(str(endpoint))
                return process
            except OSError: time.sleep(0.02)
        process.terminate(); process.wait(timeout=5)
        raise AssertionError('daemon endpoint unavailable')

    def request(params):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(10); connection.connect(str(endpoint))
            connection.sendall(json.dumps({'protocolVersion': '1.0.0', 'contractIdentity': protocol['x-arkdeck-contractIdentity'],
                'id': 'event-owner-process', 'method': 'job.events', 'params': params}).encode() + b'\n')
            return json.loads(connection.makefile('rb').readline(8 * 1024 * 1024))

    def stable(value):
        result = json.loads(json.dumps(value)); result.pop('nextCursor')
        for row in result['items']: row.pop('cursor')
        return result

    process = start()
    try:
        for sample in samples:
            response = request(sample['params']); assert response['ok'], response
            assert stable(response['result']) == stable(sample['result']), (response, sample)
        first = request({'jobId': 'job-rust-events', 'pageSize': 2})['result']
        (root / 'rust-results.json').write_text(json.dumps(first) + '\n')
        command = [str(cli), 'job', 'events', '--job', 'job-rust-events', '--page-size', '3', '--after-cursor', first['nextCursor'], '--socket', str(endpoint), '--output', 'json']
        result = subprocess.run(command, capture_output=True, timeout=10)
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert [v['eventId'] for v in json.loads(result.stdout)['result']['items']] == ['event-2', 'event-3', 'event-4']
        for token in [first['nextCursor']+'x', first['nextCursor']+'=', '../journal.jsonl']:
            assert request({'jobId': 'job-rust-events', 'afterCursor': token})['error']['code'] == 'invalidCursor'
        assert request({'jobId': 'absent'})['error']['code'] == 'notFound'
        process.terminate(); process.wait(timeout=5); process = start()
        response = request({'jobId': 'job-rust-events', 'afterCursor': first['nextCursor']})
        assert response['ok'], response
        assert [v['eventId'] for v in response['result']['items']] == ['event-2', 'event-3', 'event-4']
        assert journal.read_bytes() == before
        assert (root / 'jobs-state/runtime-jobs.sqlite3').read_bytes() == before_db
        assert (journal.parent / 'event-cursor-key.v1').read_bytes() == before_key
        print(json.dumps({'status':'PASS','nativeSamples':len(samples),'swiftCursorResume':True,'rustCursorRestart':True,'actualCLI':True,'journalUnchanged':True,'deviceDispatchCount':0}))
    finally:
        if process.poll() is None: process.terminate(); process.wait(timeout=5)


if __name__ == '__main__': main()

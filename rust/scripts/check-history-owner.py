#!/usr/bin/env python3
"""Exercise the real Rust History owner and CLI in disposable, private host roots.

No Swift daemon, device provider, installed state or hardware evidence is used.
--record-frames records completed exchanges for the existing schema generator.
"""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', type=Path, default=ROOT / 'rust/target/debug')
    parser.add_argument('--record-frames', type=Path)
    args = parser.parse_args()
    daemon = (args.bin_dir / 'arkdeck-agentd').resolve()
    cli = (args.bin_dir / 'arkdeck').resolve()
    registry = json.loads((ROOT / 'Packages/ArkDeckKit/Contracts/control-protocol.json').read_bytes())
    identity = hashlib.sha256(json.dumps(registry, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    rows = []
    children = []
    with tempfile.TemporaryDirectory(prefix='arkdeck-history-', dir='/private/tmp') as temporary:
        root = Path(temporary).resolve()
        env = {key: value for key, value in os.environ.items() if not key.startswith('ARKDECK_')}
        env['ARKDECK_DEVELOPMENT_STATE_ROOT'] = str(root)
        env['ARKDECK_DAEMON_PATH'] = str(daemon)
        endpoint = root / 'a.sock'
        env['ARKDECK_ENDPOINT'] = str(endpoint)

        def start(endpoint):
            child = subprocess.Popen([str(daemon)], env={**env, 'ARKDECK_ENDPOINT': str(endpoint)}, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            children.append(child)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if child.poll() is not None:
                    raise AssertionError(child.stderr.read().decode())
                if endpoint.exists():
                    try:
                        with socket.socket(socket.AF_UNIX) as connection:
                            connection.connect(str(endpoint))
                        return child
                    except OSError:
                        pass
                time.sleep(.01)
            raise AssertionError('Rust owner did not bind')

        def exchange(method, params, endpoint=endpoint):
            request = {'protocolVersion': registry['currentVersion'], 'contractIdentity': identity, 'id': 'history-check', 'method': method, 'params': params}
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(10)
                connection.connect(str(endpoint))
                connection.sendall(json.dumps(request).encode() + b'\n')
                with connection.makefile('rb') as stream:
                    reply = json.loads(stream.readline(8 * 1024 * 1024 + 1))
            row = {'protocolVersion': registry['currentVersion'], 'method': method, 'params': params, **reply}
            row.pop('id')
            rows.append(row)
            return reply

        def command(arguments, expected=0):
            completed = subprocess.run([str(cli), '--output', 'json', *arguments], env=env, capture_output=True, timeout=15)
            assert completed.returncode == expected, (completed.returncode, completed.stdout, completed.stderr)
            return json.loads(completed.stdout)

        def save(generation='1', **kwargs):
            return {'expectedGeneration': generation, 'search': 'build', 'status': 'failed', 'mode': 'all', 'timeRange': 'lastDay', 'activity': 'all', 'sessionId': None, 'targetId': None, **kwargs}

        try:
            first = start(endpoint)
            assert exchange('history.filter.list', {})['result']['generation'] == '1'
            assert command(['history', 'filter', 'save', '--expected-generation', '1', '--search', 'compile'])['result']['generation'] == '2'
            assert exchange('history.filter.list', {})['result']['filters'][0]['query']['search'] == 'compile'
            first.kill(); first.wait(timeout=10)
            # Reopen the persisted document through a fresh daemon process.
            start(endpoint)
            assert command(['history', 'filter', 'list'])['result']['generation'] == '2'
            stale = command(['history', 'filter', 'save', '--expected-generation', '1'], 65)
            assert stale['error']['code'] == 'resourceConflict', stale
            assert exchange('history.filter.save', save('2'))['result']['generation'] == '3'
            assert exchange('history.filter.save', save('2'))['error']['code'] == 'resourceConflict'
            assert exchange('history.filter.save', save('3', sessionId='s1', targetId='t1'))['result']['generation'] == '4'
            assert exchange('history.filter.save', save('4', status='invalid'))['error']['code'] == 'invalidInput'
            assert exchange('history.filter.save', {})['error']['code'] == 'invalidParams'
            assert exchange('history.filter.list', {'unexpected': True})['error']['code'] == 'invalidParams'
            # One Runtime holds the development directory. Another daemon is
            # refused even with a different socket name, before serving writes.
            second_endpoint = root / 'b.sock'
            refused = subprocess.run([str(daemon)], env={**env, 'ARKDECK_ENDPOINT': str(second_endpoint)}, capture_output=True, timeout=10)
            assert refused.returncode != 0 and not second_endpoint.exists()
            with ThreadPoolExecutor(max_workers=2) as pool:
                futures = [pool.submit(exchange, 'history.filter.save', save('4'), path) for path in [endpoint, endpoint]]
                answers = [future.result() for future in futures]
            assert sum(answer['ok'] for answer in answers) == 1, answers
            assert next(answer['error']['code'] for answer in answers if not answer['ok']) == 'resourceConflict'
            lock = os.open(root / '.history-filter.lock', os.O_RDWR)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                assert exchange('history.filter.save', save('5'))['error']['code'] == 'resourceConflict'
            finally:
                os.close(lock)
            assert exchange('history.filter.delete', {'expectedGeneration': '4'})['error']['code'] == 'resourceConflict'
            assert exchange('history.filter.delete', {'expectedGeneration': '5'})['result']['generation'] == '6'
            assert exchange('history.filter.list', {})['result']['filters'] == []
            assert exchange('history.filter.delete', {'expectedGeneration': '6'})['error']['code'] == 'resourceNotFound'
            # Orphaned pre-rename transactions cannot become the current document.
            (root / '.history-filter.orphan.part').write_bytes(b'incomplete transaction')
            assert command(['history', 'filter', 'list'])['result']['generation'] == '6'
            os.chmod(root, 0o500)
            try:
                assert exchange('history.filter.save', save('6'))['error']['code'] == 'ioFailure'
            finally:
                os.chmod(root, 0o700)
            document = root / 'history-filter.json'
            document.write_bytes(b'corrupt')
            assert exchange('history.filter.save', save('6'))['error']['code'] == 'recordUnreadable'
            assert document.read_bytes() == b'corrupt'
            document.unlink()
            document.symlink_to('missing-target')
            assert exchange('history.filter.list', {})['error']['code'] == 'recordUnreadable'
            assert document.is_symlink()
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=10)
                child.stderr.close()
    if args.record_frames:
        args.record_frames.parent.mkdir(parents=True, exist_ok=True)
        args.record_frames.write_text(''.join(json.dumps(row, sort_keys=True, separators=(',', ':')) + '\n' for row in rows))
    print(json.dumps({'result': 'PASS', 'kind': 'isolated-host-test', 'controlExchanges': len(rows), 'daemonSHA256': hashlib.sha256(daemon.read_bytes()).hexdigest(), 'cliSHA256': hashlib.sha256(cli.read_bytes()).hexdigest(), 'deviceDispatchCount': 0}))


if __name__ == '__main__':
    main()

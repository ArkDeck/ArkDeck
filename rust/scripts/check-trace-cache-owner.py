#!/usr/bin/env python3
"""Exercise the real isolated cache status RPC/CLI with disposable host fixtures.

No database is parsed, no cache is purged, and no device acceptance is claimed.
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

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', type=Path, default=ROOT/'rust/target/debug')
    parser.add_argument('--cli-path', type=Path)
    parser.add_argument('--record-frames', type=Path)
    args = parser.parse_args()
    daemon = (args.bin_dir/'arkdeck-agentd').resolve()
    cli = (args.cli_path or args.bin_dir/'arkdeck').resolve()
    registry = json.loads((ROOT/'Packages/ArkDeckKit/Contracts/control-protocol.json').read_bytes())
    identity = hashlib.sha256(json.dumps(registry, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    rows, children = [], []
    with tempfile.TemporaryDirectory(prefix='arkdeck-trace-owner-', dir='/private/tmp') as temporary:
        root = Path(temporary).resolve()
        endpoint = root/'a.sock'
        env = {k: v for k, v in os.environ.items() if not k.startswith('ARKDECK_')}
        env.update(ARKDECK_DEVELOPMENT_STATE_ROOT=str(root), ARKDECK_ENDPOINT=str(endpoint), ARKDECK_DAEMON_PATH=str(daemon))

        def exchange(method, params=None):
            request = {'protocolVersion': registry['currentVersion'], 'contractIdentity': identity,
                       'id': 'trace-cache-owner', 'method': method, 'params': params or {}}
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(10)
                client.connect(str(endpoint))
                client.sendall(json.dumps(request).encode()+b'\n')
                with client.makefile('rb') as reader:
                    reply = json.loads(reader.readline(8*1024*1024+1))
            row = {'protocolVersion': registry['currentVersion'], 'method': method,
                   'params': params or {}, **reply}
            row.pop('id')
            rows.append(row)
            return reply

        def status():
            reply = exchange('trace.cache.status')
            assert reply['ok'], reply
            return reply['result']

        def start():
            child = subprocess.Popen([str(daemon)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            children.append(child)
            deadline = time.monotonic()+10
            while time.monotonic() < deadline:
                if child.poll() is not None:
                    raise AssertionError(child.stderr.read().decode())
                if endpoint.exists():
                    try:
                        assert exchange('health')['ok']
                        return child
                    except OSError:
                        pass
                time.sleep(.01)
            raise AssertionError('cache owner did not become ready')

        def command():
            reply = subprocess.run([str(cli), 'trace', 'cache', 'status', '--socket', str(endpoint),
                                    '--output', 'json'], env=env, capture_output=True, timeout=15)
            assert reply.returncode == 0, (reply.returncode, reply.stdout, reply.stderr)
            return json.loads(reply.stdout)['result']

        def file(path, data):
            path.write_bytes(data)
            path.chmod(0o600)

        try:
            child = start()
            empty = status()
            assert empty == command() and empty['entryCount'] == 0 and empty['totalByteCount'] == '0'
            cache = root/'trace-cache'
            trace, parser_key = 'a'*64, 'b'*64
            entry = cache/trace/parser_key
            entry.mkdir(parents=True, mode=0o700)
            entry.parent.chmod(0o700)
            database = entry/'database.sqlite'
            file(database, b'\x01\x02\x03')
            unaccounted = status()
            assert unaccounted['entryCount'] == 1 and unaccounted['activeEntryCount'] == 1
            assert unaccounted['totalByteCount'] == '3'
            # Same ordinary metadata shape as the current Swift host fixture.
            metadata = {
                'formatVersion': 1,
                'cacheKey': {'traceSHA256': trace, 'parserBinarySHA256': parser_key,
                             'upstreamRevision': 'fixture', 'schemaAdapterVersion': 'fixture',
                             'indexSchemaVersion': 1, 'parserKey': parser_key},
                'parser': {'name': 'fixture', 'reportedVersion': 'fixture', 'binarySHA256': parser_key,
                           'upstreamRepository': 'fixture', 'upstreamRevision': 'fixture', 'architecture': 'fixture',
                           'adapterVersion': 'fixture', 'buildRecipeVersion': 'fixture'},
                'traceSHA256': trace, 'sourceSHA256': trace, 'sourceByteCount': 3,
                'schemaFingerprint': 'fixture', 'schemaAdapterVersion': 'fixture', 'indexSchemaVersion': 1,
                'databasePreparation': {'schemaAdapterVersion': 'fixture', 'schemaFingerprint': 'fixture',
                                        'indexVersion': 1, 'upstreamDatabaseSHA256': trace, 'upstreamDatabaseByteCount': 3},
                'databaseByteCount': 3, 'createdAt': '2026-09-11T00:00:00Z', 'lastAccessedAt': '2026-09-11T00:00:00Z',
            }
            file(entry/'metadata.json', json.dumps(metadata, sort_keys=True, separators=(',', ':')).encode())
            lock_id = hashlib.sha256(f'{trace}:{parser_key}'.encode()).hexdigest()
            markers = []
            for directory, suffix in [('.locks', '.lock'), ('.leases', '.lease')]:
                (cache/directory).mkdir(mode=0o700)
                marker = cache/directory/(lock_id+suffix)
                file(marker, b'')
                markers.append(marker)
            ready = status()
            assert ready['activeEntryCount'] == 0 and ready['inactiveEntryCount'] == 1
            assert ready['totalByteCount'] == str(sum(p.stat().st_size for p in entry.iterdir()))
            assert command() == ready
            for marker in markers:
                with marker.open('rb') as held:
                    fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    assert status()['activeEntryCount'] == 1
                    fcntl.flock(held, fcntl.LOCK_UN)
            child.terminate()
            child.wait(timeout=10)
            child = start()
            assert status() == ready and command() == ready
            invalid = exchange('trace.cache.status', {'path': str(cache)})
            assert not invalid['ok'] and invalid['error']['code'] == 'invalidParams', invalid
            storage = exchange('runtime.storage.status')['result']['sessionDomain']
            conflict = exchange('runtime.storage.root', {'rootPath': str(cache), 'expectedGeneration': storage['generation']})
            assert not conflict['ok'], conflict
            (entry/'unsafe-link').symlink_to(database)
            unsafe = exchange('trace.cache.status')
            assert not unsafe['ok'] and unsafe['error']['code'] == 'recordUnreadable', unsafe
            assert database.read_bytes() == b'\x01\x02\x03'
            (entry/'unsafe-link').unlink()
            cache.rename(root/'retained-cache')
            cache.mkdir(mode=0o700)
            replaced = exchange('trace.cache.status')
            assert not replaced['ok'] and replaced['error']['code'] == 'recordUnreadable', replaced
            assert (root/'retained-cache'/trace/parser_key/'database.sqlite').read_bytes() == b'\x01\x02\x03'
        finally:
            for child in children:
                if child.poll() is None:
                    child.terminate()
                child.wait(timeout=10)
    if args.record_frames:
        args.record_frames.parent.mkdir(parents=True, exist_ok=True)
        args.record_frames.write_text(''.join(json.dumps(row, sort_keys=True, separators=(',', ':'))+'\n' for row in rows))
    print(f'PASS: Rust Trace cache status, {len(rows)} real control exchanges plus CLI, restart, lease contention and namespace refusal; no purge')


if __name__ == '__main__':
    main()

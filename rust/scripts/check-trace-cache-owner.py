#!/usr/bin/env python3
"""Exercise isolated Trace status/purge with actual Rust daemon and CLI processes.

Use --native-fixture with the current Swift producer output to consume its exact
owner inodes and compare the paired native receipt. Otherwise use explicitly
synthetic host metadata. No parser, device or installed cache is accessed.
"""
from __future__ import annotations
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import socket
import sqlite3
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', type=Path, default=ROOT/'rust/target/debug')
    parser.add_argument('--cli-path', type=Path)
    parser.add_argument('--record-frames', type=Path)
    parser.add_argument('--native-fixture', type=Path)
    args = parser.parse_args()
    daemon = (args.bin_dir/'arkdeck-agentd').resolve()
    cli = (args.cli_path or args.bin_dir/'arkdeck').resolve()
    registry = json.loads((ROOT/'Packages/ArkDeckKit/Contracts/control-protocol.json').read_bytes())
    identity = hashlib.sha256(json.dumps(registry, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    rows, children = [], []
    expected = None
    if args.native_fixture:
        assert (args.native_fixture/'fixture-kind').read_text().startswith('native ArkTrace owner and metadata;')
        expected = json.loads((args.native_fixture/'swift-expected-purge.json').read_bytes())
        context = contextlib.nullcontext(str(args.native_fixture/'rust'))
    else:
        context = tempfile.TemporaryDirectory(prefix='arkdeck-trace-owner-', dir='/private/tmp')
    with context as temporary:
        root = Path(temporary).resolve()
        endpoint = root/'a.sock'
        cache = root/'trace-cache/traces'
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

        def result(method):
            reply = exchange(method)
            assert reply['ok'], reply
            return reply['result']

        def refused(method, code='outcomeUnknown', params=None):
            reply = exchange(method, params)
            assert not reply['ok'] and reply['error']['code'] == code, reply

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

        def stop(child):
            child.terminate()
            child.wait(timeout=10)

        def command(leaf='status', expected_code=0):
            reply = subprocess.run([str(cli), 'trace', 'cache', leaf, '--socket', str(endpoint),
                                    '--output', 'json'], env=env, capture_output=True, timeout=15)
            assert reply.returncode == expected_code, (reply.returncode, reply.stdout, reply.stderr)
            envelope = json.loads(reply.stdout)
            return envelope['result'] if expected_code == 0 else envelope

        def file(path, data):
            path.write_bytes(data)
            path.chmod(0o600)

        def directory(path):
            current = root
            for part in path.relative_to(root).parts:
                current = current/part
                current.mkdir(exist_ok=True, mode=0o700)
                current.chmod(0o700)

        def synthetic_entry():
            trace, parser_key = 'a'*64, 'b'*64
            entry = cache/trace/parser_key
            directory(entry)
            entry.parent.chmod(0o700)
            file(entry/'database.sqlite', b'\x01\x02\x03')
            unaccounted = result('trace.cache.status')
            assert unaccounted['entryCount'] == 1 and unaccounted['activeEntryCount'] == 1
            metadata = {'formatVersion': 1,
                'cacheKey': {'traceSHA256': trace, 'parserBinarySHA256': parser_key,
                    'upstreamRevision': 'fixture', 'schemaAdapterVersion': 'fixture', 'indexSchemaVersion': 1, 'parserKey': parser_key},
                'parser': {'name': 'fixture', 'reportedVersion': 'fixture', 'binarySHA256': parser_key,
                    'upstreamRepository': 'fixture', 'upstreamRevision': 'fixture', 'architecture': 'fixture',
                    'adapterVersion': 'fixture', 'buildRecipeVersion': 'fixture'},
                'traceSHA256': trace, 'sourceSHA256': trace, 'sourceByteCount': 3,
                'schemaFingerprint': 'fixture', 'schemaAdapterVersion': 'fixture', 'indexSchemaVersion': 1,
                'databasePreparation': {'schemaAdapterVersion': 'fixture', 'schemaFingerprint': 'fixture',
                    'indexVersion': 1, 'upstreamDatabaseSHA256': trace, 'upstreamDatabaseByteCount': 3},
                'databaseByteCount': 3, 'createdAt': '2026-09-11T00:00:00Z', 'lastAccessedAt': '2026-09-11T00:00:00Z'}
            file(entry/'metadata.json', json.dumps(metadata, sort_keys=True, separators=(',', ':')).encode())
            lock_id = hashlib.sha256(f'{trace}:{parser_key}'.encode()).hexdigest()
            for folder, suffix in [('.locks', '.lock'), ('.leases', '.lease')]:
                directory(cache/folder)
                file(cache/folder/(lock_id+suffix), b'')
            owners = cache/'.staging/.owners'
            directory(owners)
            inode = entry.stat()
            file(owners/'entry-fixture.lock', b'')
            file(owners/'entry-fixture.json', json.dumps({'formatVersion': 1, 'state': 'ready',
                'device': inode.st_dev, 'inode': inode.st_ino, 'relativePath': f'{trace}/{parser_key}'}).encode())
            file(root/'original.htrace', b'original fixture trace')

        def seed_terminal_job():
            data = {'jobID': 'terminal', 'request': {'documentType': 'runtime-operation-request', 'schemaVersion': '1.0.0',
                'requestId': 'req-terminal', 'idempotencyKey': 'idem-terminal', 'target': {'targetId': 'TGT-fixture', 'expectedBindingRevision': 1},
                'operation': {'id': 'observe.device', 'version': 1}, 'inputs': {}, 'requestedOutputs': []},
                'operationReference': 'observe.device@1', 'catalogDigest': 'a'*64, 'providerID': 'hdc',
                'createdAtUTC': '2026-08-31T12:00:00Z', 'state': 'succeeded', 'outcomeUnknown': False, 'timeline': [], 'skipReasons': {}}
            seconds = 1788177600.0-978307200.0
            order = f'{struct.unpack(">Q", struct.pack(">d", seconds))[0] ^ (1 << 63):016x}'
            with sqlite3.connect(root/'jobs-state/runtime-jobs.sqlite3') as db:
                db.execute('INSERT INTO runtime_job VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                    ('terminal', 'idem-terminal', 'b'*64, 'succeeded', 1, data['createdAtUTC'], order,
                     data['createdAtUTC'], 1, json.dumps(data).encode()))

        try:
            child = start()
            if not args.native_fixture:
                empty = result('trace.cache.status')
                assert empty == command() and empty['entryCount'] == 0
                synthetic_entry()
            entries = list(cache.glob('*/*/metadata.json'))
            assert len(entries) == 1, entries
            entry = entries[0].parent
            database = entry/'database.sqlite'
            payload, original = database.read_bytes(), (root/'original.htrace').read_bytes()
            ready = result('trace.cache.status')
            assert ready['entryCount'] == 1 and ready['activeEntryCount'] == 0
            assert ready['totalByteCount'] == str(sum(p.stat().st_size for p in entry.iterdir()))
            assert command() == ready
            markers = [*cache.glob('.locks/*.lock'), *cache.glob('.leases/*.lease')]
            for marker in markers:
                with marker.open('rb') as held:
                    fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    assert result('trace.cache.status')['activeEntryCount'] == 1
                    assert database.read_bytes() == payload
                    fcntl.flock(held, fcntl.LOCK_UN)
            stop(child)
            seed_terminal_job()
            child = start()
            assert result('trace.cache.status') == ready
            refused('trace.cache.status', 'invalidParams', {'path': str(cache)})
            storage = result('runtime.storage.status')['sessionDomain']
            for protected_root in [cache, cache.parent]:
                conflict = exchange('runtime.storage.root', {'rootPath': str(protected_root),
                                    'expectedGeneration': storage['generation']})
                assert not conflict['ok'], conflict
            (entry/'unsafe-link').symlink_to(database)
            refused('trace.cache.status', 'recordUnreadable')
            refused('trace.cache.purge')
            assert database.read_bytes() == payload
            (entry/'unsafe-link').unlink()
            jobs = root/'jobs-state/jobs'
            directory(jobs)
            orphan = jobs/'unindexed'
            directory(orphan)
            refused('trace.cache.purge')
            orphan.rmdir()
            retained = jobs/'terminal'
            directory(retained)
            file(retained/'journal.jsonl', b'unknown retained history')
            protected = result('trace.cache.purge')
            assert protected['removedEntryCount'] == protected['recoveredPrivateDirectoryCount'] == 0
            assert protected['before'] == protected['after']
            (retained/'journal.jsonl').unlink()
            retained.rmdir()
            artifacts = root/'artifacts'
            imports = artifacts/'.imports-v1'
            # The Rust Import owner creates its idle skeleton at startup; that
            # alone must not retain Trace data, while any upload state does.
            assert sorted(p.name for p in imports.iterdir()) == ['.owner.lock', 'identities', 'payloads', 'records'], sorted(imports.iterdir())
            for name in ['.imports-v1', 'unknown-artifact-owner']:
                owned = artifacts/name
                directory(owned)
                file(owned/'uninterpreted.json', b'unmigrated references')
                protected = command('purge')
                assert protected['removedEntryCount'] == protected['recoveredPrivateDirectoryCount'] == 0
                (owned/'unsafe-link').symlink_to(database)
                refused('trace.cache.purge')
                command('purge', 75)
                (owned/'unsafe-link').unlink()
                (owned/'uninterpreted.json').unlink()
                if name != '.imports-v1':
                    owned.rmdir()
            for relative in ['records/upload.json', 'payloads/upload/chunk']:
                retained = imports/relative
                directory(retained.parent)
                file(retained, b'retained upload state')
                protected = command('purge')
                assert protected['removedEntryCount'] == protected['recoveredPrivateDirectoryCount'] == 0, protected
                retained.unlink()
                if retained.parent != imports/'payloads':
                    retained.parent.rmdir()
            corrupt = artifacts/'terminal'
            directory(corrupt)
            file(corrupt/'index.json', b'{}')
            refused('trace.cache.purge')
            (corrupt/'index.json').unlink()
            corrupt.rmdir()
            assert database.read_bytes() == payload
            refused('trace.cache.purge', 'invalidParams', {'path': str(cache)})
            applied = command('purge')
            assert applied['removedEntryCount'] == 1 and applied['after']['entryCount'] == 0, applied
            if expected is not None:
                assert applied == expected, (applied, expected)
            assert not entry.exists() and (root/'original.htrace').read_bytes() == original
            stop(child)
            child = start()
            assert command('purge')['removedEntryCount'] == 0
            cache.rename(root/'retained-cache')
            directory(cache)
            refused('trace.cache.status', 'recordUnreadable')
            refused('trace.cache.purge')
            if args.native_fixture:
                (args.native_fixture/'rust-purge.json').write_text(json.dumps(applied, sort_keys=True)+'\n')
        finally:
            for child in children:
                if child.poll() is None:
                    stop(child)
                child.stderr.close()
    if args.record_frames:
        args.record_frames.parent.mkdir(parents=True, exist_ok=True)
        args.record_frames.write_text(''.join(json.dumps(row, sort_keys=True, separators=(',', ':'))+'\n' for row in rows))
    print(f'PASS: Rust Trace status/purge, {len(rows)} control exchanges plus CLI; complete owner retention, leased deletion, restart and original Artifact preservation')


if __name__ == '__main__':
    main()

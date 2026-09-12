#!/usr/bin/env python3
"""Exercise actual isolated Tool list RPC/CLI and retained native pages.

Private test roots remain on disk. An optional native registry is only copied;
no registered source, installed state, helper process or device is modified.
"""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
METHOD = 'runtime.tool.list'


def digest_files(root):
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', type=Path, default=ROOT/'rust/target/debug')
    parser.add_argument('--cli-path', type=Path)
    parser.add_argument('--record-frames', type=Path)
    parser.add_argument('--native-registry', type=Path)
    args = parser.parse_args()
    daemon = (args.bin_dir/'arkdeck-agentd').resolve()
    cli = (args.cli_path or args.bin_dir/'arkdeck').resolve()
    registry = json.loads((ROOT/'Packages/ArkDeckKit/Contracts/control-protocol.json').read_bytes())
    assert METHOD in registry['methods'], 'Tool list requires the current candidate contract'
    identity = hashlib.sha256(json.dumps(registry, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    root = Path(tempfile.mkdtemp(prefix='tool-list-process-', dir='/private/tmp')).resolve()
    endpoint = root/'a.sock'
    native_before = None
    if args.native_registry:
        source = args.native_registry.resolve(strict=True)
        assert str(source).startswith('/private/tmp/') and source.is_dir()
        native_before = digest_files(source)
        destination = root/'bootstrap'
        shutil.copytree(source, destination, symlinks=True)
        # macOS fcopyfile may alter quarantine flags on a new copy. Quarantine
        # bytes participate in the frozen Tool content identity, so restore
        # exactly those source bytes on our new copies before native validation.
        for original in [source, *source.rglob('*')]:
            if original.is_symlink():
                continue
            copied = destination/original.relative_to(source)
            attribute = subprocess.run(['/usr/bin/xattr', '-px', 'com.apple.quarantine', str(original)],
                                       capture_output=True, check=False)
            if attribute.returncode == 0:
                value = bytes.fromhex(attribute.stdout.decode()).hex()
                subprocess.run(['/usr/bin/xattr', '-wx', 'com.apple.quarantine', value, str(copied)],
                               check=True, capture_output=True)
            measured = subprocess.run(['/usr/bin/xattr', '-px', 'com.apple.quarantine', str(copied)],
                                      capture_output=True, check=False)
            assert (attribute.returncode, attribute.stdout) == (measured.returncode, measured.stdout)

    env = {k: v for k, v in os.environ.items() if not k.startswith('ARKDECK_')}
    env.update(ARKDECK_DEVELOPMENT_STATE_ROOT=str(root), ARKDECK_ENDPOINT=str(endpoint),
               ARKDECK_DAEMON_PATH=str(daemon))
    rows, children = [], []

    def exchange(params, method=METHOD):
        request = {'protocolVersion': registry['currentVersion'], 'contractIdentity': identity,
                   'id': 'tool-list-process', 'method': method, 'params': params}
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(20)
            client.connect(str(endpoint))
            client.sendall(json.dumps(request).encode()+b'\n')
            with client.makefile('rb') as reader:
                reply = json.loads(reader.readline(8*1024*1024+1))
        assert reply['id'] == request['id']
        row = {'protocolVersion': registry['currentVersion'], 'method': method, 'params': params, **reply}
        row.pop('id')
        rows.append(row)
        return reply

    def result(params):
        reply = exchange(params)
        assert reply['ok'], reply
        return reply['result']

    def refused(params, code):
        reply = exchange(params)
        assert not reply['ok'] and reply['error']['code'] == code, reply
        assert reply['error']['details'] == {'phase': 'bootstrapRegistryOwner', 'newDispatchCount': 0}

    def command(arguments=(), code=0):
        answer = subprocess.run([str(cli), 'runtime', 'tool', 'list', *arguments,
                                 '--socket', str(endpoint), '--output', 'json'], env=env,
                                capture_output=True, timeout=30)
        assert answer.returncode == code, (answer.returncode, answer.stdout, answer.stderr)
        return json.loads(answer.stdout)

    def start():
        child = subprocess.Popen([str(daemon)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        children.append(child)
        deadline = time.monotonic()+10
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise AssertionError(child.stderr.read().decode())
            if endpoint.exists():
                try:
                    assert exchange({}, 'health')['ok']
                    return child
                except OSError:
                    pass
            time.sleep(.01)
        raise AssertionError('Tool list Runtime did not start')

    try:
        child = start()
        first = result({'pageSize': 1})
        assert set(first) == {'schemaVersion', 'pageKind', 'items', 'order', 'snapshotRevision', 'hasMore', 'nextCursor'}
        assert first['schemaVersion'] == 'arkdeck.cli.page/1' and first['pageKind'] == 'snapshot'
        assert first['order'] == 'toolRef:asc'
        inventory = command()['result']['items']
        if args.native_registry:
            assert len(inventory) >= 2 and first['hasMore']
            assert first['items'] == inventory[:1]
            pages = [first]
            cursor = first['nextCursor']
            while cursor:
                page = result({'pageSize': 1, 'cursor': cursor})
                assert command(['--page-size', '1', '--cursor', cursor])['result'] == page
                assert page['snapshotRevision'] == first['snapshotRevision']
                pages.append(page)
                cursor = page['nextCursor']
            assert [row for page in pages for row in page['items']] == inventory
            assert {row['kind'] for row in inventory} == {'hdc', 'deveco'}
            refs = [row['toolRef'] for row in inventory]
            assert refs == sorted(set(refs))
            cursor = first['nextCursor']
            child.terminate(); child.wait(timeout=10); child = start()
            assert result({'pageSize': 1, 'cursor': cursor}) == pages[1]
            refused({'pageSize': 2, 'cursor': cursor}, 'invalidCursor')
            # A reclaimed snapshot is expired; never silently start a new query.
            expired = result({'pageSize': 1})
            (root/'bootstrap/tool-snapshots'/f"snapshot-{expired['snapshotRevision']}.json").unlink()
            refused({'pageSize': 1, 'cursor': expired['nextCursor']}, 'invalidCursor')
            (root/'actual-tool-list.json').write_text(json.dumps({'pages': pages, 'all': inventory}))
        else:
            assert not first['hasMore'] and first['nextCursor'] is None
            assert first['items'] == inventory == []
            child.terminate(); child.wait(timeout=10); child = start()
            assert result({})['items'] == []
        index = root/'bootstrap/tools.json'
        before = index.read_bytes()
        for size in [-1, 0, 1001]:
            refused({'pageSize': size}, 'invalidInput')
        refused({'cursor': 'invalid'}, 'invalidCursor')
        refused({'pageSize': None}, 'invalidParams')
        refused({'path': '/private/tmp/forbidden'}, 'invalidParams')
        with (root/'bootstrap/.lock').open('rb') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            refused({'pageSize': 0, 'cursor': 'invalid'}, 'resourceConflict')
            assert command(code=65)['error']['code'] == 'resourceConflict'
            fcntl.flock(held, fcntl.LOCK_UN)
        assert index.read_bytes() == before
        # Only this new process fixture's index is damaged. Inventory validation
        # precedes cursor/size refusal and never repairs the corrupt bytes.
        index.write_bytes(b'{corrupt isolated tool index')
        refused({'pageSize': 0, 'cursor': 'invalid'}, 'recordUnreadable')
        assert command(code=2)['error']['code'] == 'recordUnreadable'
        assert index.read_bytes() == b'{corrupt isolated tool index'
        index.write_bytes(before)
        if args.native_registry:
            assert digest_files(source) == native_before
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=10)
            child.stderr.close()
        if args.record_frames:
            args.record_frames.write_text(''.join(json.dumps(row, sort_keys=True, separators=(',', ':'))+'\n' for row in rows))
    print(json.dumps({'result': 'PASS', 'kind': 'isolated-host-test', 'method': METHOD,
                      'controlExchanges': len(rows), 'nativeInventory': bool(args.native_registry),
                      'deviceDispatchCount': 0, 'retainedTestRoot': str(root)}, sort_keys=True))


if __name__ == '__main__':
    main()

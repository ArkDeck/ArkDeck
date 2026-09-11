#!/usr/bin/env python3
"""Exercise actual isolated Bundle metadata retirement RPC/CLI and retained content.

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
METHOD = 'runtime.bundle.remove'


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
    assert METHOD in registry['methods'], 'Bundle retirement requires the current candidate contract'
    identity = hashlib.sha256(json.dumps(registry, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    root = Path(tempfile.mkdtemp(prefix='bundle-retirement-process-', dir='/private/tmp')).resolve()
    endpoint = root/'a.sock'
    native_before = None
    if args.native_registry:
        source = args.native_registry.resolve(strict=True)
        assert str(source).startswith('/private/tmp/') and source.is_dir()
        native_before = digest_files(source)
        destination = root/'bootstrap'
        shutil.copytree(source, destination, symlinks=True)
        # macOS fcopyfile may alter quarantine flags on a new copy. Quarantine
        # bytes participate in the frozen Bundle content identity, so restore
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
                   'id': 'bundle-retirement-process', 'method': method, 'params': params}
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
        answer = subprocess.run([str(cli), 'runtime', 'bundle', 'remove', *arguments,
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
        raise AssertionError('Bundle retirement Runtime did not start')

    try:
        child = start()
        fields = {'bundle': 'bundle:sha256:' + '0'*64, 'expectedGeneration': '1'}
        index = root/'bootstrap/bundles.json'
        if args.native_registry:
            original = json.loads(index.read_bytes())
            records = original['records']
            available = next(v for v in records if v['state'] == 'available')
            reference = available['reference']
            fields['bundle'] = reference
            inspected = exchange({'bundle': reference}, 'runtime.bundle.inspect')
            assert inspected['ok'], inspected
            expected = dict(inspected['result'], state='removed', generation='2')
            content_before = digest_files(root/'bootstrap')
            first = command(['--bundle', reference, '--expected-generation', '1'])
            assert first['result'] == expected, first
            updated = json.loads(index.read_bytes())
            allowed = json.loads(json.dumps(original))
            for row in allowed['records']:
                if row['reference'] == reference:
                    row.update(state='removed', generation=2)
            assert updated == allowed
            content_after = digest_files(root/'bootstrap')
            content_before.pop('bundles.json'); content_after.pop('bundles.json')
            assert content_before == content_after
            before, identity_before = index.read_bytes(), index.stat()
            assert result(fields) == expected
            child.terminate(); child.wait(timeout=10); child = start()
            assert command(['--bundle', reference, '--expected-generation', '1'])['result'] == expected
            refused(dict(fields, expectedGeneration='2'), 'resourceConflict')
            assert command(['--bundle', reference, '--expected-generation', '2'], code=65)['error']['code'] == 'resourceConflict'
            assert index.read_bytes() == before
            identity_after = index.stat()
            assert (identity_before.st_ino, identity_before.st_mtime_ns, identity_before.st_ctime_ns) == (identity_after.st_ino, identity_after.st_mtime_ns, identity_after.st_ctime_ns)
        else:
            refused(fields, 'resourceNotFound')
            child.terminate(); child.wait(timeout=10); child = start()
            refused(dict(fields, expectedGeneration='2'), 'resourceNotFound')
        before = index.read_bytes()
        refused(dict(fields, bundle='invalid'), 'invalidInput')
        refused(dict(fields, expectedGeneration=None), 'invalidParams')
        refused(dict(fields, path='/private/tmp/forbidden'), 'invalidParams')
        with (root/'bootstrap/.lock').open('rb') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            refused(dict(fields, bundle='invalid'), 'resourceConflict')
            assert command(['--bundle', fields['bundle'], '--expected-generation', '1'], code=65)['error']['code'] == 'resourceConflict'
            fcntl.flock(held, fcntl.LOCK_UN)
        assert index.read_bytes() == before
        index.write_bytes(b'{corrupt isolated bundle index')
        refused(dict(fields, bundle='invalid'), 'recordUnreadable')
        assert command(['--bundle', fields['bundle'], '--expected-generation', '1'], code=2)['error']['code'] == 'recordUnreadable'
        assert index.read_bytes() == b'{corrupt isolated bundle index'
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

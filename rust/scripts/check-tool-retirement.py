#!/usr/bin/env python3
"""Exercise actual isolated HDC and DevEco metadata retirement RPC/CLI and retained content.

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
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
METHOD = 'runtime.tool.remove'


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
    assert METHOD in registry['methods'], 'Tool retirement requires the current candidate contract'
    identity = hashlib.sha256(json.dumps(registry, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    root = Path(tempfile.mkdtemp(prefix='tool-retirement-process-', dir='/private/tmp')).resolve()
    endpoint = root/'a.sock'
    native_before = None
    if args.native_registry:
        source = args.native_registry.resolve(strict=True)
        assert str(source).startswith('/private/tmp/') and source.is_dir()
        native_before = digest_files(source)
        destination = root/'bootstrap'
        shutil.copytree(source, destination, symlinks=True)
        # macOS fcopyfile may alter quarantine flags on a new copy. Quarantine
        # bytes participate in the frozen tool content identity, so restore
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
                   'id': 'tool-retirement-process', 'method': method, 'params': params}
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

    def command(arguments=(), code=0, socket_path=None):
        answer = subprocess.run([str(cli), 'runtime', 'tool', 'remove', *arguments,
                                 '--socket', str(socket_path or endpoint), '--output', 'json'], env=env,
                                capture_output=True, timeout=30)
        assert answer.returncode == code, (answer.returncode, answer.stdout, answer.stderr)
        return json.loads(answer.stdout)

    def lose_published_receipt(reference):
        # Forward one real owner call and discard its successful receipt. The
        # CLI must report uncertainty and never reconnect or replay the write.
        proxy = root/'loss.sock'
        requests, replies, failures = [], [], []
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(str(proxy)); os.chmod(proxy, 0o600)
            listener.listen(2); listener.settimeout(30)
            def forward():
                try:
                    with listener.accept()[0] as client, socket.socket(socket.AF_UNIX) as upstream:
                        client.settimeout(30); upstream.settimeout(30)
                        upstream.connect(str(endpoint))
                        with client.makefile('rb') as incoming, upstream.makefile('rb') as outgoing:
                            for step in range(2):
                                raw = incoming.readline(8*1024*1024+1)
                                request = json.loads(raw); requests.append(request)
                                upstream.sendall(raw)
                                raw_reply = outgoing.readline(8*1024*1024+1)
                                reply = json.loads(raw_reply); replies.append(reply)
                                row = {'protocolVersion': registry['currentVersion'],
                                       'method': request['method'], 'params': request.get('params') or {}, **reply}
                                row.pop('id'); rows.append(row)
                                if step == 0:
                                    assert request['method'] == 'health'
                                    client.sendall(raw_reply)
                                else:
                                    assert request['method'] == METHOD and reply['ok'], reply
                    listener.settimeout(.2)
                    try:
                        extra, _ = listener.accept(); extra.close()
                        raise AssertionError('CLI replayed retirement after losing the receipt')
                    except socket.timeout:
                        pass
                except BaseException as error:
                    failures.append(error)
            worker = threading.Thread(target=forward)
            worker.start()
            try:
                error = command(['--tool', reference, '--expected-generation', '1'], 75, proxy)
                assert error['error']['code'] == 'outcomeUnknown', error
            finally:
                worker.join(timeout=35)
        proxy.unlink()
        assert not worker.is_alive() and not failures, failures
        assert len(requests) == 2
        return replies[1]['result']

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
        raise AssertionError('Tool retirement Runtime did not start')

    try:
        child = start()
        fields = {'tool': 'tool:sha256:' + '0'*64, 'expectedGeneration': '1'}
        index = root/'bootstrap/tools.json'
        if not args.native_registry:
            # Real signed system bytes exercise the HDC metadata owner in CI;
            # they are never executed or claimed as device acceptance.
            registered = exchange({'kind': 'hdc', 'file': '/usr/bin/true'}, 'runtime.tool.register')
            assert registered['ok'], registered
        hdc_reference = None
        for index_name in (["tools.json", "deveco-toolchains.json"] if args.native_registry else ["tools.json"]):
            index = root/"bootstrap"/index_name
            original = json.loads(index.read_bytes())
            records = original['records']
            available = next(v for v in records if v['state'] == 'available')
            reference = available['reference']
            fields['tool'] = reference
            if index_name == 'tools.json': hdc_reference = reference
            inspected = exchange({'tool': reference}, 'runtime.tool.inspect')
            assert inspected['ok'], inspected
            expected = dict(inspected['result'], state='removed', generation='2')
            # Seed only a test-owned dependency reference. No selection or
            # capability is acquired, and the owner must refuse retirement.
            retained = json.loads(json.dumps(original))
            target = next(v for v in retained['records'] if v['reference'] == reference)
            target['references'] = [{'kind': 'workspacePreset' if index_name.startswith('deveco') else 'job',
                                     'id': 'tool-retirement-test'}]
            index.write_text(json.dumps(retained, sort_keys=True, separators=(',', ':')))
            retained_bytes = index.read_bytes()
            refused(fields, 'resourceConflict')
            assert command(['--tool', reference, '--expected-generation', '1'], 65)['error']['code'] == 'resourceConflict'
            assert index.read_bytes() == retained_bytes
            index.write_text(json.dumps(original, sort_keys=True, separators=(',', ':')))
            content_before = digest_files(root/'bootstrap')
            first = lose_published_receipt(reference)
            assert first == expected, first
            updated = json.loads(index.read_bytes())
            allowed = json.loads(json.dumps(original))
            for row in allowed['records']:
                if row['reference'] == reference:
                    row.update(state='removed', generation=2)
            assert updated == allowed
            content_after = digest_files(root/'bootstrap')
            content_before.pop(index_name); content_after.pop(index_name)
            assert content_before == content_after
            before, identity_before = index.read_bytes(), index.stat()
            assert result(fields) == expected
            child.terminate(); child.wait(timeout=10); child = start()
            assert command(['--tool', reference, '--expected-generation', '1'])['result'] == expected
            refused(dict(fields, expectedGeneration='2'), 'resourceConflict')
            assert command(['--tool', reference, '--expected-generation', '2'], code=65)['error']['code'] == 'resourceConflict'
            assert index.read_bytes() == before
            identity_after = index.stat()
            assert (identity_before.st_ino, identity_before.st_mtime_ns, identity_before.st_ctime_ns) == (identity_after.st_ino, identity_after.st_mtime_ns, identity_after.st_ctime_ns)
        index = root/"bootstrap/tools.json"
        fields["tool"] = hdc_reference
        refused(dict(fields, tool='tool:sha256:'+'0'*64), 'resourceNotFound')
        before = index.read_bytes()
        refused(dict(fields, tool='invalid'), 'invalidInput')
        refused(dict(fields, expectedGeneration=None), 'invalidParams')
        refused(dict(fields, path='/private/tmp/forbidden'), 'invalidParams')
        with (root/'bootstrap/.lock').open('rb') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            refused(dict(fields, tool='invalid'), 'resourceConflict')
            assert command(['--tool', fields['tool'], '--expected-generation', '1'], code=65)['error']['code'] == 'resourceConflict'
            fcntl.flock(held, fcntl.LOCK_UN)
        assert index.read_bytes() == before
        # Retired HDC still retains immutable content, so damage remains fatal.
        content = root/'bootstrap'/f"tool-{hdc_reference.split(':')[-1]}.hdc/hdc"
        native_bytes = content.read_bytes()
        mode = content.stat().st_mode & 0o777
        content.chmod(0o700); content.write_bytes(b'corrupt retained native content')
        refused(fields, 'recordUnreadable')
        assert command(['--tool', fields['tool'], '--expected-generation', '1'], 2)['error']['code'] == 'recordUnreadable'
        content.write_bytes(native_bytes); content.chmod(mode)
        index.write_bytes(b'{corrupt isolated tool index')
        refused(dict(fields, tool='invalid'), 'recordUnreadable')
        assert command(['--tool', fields['tool'], '--expected-generation', '1'], code=2)['error']['code'] == 'recordUnreadable'
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

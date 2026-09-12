#!/usr/bin/env python3
"""Actual Rust endpoint and CLI Target presentation checks with exported Swift fixture bytes.

The supplied store must be emitted by the synthetic Swift contract producer.
This test never adopts a device, supplies observation facts, or edits installed state.
"""
from __future__ import annotations
import argparse
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

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', type=Path, default=ROOT/'rust/target/debug')
    parser.add_argument('--swift-target-store', type=Path, required=True)
    parser.add_argument('--cli-path', type=Path)
    parser.add_argument('--record-frames', type=Path)
    parser.add_argument('--record-names-copy', type=Path)
    args = parser.parse_args()
    daemon = (args.bin_dir/'arkdeck-agentd').resolve()
    cli = (args.cli_path or args.bin_dir/'arkdeck').resolve()
    registry = json.loads((ROOT/'Packages/ArkDeckKit/Contracts/control-protocol.json').read_bytes())
    identity = hashlib.sha256(json.dumps(registry, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    rows = []
    children = []
    with tempfile.TemporaryDirectory(prefix='target-rpc-', dir='/private/tmp') as temporary:
        root = Path(temporary).resolve()
        endpoint = root/'a.sock'
        store = root/'targets-state'
        store.mkdir(mode=0o700)
        for name in ('targets.json', 'target-display-names.json'):
            shutil.copyfile(args.swift_target_store/name, store/name)
            (store/name).chmod(0o600)
        binding_bytes = (store/'targets.json').read_bytes()
        env = {key: value for key, value in os.environ.items() if not key.startswith('ARKDECK_')}
        env.update(ARKDECK_DEVELOPMENT_STATE_ROOT=str(root), ARKDECK_ENDPOINT=str(endpoint), ARKDECK_DAEMON_PATH=str(daemon))
        def exchange(method, params):
            request = dict(protocolVersion=registry['currentVersion'], contractIdentity=identity, id='target-resource-check', method=method, params=params)
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(10)
                client.connect(str(endpoint))
                client.sendall(json.dumps(request).encode()+b'\n')
                with client.makefile('rb') as reader:
                    reply = json.loads(reader.readline(8*1024*1024+1))
            row = dict(protocolVersion=registry['currentVersion'], method=method, params=params, **reply)
            row.pop('id')
            rows.append(row)
            return reply
        def result(method, params):
            reply = exchange(method, params)
            assert reply['ok'], reply
            return reply['result']
        def refused(method, params, code):
            reply = exchange(method, params)
            assert not reply['ok'] and reply['error']['code'] == code, reply
        def command(arguments, expected=0):
            reply = subprocess.run([str(cli), *arguments, '--socket', str(endpoint), '--output', 'json'], env=env, capture_output=True, timeout=15)
            assert reply.returncode == expected, (reply.returncode, reply.stdout, reply.stderr)
            return json.loads(reply.stdout)
        def start():
            child = subprocess.Popen([str(daemon)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            children.append(child)
            deadline = time.monotonic()+10
            while time.monotonic() < deadline:
                if child.poll() is not None:
                    raise AssertionError(child.stderr.read().decode())
                if endpoint.exists():
                    try:
                        assert result('health', {})['status'] == 'ok'
                        return child
                    except OSError:
                        pass
                time.sleep(.01)
            raise AssertionError('Target owner did not become ready')
        try:
            child = start()
            listed = command(['target', 'list'])['result']
            assert listed
            target = listed[0]['targetId']
            shown = result('target.show', {'targetId': target})
            generation = shown['displayNameGeneration']
            named = command(['target', 'display-name', 'set', '--target', target, '--expected-generation', generation, '--name', 'Rust fixture name'])['result']
            assert named['targetId'] == target and named['generation'] == str(int(generation)+1)
            refused('target.display-name.set', {'targetId': target, 'expectedGeneration': generation, 'name': 'Stale'}, 'resourceConflict')
            stale = command(['target', 'display-name', 'clear', '--target', target, '--expected-generation', generation], 65)
            assert stale['error']['code'] == 'resourceConflict'
            assert stale['error']['controlRequestRetryable'] is False
            refused('target.display-name.set', {'targetId': target, 'expectedGeneration': named['generation'], 'name': ' valid', 'freshFacts': {}}, 'invalidParams')
            refused('target.show', {'targetId': 'target-missing'}, 'notFound')
            refused('device.display-name.set', {'candidate': 'invented', 'observationId': 'invented', 'observationGeneration': '1', 'name': 'No authority'}, 'resourceConflict')
            child.terminate()
            child.wait(timeout=10)
            child = start()
            reopened = command(['target', 'show', '--target', target])['result']
            assert reopened['displayName'] == 'Rust fixture name' and reopened['displayNameGeneration'] == named['generation']
            cleared = command(['target', 'display-name', 'clear', '--target', target, '--expected-generation', named['generation']])['result']
            assert cleared['name'] is None and cleared['generation'] == str(int(named['generation'])+1)
            assert (store/'targets.json').read_bytes() == binding_bytes
            if args.record_names_copy:
                args.record_names_copy.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(store/'target-display-names.json', args.record_names_copy)
            assert not list((root/'jobs-state'/'jobs').glob('*/job-record.json'))
        finally:
            for child in children:
                if child.poll() is None:
                    child.terminate()
                    child.wait(timeout=10)
    if args.record_frames:
        args.record_frames.mkdir(parents=True, exist_ok=True)
        for method in sorted({row['method'] for row in rows}):
            (args.record_frames/f'{method}.jsonl').write_text(''.join(json.dumps(row, sort_keys=True, separators=(',', ':'))+'\n' for row in rows if row['method'] == method))
    print(json.dumps({'status': 'passed', 'domain': 'synthetic Swift store to actual Rust endpoint and CLI; no device dispatch', 'recordedFrames': len(rows)}, sort_keys=True))
if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Check the macOS Import upload owner and CLI against real Swift durable fixtures.

Only disposable host roots and authenticated local sockets are used. Commit,
release and reference inspection remain unavailable; this is no device evidence.
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
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / 'rust/tests/fixtures/import-upload-current'
TARGET_FIXTURE = ROOT / 'rust/tests/fixtures/import-target-current'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', type=Path, default=ROOT / 'rust/target/debug')
    args = parser.parse_args()
    daemon = (args.bin_dir / 'arkdeck-agentd').resolve()
    cli = (args.bin_dir / 'arkdeck').resolve()
    registry = json.loads((ROOT / 'Packages/ArkDeckKit/Contracts/control-protocol.json').read_bytes())
    identity = hashlib.sha256(json.dumps(registry, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    samples = json.loads((FIXTURE / 'swift-results.json').read_bytes())
    expected = next(row['result'] for row in samples if row['method'] == 'artifact.import.inspect')
    request_id = expected['importRequestId']
    imported = expected['importId']
    children = []
    with tempfile.TemporaryDirectory(prefix='arkdeck-import-', dir='/private/tmp') as temporary:
        root = Path(temporary).resolve()
        shutil.copytree(FIXTURE / 'artifacts', root / 'artifacts')
        # Git stores files without private mode bits. This local copy recreates
        # owner filesystem permissions; file bytes remain the Swift producer's.
        for path in (root / 'artifacts').rglob('*'):
            path.chmod(0o700 if path.is_dir() else 0o600)
        (root / 'artifacts').chmod(0o700)
        shutil.copytree(TARGET_FIXTURE / 'direct', root / 'targets-state')
        for path in (root / 'targets-state').iterdir():
            path.chmod(0o600)
        (root / 'targets-state').chmod(0o700)
        target_bytes = (root / 'targets-state/targets.json').read_bytes()
        actual_target = json.loads(target_bytes)['targets'][0]
        source = root / 'fixture.hap'
        shutil.copyfile(FIXTURE / 'fixture.hap', source)
        env = {key: value for key, value in os.environ.items() if not key.startswith('ARKDECK_')}
        endpoint = root / 'a.sock'
        env.update(ARKDECK_DEVELOPMENT_STATE_ROOT=str(root), ARKDECK_DAEMON_PATH=str(daemon), ARKDECK_ENDPOINT=str(endpoint))
        checkpoint = root / 'artifacts/.imports-v1/records' / (hashlib.sha256(request_id.encode()).hexdigest() + '.json')
        stage = root / f'artifacts/.imports-v1/payloads/{imported}.stage'

        def start():
            child = subprocess.Popen([str(daemon)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
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
            raise AssertionError('Import owner did not bind')

        def exchange(method, params):
            request = {'protocolVersion': registry['currentVersion'], 'contractIdentity': identity,
                       'id': 'import-owner-check', 'method': method, 'params': params}
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(10)
                connection.connect(str(endpoint))
                connection.sendall(json.dumps(request).encode() + b'\n')
                with connection.makefile('rb') as stream:
                    return json.loads(stream.readline(8 * 1024 * 1024 + 1))

        def command(arguments, expected_exit=0, socket_path=None):
            complete = subprocess.run([str(cli), '--output', 'json', '--socket', str(socket_path or endpoint), *arguments],
                                      env=env, capture_output=True, timeout=15)
            assert complete.returncode == expected_exit, (complete.returncode, complete.stdout, complete.stderr)
            return json.loads(complete.stdout)

        proxy = None
        worker = None
        stopping = threading.Event()
        forwarded = []
        proxy_errors = []
        try:
            child = start()
            before = checkpoint.read_bytes()
            assert exchange('artifact.import.inspect', {'importRequestId': request_id})['result'] == expected
            assert exchange('artifact.import.begin', expected['metadata'])['result'] == expected
            assert checkpoint.read_bytes() == before
            new_metadata = {**expected['metadata'], 'importRequestId': 'requires-target-owner'}
            refusal = exchange('artifact.import.begin', new_metadata)
            assert refusal['error']['code'] == 'resourceConflict', refusal
            assert not checkpoint.with_name(hashlib.sha256(b'requires-target-owner').hexdigest() + '.json').exists()

            # This proxy forwards the real owner's health and typed requests,
            # then loses exactly one successful append reply after publication.
            proxy_path = root / 'drop.sock'
            proxy = socket.socket(socket.AF_UNIX)
            proxy.bind(str(proxy_path))
            proxy_path.chmod(0o600)
            proxy.listen(8)
            proxy.settimeout(.1)

            def serve_proxy():
                dropped = False
                try:
                    while not stopping.is_set():
                        try:
                            client, _ = proxy.accept()
                        except TimeoutError:
                            continue
                        with client, socket.socket(socket.AF_UNIX) as upstream:
                            client.settimeout(10)
                            upstream.settimeout(10)
                            upstream.connect(str(endpoint))
                            with client.makefile('rb') as incoming, upstream.makefile('rb') as outgoing:
                                while True:
                                    line = incoming.readline(4 * 1024 * 1024 + 1)
                                    if not line:
                                        break
                                    request = json.loads(line)
                                    forwarded.append(request)
                                    upstream.sendall(line)
                                    reply = outgoing.readline(8 * 1024 * 1024 + 1)
                                    if request['method'] == 'artifact.import.append' and not dropped:
                                        assert json.loads(reply)['ok'] is True
                                        dropped = True
                                        break
                                    client.sendall(reply)
                except Exception as error:
                    if not stopping.is_set():
                        proxy_errors.append(repr(error))

            worker = threading.Thread(target=serve_proxy, daemon=True)
            worker.start()
            result = command(['artifact', 'import', 'hap', '--import-request-id', request_id,
                              '--target', expected['metadata']['targetId'], '--file', str(source)], 69, proxy_path)
            assert result['error']['code'] == 'operationUnavailable', result
            imports = [request for request in forwarded if request['method'].startswith('artifact.import.')]
            assert [request['method'] for request in imports] == [
                'artifact.import.inspect', 'artifact.import.append',
                'artifact.import.inspect', 'artifact.import.commit'], imports
            assert imports[0]['params'] == imports[2]['params'] == {'importRequestId': request_id}, imports
            assert imports[1]['params']['importId'] == imported and imports[1]['params']['offset'] == '2048', imports
            assert imports[1]['params']['generation'] == '1' and imports[1]['params']['byteCount'] == '2048', imports
            assert imports[3]['params'] == {'importId': imported, 'generation': '1'}, imports
            assert not any(request['method'] == 'target.show' for request in forwarded), forwarded
            assert stage.read_bytes() == source.read_bytes()
            uploaded = exchange('artifact.import.inspect', {'importId': imported})['result']
            assert uploaded['nextOffset'] == '4096' and uploaded['generation'] == '1'
            stopping.set()
            worker.join(2)
            assert not worker.is_alive() and not proxy_errors, proxy_errors
            proxy.close()
            proxy = None

            child.terminate()
            child.wait(timeout=10)
            child = start()
            assert exchange('artifact.import.inspect', {'importId': imported})['result'] == uploaded
            assert command(['artifact', 'import', 'inspect', '--import', imported], 69)['error']['code'] == 'operationUnavailable'
            saved = checkpoint.read_bytes()
            for method in ['artifact.import.commit', 'artifact.import.release', 'artifact.import.inspection']:
                params = {'importId': imported} if method.endswith('inspection') else {'importId': imported, 'generation': '1'}
                refusal = exchange(method, params)
                assert refusal['error']['code'] == 'operationUnavailable', refusal
                assert checkpoint.read_bytes() == saved and stage.read_bytes() == source.read_bytes()
            changed = source.read_bytes()[:-1] + b'X'
            source.write_bytes(changed)
            assert command(['artifact', 'import', 'hap', '--import-request-id', request_id,
                            '--target', expected['metadata']['targetId'], '--file', str(source)], 2)['error']['code'] == 'artifactIntegrityFailed'
            assert checkpoint.read_bytes() == saved
            aborted = command(['artifact', 'import', 'abort', '--import-request-id', request_id, '--expected-generation', '1'])['result']
            assert aborted['state'] == 'aborted' and aborted['generation'] == '2'
            assert not stage.exists()
            assert command(['artifact', 'import', 'abort', '--import-request-id', request_id, '--expected-generation', '1'])['result'] == aborted
            assert exchange('artifact.import.begin', expected['metadata'])['result'] == aborted
            assert exchange('artifact.import.inspect', {'importId': imported})['result'] == aborted
            # A new CLI upload resolves the actual Target owner. The committed
            # fixture document deliberately gives physical identity and connect
            # key different digests, proving the binding uses the HDC route.
            shutil.copyfile(FIXTURE / 'fixture.hap', source)
            fresh_request = 'actual-target-new-upload'
            fresh = command(['artifact', 'import', 'hap', '--import-request-id', fresh_request,
                             '--target', actual_target['targetID'], '--file', str(source)], 69)
            assert fresh['error']['code'] == 'operationUnavailable', fresh  # commit owner remains absent
            discovered = exchange('artifact.import.inspect', {'importRequestId': fresh_request})['result']
            fresh_id = discovered['importId']
            assert discovered['state'] == 'inProgress' and discovered['nextOffset'] == '4096', discovered
            record_path = root / 'artifacts/.imports-v1/records' / (hashlib.sha256(fresh_request.encode()).hexdigest() + '.json')
            record = json.loads(record_path.read_bytes())
            assert record['binding'] == {'targetID': actual_target['targetID'], 'bindingRevision': actual_target['bindingRevision'],
                'stableIdentitySHA256': hashlib.sha256(actual_target['connectKey'].encode()).hexdigest()}, record
            assert record['binding']['stableIdentitySHA256'] != actual_target['stablePhysicalIdentitySHA256']
            assert (root / 'artifacts/.imports-v1/payloads' / (fresh_id + '.stage')).read_bytes() == source.read_bytes()
            assert (root / 'targets-state/targets.json').read_bytes() == target_bytes
            child.terminate()
            child.wait(timeout=10)
            child = start()
            assert exchange('artifact.import.inspect', {'importRequestId': fresh_request})['result'] == discovered
            assert command(['artifact', 'import', 'abort', '--import-request-id', fresh_request,
                            '--expected-generation', '1'])['result']['state'] == 'aborted'
            # A proven alias cannot borrow the presentation digest or a stale
            # fallback in place of the not-yet-composed live route owner.
            child.terminate()
            child.wait(timeout=10)
            for name in ['targets.json', 'target-display-names.json']:
                shutil.copyfile(TARGET_FIXTURE / 'alias' / name, root / 'targets-state' / name)
                (root / 'targets-state' / name).chmod(0o600)
            alias_target = json.loads((TARGET_FIXTURE / 'alias/targets.json').read_bytes())['targets'][0]
            child = start()
            alias_metadata = {**expected['metadata'], 'importRequestId': 'requires-alias-route-owner',
                              'targetId': alias_target['targetID'], 'bindingRevision': str(alias_target['bindingRevision'])}
            refusal = exchange('artifact.import.begin', alias_metadata)
            assert refusal['error']['code'] == 'operationUnavailable', refusal
            assert not checkpoint.with_name(hashlib.sha256(b'requires-alias-route-owner').hexdigest() + '.json').exists()
            print('PASS: native upload/Target fixture parity, new CLI upload through actual direct Target binding, lost-append reply inspect/resume, restart, source identity, abort tombstone and unavailable publication/alias-route/reference seams; no device dispatch')
        finally:
            stopping.set()
            if worker:
                worker.join(2)
            if proxy:
                proxy.close()
            for child in children:
                if child.poll() is None:
                    child.terminate()
                    child.wait(timeout=10)


if __name__ == '__main__':
    main()

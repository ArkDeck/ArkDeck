#!/usr/bin/env python3
"""Check the facade-owned host stores against the real paired Swift authority.

The Rust facade serves history.filter.* from the paired authority's state
directory and the Swift daemon behind it is composed without that store
(TASK-XPA-012). This harness starts the real pair in a disposable private root,
drives the Rust and Swift CLIs through the public socket, and reads the Swift
daemon's own debug control-frame log: no History filter frame reaches it while
forwarded frames still do. The same directory is then served by a standalone
Swift daemon (whose log must show those frames, the positive control) and by
the pair again, so each owner reads what the other wrote.

Swift children get CFFIXED_USER_HOME inside the disposable root, so their
composition never opens the installed Application Support tree. Host-only:
no installed state, device or hardware evidence.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

ROOT = Path(__file__).resolve().parents[2]
OWNED = {'history.filter.delete', 'history.filter.list', 'history.filter.save'}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', type=Path, default=ROOT / 'rust/target/debug')
    parser.add_argument('--swift-bin-dir', type=Path, default=ROOT / 'Packages/ArkDeckKit/.build/debug',
                        help='SwiftPM debug products holding arkdeck-agentd and arkdeck')
    parser.add_argument('--record', type=Path, help='write the summary JSON here')
    args = parser.parse_args()
    facade = (args.bin_dir / 'arkdeck-agentd').resolve()
    rust_cli = (args.bin_dir / 'arkdeck').resolve()
    swift = (args.swift_bin_dir / 'arkdeck-agentd').resolve()
    swift_cli = (args.swift_bin_dir / 'arkdeck').resolve()
    registry = json.loads((ROOT / 'Packages/ArkDeckKit/Contracts/control-protocol.json').read_bytes())
    identity = hashlib.sha256(json.dumps(registry, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    checks: list[str] = []
    phases: dict[str, dict] = {}
    children: list[subprocess.Popen] = []

    with tempfile.TemporaryDirectory(prefix='xpa012-facade-owners-', dir='/private/tmp') as temporary:
        base = Path(temporary).resolve()
        state, home = base / 'state', base / 'home'
        for path in (state, home):
            path.mkdir(mode=0o700)
        public = state / 'agentd.sock'
        document = state / 'history-filter.json'
        clean = {key: value for key, value in os.environ.items()
                 if not key.startswith('ARKDECK_') and key != 'CFFIXED_USER_HOME'}
        clean['CFFIXED_USER_HOME'] = str(home)

        def check(name: str, condition: bool, detail: object = None) -> None:
            if not condition:
                raise AssertionError(f'{name}: {detail}')
            checks.append(name)

        def exchange(method: str, params: dict | None = None) -> dict:
            request = {'protocolVersion': registry['currentVersion'], 'contractIdentity': identity,
                       'id': 'facade-host-owner', 'method': method}
            if params is not None:
                request['params'] = params
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(30)
                connection.connect(str(public))
                connection.sendall(json.dumps(request, separators=(',', ':')).encode() + b'\n')
                with connection.makefile('rb') as stream:
                    return json.loads(stream.readline(8 * 1024 * 1024 + 1))

        def run(argv: list[str], env: dict, expected: int) -> dict:
            completed = subprocess.run(argv, env=env, capture_output=True, timeout=60)
            if completed.returncode != expected:
                raise AssertionError((argv, completed.returncode, completed.stdout, completed.stderr))
            return json.loads(completed.stdout)

        def rust(arguments: list[str], expected: int = 0) -> dict:
            env = dict(clean, ARKDECK_ENDPOINT=str(public), ARKDECK_DAEMON_PATH=str(facade))
            return run([str(rust_cli), '--output', 'json', *arguments], env, expected)

        def swift_command(arguments: list[str], expected: int = 0) -> dict:
            return run([str(swift_cli), *arguments, '--socket', str(public), '--output', 'json'], clean, expected)

        def wait_released(lock: Path) -> None:
            deadline = time.monotonic() + 60
            while lock.exists() and time.monotonic() < deadline:
                descriptor = os.open(lock, os.O_RDWR)
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    return
                except BlockingIOError:
                    time.sleep(.05)
                finally:
                    os.close(descriptor)
            if lock.exists():
                raise AssertionError('Swift authority kept its instance lock')

        def start(kind: str, frames: Path) -> subprocess.Popen:
            env = dict(clean, ARKDECK_CONTROL_FRAME_LOG=str(frames))
            if kind == 'pair':
                env.update(ARKDECK_ENDPOINT=str(public), ARKDECK_SWIFT_DAEMON=str(swift))
                argv = [str(facade)]
            else:
                argv = [str(swift), '--state-dir', str(state)]
            child = subprocess.Popen(argv, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            children.append(child)
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                if child.poll() is not None:
                    raise AssertionError(f'{kind} exited: {child.stderr.read().decode(errors="replace")}')
                if public.exists():
                    try:
                        if exchange('health').get('ok'):
                            return child
                    except OSError:
                        pass
                time.sleep(.05)
            raise AssertionError(f'{kind} did not serve health')

        def stop(child: subprocess.Popen) -> None:
            child.send_signal(signal.SIGTERM)
            child.wait(timeout=60)
            # The authority drains after its pairing pipe or signal closes.
            wait_released(state / 'instance.lock')

        def census(frames: Path) -> list[str]:
            methods = []
            for path in sorted(frames.glob('control-frames-*.jsonl')):
                methods += [json.loads(line)['method'] for line in path.read_text().splitlines()]
            return methods

        try:
            # Phase A: the paired facade owns the store.
            frames_a = base / 'frames-pair-1'
            pair = start('pair', frames_a)
            check('pair.list.initial', rust(['history', 'filter', 'list'])['result']['generation'] == '1')
            saved = swift_command(['history', 'filter', 'save', '--expected-generation', '1', '--search', 'compile'])
            check('pair.swiftCli.save', saved['result']['generation'] == '2', saved)
            listed = rust(['history', 'filter', 'list'])['result']
            check('pair.rustCli.readsSave', listed['filters'][0]['query']['search'] == 'compile', listed)
            stale = swift_command(['history', 'filter', 'save', '--expected-generation', '1'], 65)
            check('pair.staleGeneration', stale['error']['code'] == 'resourceConflict', stale)
            with ThreadPoolExecutor(max_workers=8) as pool:
                answers = list(pool.map(lambda _: exchange('history.filter.list', {}), range(32)))
            check('pair.concurrentReadsQueue', all(a.get('ok') for a in answers), answers)
            before = document.read_bytes()
            lock = os.open(state / '.history-filter.lock', os.O_RDWR)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                refused = exchange('history.filter.save', {
                    'expectedGeneration': '2', 'search': 'held', 'status': 'all', 'mode': 'all',
                    'sessionId': None, 'targetId': None, 'timeRange': 'anyTime', 'activity': 'all'})
            finally:
                os.close(lock)
            check('pair.foreignLockRefused', refused.get('error', {}).get('code') == 'resourceConflict', refused)
            check('pair.foreignLockWroteNothing', document.read_bytes() == before)
            check('pair.forwardedHealth', exchange('health').get('ok') is True)
            stop(pair)
            methods = census(frames_a)
            check('pair.authorityServedForwardedFrames', 'health' in methods, methods)
            check('pair.authorityNeverSawOwnedFrames', not OWNED.intersection(methods), methods)
            phases['pair-1'] = {'authorityFrames': len(methods), 'ownedFramesAtAuthority': 0}

            # Phase B: a standalone Swift daemon owns the same directory.
            frames_b = base / 'frames-standalone'
            standalone = start('standalone', frames_b)
            listed = swift_command(['history', 'filter', 'list'])['result']
            check('standalone.readsFacadeDocument',
                  (listed['generation'], listed['filters'][0]['query']['search']) == ('2', 'compile'), listed)
            saved = swift_command(['history', 'filter', 'save', '--expected-generation', '2', '--search', 'swift-owner'])
            check('standalone.save', saved['result']['generation'] == '3', saved)
            stop(standalone)
            methods = census(frames_b)
            owned_b = sorted(OWNED.intersection(methods))
            check('standalone.recorderSeesOwnedFrames', owned_b == ['history.filter.list', 'history.filter.save'], methods)
            phases['standalone'] = {'authorityFrames': len(methods), 'ownedFramesAtAuthority': len(
                [m for m in methods if m in OWNED])}

            # Phase C: the pair again reads the Swift-written document.
            frames_c = base / 'frames-pair-2'
            pair = start('pair', frames_c)
            listed = rust(['history', 'filter', 'list'])['result']
            check('pair.readsStandaloneDocument',
                  (listed['generation'], listed['filters'][0]['query']['search']) == ('3', 'swift-owner'), listed)
            deleted = rust(['history', 'filter', 'delete', '--expected-generation', '3'])['result']
            check('pair.delete', (deleted['generation'], deleted['query']) == ('4', None), deleted)
            check('pair.swiftCliReadsDelete', swift_command(['history', 'filter', 'list'])['result']['filters'] == [])
            stop(pair)
            methods = census(frames_c)
            check('pair2.authorityNeverSawOwnedFrames', not OWNED.intersection(methods), methods)
            phases['pair-2'] = {'authorityFrames': len(methods), 'ownedFramesAtAuthority': 0}
            check('noOrphanTransactions', not list(state.glob('.history-filter.*.part')))
            final = json.loads(document.read_bytes())
            check('finalDocument', (final['schemaVersion'], final['generation'], 'query' in final)
                  == ('arkdeck.history-filter-store/1', 4, False), final)
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=30)
                if child.stderr:
                    child.stderr.close()

    summary = {'result': 'PASS', 'kind': 'isolated-host-test', 'checks': checks, 'phases': phases,
               'facadeSHA256': sha256(facade), 'rustCliSHA256': sha256(rust_cli),
               'swiftDaemonSHA256': sha256(swift), 'swiftCliSHA256': sha256(swift_cli),
               'deviceDispatchCount': 0}
    if args.record:
        args.record.parent.mkdir(parents=True, exist_ok=True)
        args.record.write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print(json.dumps(summary, sort_keys=True))


if __name__ == '__main__':
    main()

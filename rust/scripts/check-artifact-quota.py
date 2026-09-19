#!/usr/bin/env python3
"""Compare Rust `artifact.quota` with the real Swift daemon over the Artifact
roots of the shared oracle.

Every scenario of rust/tests/fixtures/artifact-quota (a root the Swift
`RuntimeArtifactStore` wrote through its public API, and that root with one
change each) becomes the Artifact root of a fresh standalone Swift daemon
(`<state>/artifacts`) and then of a fresh isolated Rust owner
(`<root>/artifacts`): a Swift daemon keeps its used bytes once it has walked
them, so each read here is its first. Each daemon answers `artifact.quota` over
its socket and its CLI prints `artifact quota`. Every answer must equal the
oracle's and the other daemon's, with the root spelled `<root>`, both CLIs must
end the same way, and the Rust owner's read must leave its root exactly as its
startup left it.

Seeding moves every recorded retention deadline forward by one whole number
of days, the same for every index, so the earliest lands at least a week
after the run starts (`fixture-deadlines.py`): both daemons sweep expired
Artifacts at startup with the real clock, and the recorded ones lapse on
2026-09-21. The quota counts bytes, never a deadline.

Swift children get CFFIXED_USER_HOME inside the disposable root. Host-only: no
device, installed state or hardware evidence.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / 'rust/tests/fixtures/artifact-quota'
LABEL = '<root>'
CACHE = '.payload-verification-v1.json'
_deadlines_spec = importlib.util.spec_from_file_location(
    'fixture_deadlines', Path(__file__).with_name('fixture-deadlines.py'))
fixture_deadlines = importlib.util.module_from_spec(_deadlines_spec)
_deadlines_spec.loader.exec_module(fixture_deadlines)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(root: Path, scenario: str, before: list[dict], moved_by: datetime.timedelta) -> None:
    """The scenario's Artifact root as the oracle's read found it, its
    deadlines moved `moved_by`."""
    root.mkdir(mode=0o700)
    for entry in before:
        path = root / entry['path']
        if entry['kind'] == 'directory':
            path.mkdir(mode=0o700)
            path.chmod(int(entry['mode'], 8))
        elif entry['kind'] == 'file':
            fixture_deadlines.copy(FIXTURE / 'stores' / scenario / entry['path'], path, moved_by)
            path.chmod(int(entry['mode'], 8))
        elif entry['kind'] == 'symlink':
            os.symlink(entry['target'], path)
        else:
            raise AssertionError(f'{scenario}: unexpected entry {entry}')


def entries(root: Path) -> list[dict]:
    """Every entry under `root` as the oracle records it."""
    paths = []
    for directory, names, files in os.walk(root):
        for name in names + files:
            paths.append((Path(directory) / name).relative_to(root).as_posix())
    result = []
    for relative in sorted(paths, key=lambda path: path.encode()):
        path = root / relative
        status = path.lstat()
        mode = format(status.st_mode & 0o7777, 'o')
        if path.is_symlink():
            result.append({'kind': 'symlink', 'path': relative, 'target': os.readlink(path)})
        elif path.is_dir():
            result.append({'kind': 'directory', 'mode': mode, 'path': relative})
        elif path.name == CACHE:
            result.append({'kind': 'file', 'mode': mode, 'path': relative})
        else:
            result.append({'kind': 'file', 'mode': mode, 'path': relative, 'size': status.st_size})
    return result


def labelled(value, root: Path):
    """A value with the Artifact root spelled `<root>`, however the daemon
    spells it (Swift resolves /private/tmp to /tmp)."""
    if isinstance(value, dict):
        return {key: labelled(item, root) for key, item in value.items()}
    if isinstance(value, list):
        return [labelled(item, root) for item in value]
    if isinstance(value, str):
        for spelling in (str(root), str(root).removeprefix('/private')):
            value = value.replace(spelling, LABEL)
    return value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', type=Path, default=ROOT / 'rust/target/debug')
    parser.add_argument('--swift-bin-dir', type=Path, required=True,
                        help='SwiftPM debug products holding arkdeck-agentd and arkdeck')
    parser.add_argument('--record', type=Path, help='write the summary JSON here')
    args = parser.parse_args()
    rust_daemon = (args.bin_dir / 'arkdeck-agentd').resolve(strict=True)
    rust_cli = (args.bin_dir / 'arkdeck').resolve(strict=True)
    swift_daemon = (args.swift_bin_dir / 'arkdeck-agentd').resolve(strict=True)
    swift_cli = (args.swift_bin_dir / 'arkdeck').resolve(strict=True)
    registry = json.loads((ROOT / 'Packages/ArkDeckKit/Contracts/control-protocol.json').read_bytes())
    identity = hashlib.sha256(json.dumps(registry, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    cases = json.loads((FIXTURE / 'cases.json').read_text())
    trees = json.loads((FIXTURE / 'tree.json').read_text())
    checks: list[str] = []
    children: list[subprocess.Popen] = []

    moved_by = fixture_deadlines.shift(sorted(
        path for path in (FIXTURE / 'stores').rglob('index.json') if path.is_file() and not path.is_symlink()))

    with tempfile.TemporaryDirectory(prefix='xpa013-artifact-quota-', dir='/private/tmp') as temporary:
        base = Path(temporary).resolve()
        home = base / 'home'
        home.mkdir(mode=0o700)
        clean = {key: value for key, value in os.environ.items()
                 if not key.startswith('ARKDECK_') and key != 'CFFIXED_USER_HOME'}
        clean.update(CFFIXED_USER_HOME=str(home))

        def check(name: str, condition: bool, detail: object = None) -> None:
            if not condition:
                raise AssertionError(f'{name}: {detail}')
            checks.append(name)

        def exchange(endpoint: Path, method: str, params: dict | None = None) -> dict:
            request = {'protocolVersion': registry['currentVersion'], 'contractIdentity': identity,
                       'id': 'artifact-quota-harness', 'method': method}
            if params is not None:
                request['params'] = params
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(60)
                connection.connect(str(endpoint))
                connection.sendall(json.dumps(request, separators=(',', ':')).encode() + b'\n')
                with connection.makefile('rb') as stream:
                    reply = json.loads(stream.readline(8 * 1024 * 1024 + 1))
            return {key: reply[key] for key in ('ok', 'result', 'error') if key in reply}

        def start(argv: list[str], env: dict, endpoint: Path) -> subprocess.Popen:
            child = subprocess.Popen(argv, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            children.append(child)
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                if child.poll() is not None:
                    raise AssertionError(f'{argv[0]} exited: {child.stderr.read().decode(errors="replace")}')
                if endpoint.exists():
                    try:
                        if exchange(endpoint, 'health').get('ok'):
                            return child
                    except OSError:
                        pass
                time.sleep(.05)
            raise AssertionError(f'{argv[0]} did not serve health')

        def stop(child: subprocess.Popen) -> None:
            child.send_signal(signal.SIGTERM)
            child.wait(timeout=60)

        def cli(argv: list[str], env: dict, root: Path) -> dict:
            completed = subprocess.run(argv, env=env, capture_output=True, timeout=120)
            document = json.loads(completed.stdout)
            outcome = ({'result': document['result']} if completed.returncode == 0
                       else {'code': document['error']['code']})
            return {'exit': completed.returncode, **labelled(outcome, root)}

        try:
            for index, case in enumerate(cases):
                scenario = case['scenario']
                before = trees[scenario]['before']

                swift_state = base / f'swift-{index}'
                swift_state.mkdir(mode=0o700)
                swift_root = swift_state / 'artifacts'
                build(swift_root, scenario, before, moved_by)
                swift_socket = swift_state / 'agentd.sock'
                swift = start([str(swift_daemon), '--state-dir', str(swift_state)], clean, swift_socket)
                swift_answer = labelled(exchange(swift_socket, 'artifact.quota', {}), swift_root)
                swift_cli_read = cli([str(swift_cli), 'artifact', 'quota', '--socket', str(swift_socket),
                                      '--output', 'json'], clean, swift_root)
                stop(swift)

                rust_state = base / f'rust-{index}'
                rust_state.mkdir(mode=0o700)
                rust_root = rust_state / 'artifacts'
                build(rust_root, scenario, before, moved_by)
                rust_socket = rust_state / 'control.sock'
                rust = start([str(rust_daemon)],
                             dict(clean, ARKDECK_DEVELOPMENT_STATE_ROOT=str(rust_state),
                                  ARKDECK_ENDPOINT=str(rust_socket)),
                             rust_socket)
                started = entries(rust_root)
                rust_answer = labelled(exchange(rust_socket, 'artifact.quota', {}), rust_root)
                rust_cli_read = cli([str(rust_cli), '--output', 'json', 'artifact', 'quota'],
                                    dict(clean, ARKDECK_ENDPOINT=str(rust_socket),
                                         ARKDECK_DAEMON_PATH=str(rust_daemon)), rust_root)
                check(f'rust.unchanged.{scenario}', entries(rust_root) == started,
                      {'started': started, 'after': entries(rust_root)})
                stop(rust)

                check(f'swift.oracle.{scenario}', swift_answer == case['response'],
                      {'swift': swift_answer, 'oracle': case['response']})
                check(f'identical.{scenario}', rust_answer == swift_answer,
                      {'swift': swift_answer, 'rust': rust_answer})
                check(f'cli.{scenario}', rust_cli_read == swift_cli_read,
                      {'swift': swift_cli_read, 'rust': rust_cli_read})
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                    child.wait()
            subprocess.run(['chmod', '-R', 'u+rwX', str(base)], check=False)

    summary = {
        'kind': 'isolated-host-test',
        'result': 'PASS',
        'scenarios': len(cases),
        'checks': len(checks),
        'recordedDeadlinesMovedDays': moved_by.days,
        'deviceDispatchCount': 0,
        'rustDaemonSHA256': sha256(rust_daemon),
        'rustCliSHA256': sha256(rust_cli),
        'swiftDaemonSHA256': sha256(swift_daemon),
        'swiftCliSHA256': sha256(swift_cli),
    }
    text = json.dumps(summary, sort_keys=True)
    if args.record:
        args.record.write_text(text + '\n')
    print(text)


if __name__ == '__main__':
    main()

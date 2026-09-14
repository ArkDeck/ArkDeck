#!/usr/bin/env python3
"""Compare Rust `capability.list` and `capability.inspect` with the real Swift
daemon over the capability stores of the shared oracle.

Every scenario of rust/tests/fixtures/capability-read (stores the Swift
`RuntimeCapabilityStore` wrote through its public API, and such stores with
one defect each) is placed where each daemon keeps its capability store: the
standalone Swift daemon's `<state>/capabilities`, then the isolated Rust
owner's `<root>/jobs-state/capabilities`. Each daemon answers the oracle's
reads of every scenario over its socket while it runs, and each CLI lists and
inspects a populated store, an absent capability and a corrupt store. Every
answer must equal the oracle's and the other daemon's, with each store's
directory spelled `<store>`, every CLI read must end as the other CLI's does,
and the reads must leave each store as the oracle's reads left it: every file
byte-identical, at most the lock file new.

Swift children get CFFIXED_USER_HOME inside the disposable root. The
capabilities are the oracle's synthetic ones in that root: nothing is
installed, minted, reserved or consumed. Host-only: no device, installed state
or hardware evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / 'rust/tests/fixtures/capability-read'
LABEL = '<store>'
# The CLI reads each owner makes: a scenario and the arguments after `arkdeck`.
CLI_READS = (
    ('ledger', ('capability', 'list')),
    ('ledger', ('capability', 'inspect', '--capability', 'CAP-RT-POLICY-FLASH-G1')),
    ('ledger', ('capability', 'inspect', '--capability', 'CAP-RT-NOT-INSTALLED')),
    ('checkpointMissing', ('capability', 'list')),
    ('empty', ('capability', 'list')),
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def install(directory: Path, scenario: str, before: list[dict]) -> None:
    """The scenario's store as the oracle's reads found it."""
    for entry in directory.iterdir():
        entry.unlink()
    for entry in before:
        path = directory / entry['path']
        if entry['kind'] == 'file':
            shutil.copyfile(FIXTURE / 'stores' / scenario / entry['path'], path)
            path.chmod(int(entry['mode'], 8))
        elif entry['kind'] == 'symlink':
            os.symlink(entry['target'], path)
        else:
            raise AssertionError(f'{scenario}: unexpected entry {entry}')


def entries(directory: Path) -> list[dict]:
    """Every store entry as the oracle records it."""
    result = []
    for path in sorted(directory.iterdir(), key=lambda path: path.name.encode()):
        if path.is_symlink():
            result.append({'kind': 'symlink', 'path': path.name, 'target': os.readlink(path)})
        elif path.is_file():
            status = path.lstat()
            result.append({'kind': 'file', 'mode': format(status.st_mode & 0o7777, 'o'),
                           'path': path.name, 'size': status.st_size})
        else:
            result.append({'kind': 'other', 'path': path.name})
    return result


def labelled(value, store: Path):
    """A value with the store's directory spelled `<store>`, however the
    daemon spells it (Swift resolves /private/tmp to /tmp)."""
    if isinstance(value, dict):
        return {key: labelled(item, store) for key, item in value.items()}
    if isinstance(value, list):
        return [labelled(item, store) for item in value]
    if isinstance(value, str):
        for spelling in (str(store), str(store).removeprefix('/private')):
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

    with tempfile.TemporaryDirectory(prefix='xpa014-capability-read-', dir='/private/tmp') as temporary:
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
                       'id': 'capability-read-harness', 'method': method}
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

        def cli(argv: list[str], env: dict) -> tuple[int, dict]:
            completed = subprocess.run(argv, env=env, capture_output=True, timeout=120)
            return completed.returncode, json.loads(completed.stdout)

        def drive(owner: str, endpoint: Path, store: Path, run_cli) -> tuple[dict, dict, dict]:
            """Every oracle read of every scenario over the socket and the
            store each scenario's reads left, then the CLI reads."""
            answers, after = {}, {}
            for case in cases:
                scenario = case['scenario']
                install(store, scenario, trees[scenario]['before'])
                answers[scenario] = [labelled(exchange(endpoint, read['method'], read['params']), store)
                                     for read in case['exchanges']]
                after[scenario] = entries(store)
                for entry in trees[scenario]['before']:
                    if entry['kind'] == 'file':
                        name = entry['path']
                        check(f'{owner}.unchanged.{scenario}/{name}', (store / name).read_bytes()
                              == (FIXTURE / 'stores' / scenario / name).read_bytes())
            reads = {}
            for scenario, argv in CLI_READS:
                install(store, scenario, trees[scenario]['before'])
                code, document = run_cli(list(argv))
                outcome = ({'result': document['result']} if code == 0
                           else {'code': document['error']['code']})
                reads[f'{scenario}: {" ".join(argv)}'] = {'exit': code, **labelled(outcome, store)}
            return answers, after, reads

        try:
            # Phase A: the standalone Swift daemon keeps its store at
            # `<state>/capabilities`, created at startup.
            swift_state = base / 'swift-state'
            swift_state.mkdir(mode=0o700)
            swift_socket = swift_state / 'agentd.sock'
            swift = start([str(swift_daemon), '--state-dir', str(swift_state)], clean, swift_socket)
            swift_store = swift_state / 'capabilities'
            check('swift.store', swift_store.is_dir(), swift_store)
            swift_answers, swift_after, swift_cli_reads = drive(
                'swift', swift_socket, swift_store,
                lambda argv: cli([str(swift_cli), *argv, '--socket', str(swift_socket),
                                  '--output', 'json'], clean))
            stop(swift)

            # Phase B: the isolated Rust owner keeps its store beside its Job
            # state, `<root>/jobs-state/capabilities`, created at startup.
            rust_state = base / 'rust-state'
            rust_state.mkdir(mode=0o700)
            rust_socket = rust_state / 'control.sock'
            rust = start([str(rust_daemon)],
                         dict(clean, ARKDECK_DEVELOPMENT_STATE_ROOT=str(rust_state),
                              ARKDECK_ENDPOINT=str(rust_socket)),
                         rust_socket)
            rust_store = rust_state / 'jobs-state' / 'capabilities'
            check('rust.store', rust_store.is_dir() and rust_store.stat().st_mode & 0o777 == 0o700,
                  rust_store)
            cli_env = dict(clean, ARKDECK_ENDPOINT=str(rust_socket), ARKDECK_DAEMON_PATH=str(rust_daemon))
            rust_answers, rust_after, rust_cli_reads = drive(
                'rust', rust_socket, rust_store,
                lambda argv: cli([str(rust_cli), '--output', 'json', *argv], cli_env))
            stop(rust)

            reads = 0
            for case in cases:
                scenario = case['scenario']
                oracle = [read['response'] for read in case['exchanges']]
                reads += len(oracle)
                check(f'swift.oracle.{scenario}', swift_answers[scenario] == oracle,
                      {'swift': swift_answers[scenario], 'oracle': oracle})
                check(f'identical.{scenario}', rust_answers[scenario] == swift_answers[scenario],
                      {'swift': swift_answers[scenario], 'rust': rust_answers[scenario]})
                for owner, after in (('swift', swift_after), ('rust', rust_after)):
                    check(f'{owner}.tree.{scenario}', after[scenario] == trees[scenario]['after'],
                          {'live': after[scenario], 'oracle': trees[scenario]['after']})
            for key, swift_read in swift_cli_reads.items():
                check(f'cli.{key}', rust_cli_reads[key] == swift_read,
                      {'swift': swift_read, 'rust': rust_cli_reads[key]})
            check('cli.outcomes', [read['exit'] == 0 for read in rust_cli_reads.values()]
                  == [True, True, False, False, True], rust_cli_reads)
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                    child.wait()

    summary = {
        'kind': 'isolated-host-test',
        'result': 'PASS',
        'scenarios': len(cases),
        'readsPerOwner': reads,
        'cliReadsPerOwner': len(CLI_READS),
        'checks': len(checks),
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

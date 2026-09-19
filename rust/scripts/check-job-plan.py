#!/usr/bin/env python3
"""Compare Rust `job.plan` with the real Swift daemon on one physical state root.

A materialized plan digest covers the source Artifact's absolute path, so the
two owners plan over the same directory in turn: the standalone Swift daemon
(`--state-dir`) first, then the isolated Rust owner
(`ARKDECK_DEVELOPMENT_STATE_ROOT`) over a fresh copy of the same recorded
Artifact store at the same path. Each answers every request of the Swift oracle
(rust/tests/fixtures/job-plan-analyzer) over its socket and through its CLI,
and the answers must be identical. Both name /usr/bin/true as the
crash-signature analyzer, which planning pins by digest and never runs.

Seeding moves every recorded retention deadline forward by one whole number
of days, the same for every index, so the earliest lands at least a week
after the run starts (`fixture-deadlines.py`): both daemons sweep expired
Artifacts at startup with the real clock, and the recorded ones lapse on
2026-09-21. Nothing either owner answers reads a deadline.

Swift children get CFFIXED_USER_HOME inside the disposable root, so neither
owner opens installed Application Support state. Host-only: no device,
hardware evidence or installed state.
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
FIXTURE = ROOT / 'rust/tests/fixtures/job-plan-analyzer'
ANALYZER = Path('/usr/bin/true')
_deadlines_spec = importlib.util.spec_from_file_location(
    'fixture_deadlines', Path(__file__).with_name('fixture-deadlines.py'))
fixture_deadlines = importlib.util.module_from_spec(_deadlines_spec)
_deadlines_spec.loader.exec_module(fixture_deadlines)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def seed(state: Path, moved_by: datetime.timedelta) -> None:
    """The recorded Artifact store, with the modes Swift publication leaves and
    its deadlines moved `moved_by`."""
    state.mkdir(mode=0o700)
    artifacts = state / 'artifacts'
    artifacts.mkdir(mode=0o700)
    for job in sorted((FIXTURE / 'artifacts').iterdir()):
        destination = artifacts / job.name
        destination.mkdir(mode=0o700)
        for source in sorted(job.iterdir()):
            fixture_deadlines.copy(source, destination / source.name, moved_by)
            (destination / source.name).chmod(0o600 if source.name == 'index.json' else 0o400)


def tree(path: Path) -> set[str]:
    return {str(entry.relative_to(path)) for entry in path.rglob('*')}


def without_digest(answer: dict) -> dict:
    """An answer apart from the plan digest, which pins the analyzer bytes."""
    if not answer.get('ok'):
        return answer
    return dict(answer, result={k: v for k, v in answer['result'].items() if k != 'materializedPlanDigest'})


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
    # Cases planned by the configured daemon over an unchanged store; the
    # unconfigured and mutated ones are covered by the Rust oracle replay.
    cases = [case for case in json.loads((FIXTURE / 'cases.json').read_text())
             if 'engine' not in case and 'mutation' not in case]
    planned = next(case for case in cases if case['name'] == 'planned')
    checks: list[str] = []
    children: list[subprocess.Popen] = []
    summary: dict = {}

    moved_by = fixture_deadlines.shift(sorted((FIXTURE / 'artifacts').glob('*/index.json')))

    with tempfile.TemporaryDirectory(prefix='xpa014-job-plan-', dir='/private/tmp') as temporary:
        base = Path(temporary).resolve()
        state, home = base / 'state', base / 'home'
        home.mkdir(mode=0o700)
        clean = {key: value for key, value in os.environ.items()
                 if not key.startswith('ARKDECK_') and key != 'CFFIXED_USER_HOME'}
        clean.update(CFFIXED_USER_HOME=str(home), ARKDECK_ANALYZER_PATH=str(ANALYZER))
        request_file = base / 'request.json'
        request_file.write_text(planned['params']['requestJson'])
        inputs_file = base / 'inputs.json'
        inputs_file.write_text(json.dumps(json.loads(planned['params']['requestJson'])['inputs']))
        flag_form = ['--target', 'TGT-ORACLE', '--operation', 'analyzer.extract-crash-signature@1',
                     '--inputs-file', str(inputs_file), '--request-id', 'req-harness-flags',
                     '--idempotency-key', 'idem-harness-flags-0001']

        def check(name: str, condition: bool, detail: object = None) -> None:
            if not condition:
                raise AssertionError(f'{name}: {detail}')
            checks.append(name)

        def exchange(endpoint: Path, method: str, params: dict | None = None) -> dict:
            request = {'protocolVersion': registry['currentVersion'], 'contractIdentity': identity,
                       'id': 'job-plan-harness', 'method': method}
            if params is not None:
                request['params'] = params
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(30)
                connection.connect(str(endpoint))
                connection.sendall(json.dumps(request, separators=(',', ':')).encode() + b'\n')
                with connection.makefile('rb') as stream:
                    return json.loads(stream.readline(8 * 1024 * 1024 + 1))

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

        def answers(endpoint: Path) -> dict:
            replies = {}
            for case in cases:
                params = case['params'] if 'params' in case else {'requestJson': ' ' * case['requestJsonSpaces']}
                reply = exchange(endpoint, 'job.plan', params)
                replies[case['name']] = {key: reply[key] for key in ('ok', 'result', 'error') if key in reply}
            return replies

        def cli(argv: list[str], env: dict, expected: int = 0) -> dict:
            completed = subprocess.run(argv, env=env, capture_output=True, timeout=60)
            if completed.returncode != expected:
                raise AssertionError((argv, completed.returncode, completed.stdout, completed.stderr))
            return json.loads(completed.stdout)

        try:
            # Phase A: the standalone Swift daemon plans over the recorded store.
            seed(state, moved_by)
            swift_socket = state / 'agentd.sock'
            swift = start([str(swift_daemon), '--state-dir', str(state)], clean, swift_socket)
            before = tree(state / 'artifacts')
            swift_answers = answers(swift_socket)
            swift_file = cli([str(swift_cli), 'job', 'plan', '--request-file', str(request_file),
                              '--socket', str(swift_socket), '--output', 'json'], clean)
            swift_flags = cli([str(swift_cli), 'job', 'plan', *flag_form,
                               '--socket', str(swift_socket), '--output', 'json'], clean)
            swift_effects = sorted(tree(state / 'artifacts') - before)
            stop(swift)
            state.rename(base / 'state-swift')

            # Phase B: the isolated Rust owner plans over a fresh copy at the same path.
            seed(state, moved_by)
            rust_socket = state / 'control.sock'
            rust_env = dict(clean, ARKDECK_DEVELOPMENT_STATE_ROOT=str(state), ARKDECK_ENDPOINT=str(rust_socket))
            rust = start([str(rust_daemon)], rust_env, rust_socket)
            before = tree(state / 'artifacts')
            rust_answers = answers(rust_socket)
            cli_env = dict(clean, ARKDECK_ENDPOINT=str(rust_socket), ARKDECK_DAEMON_PATH=str(rust_daemon))
            rust_file = cli([str(rust_cli), '--output', 'json', 'job', 'plan',
                             '--request-file', str(request_file)], cli_env)
            rust_flags = cli([str(rust_cli), '--output', 'json', 'job', 'plan', *flag_form], cli_env)
            pinned = cli([str(rust_cli), '--output', 'json', 'job', 'plan', *flag_form,
                          '--expected-binding-revision', '3'], cli_env, 64)
            refused = cli([str(rust_cli), '--output', 'json', 'job', 'plan', '--request-file',
                           str(request_file), '--timeout', '5s', '--target', 'TGT-ORACLE'], cli_env, 64)
            rust_effects = sorted(tree(state / 'artifacts') - before)
            stop(rust)

            oracle = {case['name']: case['response'] for case in cases}
            for name, swift_answer in swift_answers.items():
                check(f'identical.{name}', rust_answers[name] == swift_answer,
                      {'swift': swift_answer, 'rust': rust_answers[name]})
                # The live Swift composition answers as the recorded oracle,
                # apart from the digest of the analyzer each one pins.
                check(f'oracle.{name}', without_digest(swift_answer) == without_digest(oracle[name]),
                      {'live': swift_answer, 'oracle': oracle[name]})
            zero = {'phase': 'preAdmission', 'newDispatchCount': 0}
            check('refusalsProveZeroDispatch', all(
                answer['error'].get('details') == zero for answer in rust_answers.values() if not answer['ok']))
            check('plansAreNeverAdmitted', all(
                answer['result']['jobAdmitted'] is False and answer['result']['dispatchDisposition'] == 'notDispatched'
                for answer in rust_answers.values() if answer['ok']))
            check('cli.requestFile', rust_file['result'] == swift_file['result'] == rust_answers['planned']['result'],
                  {'swift': swift_file, 'rust': rust_file})
            check('cli.flagForm', rust_flags['result'] == swift_flags['result'], {'swift': swift_flags, 'rust': rust_flags})
            check('cli.hostOnlyRevisionRefused', pinned['error']['code'] == 'invalidOption', pinned)
            check('cli.requestFileExclusive', refused['error']['code'] == 'invalidOption', refused)
            check('rust.planningWritesNothing', rust_effects == [], rust_effects)
            summary = {
                'result': 'PASS', 'kind': 'isolated-host-test', 'cases': len(cases),
                'identicalAnswers': len(swift_answers), 'plannedAnswers': sum(1 for a in rust_answers.values() if a['ok']),
                'checks': len(checks), 'swiftPlanningSideEffects': swift_effects, 'rustPlanningSideEffects': rust_effects,
                'analyzer': str(ANALYZER), 'analyzerSHA256': sha256(ANALYZER),
                'plannedDigest': rust_answers['planned']['result']['materializedPlanDigest'],
                'rustDaemonSHA256': sha256(rust_daemon), 'rustCliSHA256': sha256(rust_cli),
                'swiftDaemonSHA256': sha256(swift_daemon), 'swiftCliSHA256': sha256(swift_cli),
                'recordedDeadlinesMovedDays': moved_by.days, 'deviceDispatchCount': 0,
            }
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=30)
                if child.stderr:
                    child.stderr.close()

    if args.record:
        args.record.parent.mkdir(parents=True, exist_ok=True)
        args.record.write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print(json.dumps(summary, sort_keys=True))


if __name__ == '__main__':
    main()

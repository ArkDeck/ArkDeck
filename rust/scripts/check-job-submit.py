#!/usr/bin/env python3
"""Compare Rust `job.submit` admission with the real Swift daemon, then hand the
Rust-admitted Jobs to a Swift daemon that recovers them and runs one.

The plan digest covers the source Artifact's absolute path, so the owners admit
over one state root in turn: the standalone Swift daemon (`--state-dir`) first,
then the isolated Rust owner (`ARKDECK_DEVELOPMENT_STATE_ROOT`) over a fresh copy
of the recorded Artifact store at the same path. Each answers the admission
oracle's requests (rust/tests/fixtures/job-submit-analyzer) in order over its
socket, and each CLI submits the same flag-form request. The answers must be
identical; the admission index and every admitted Job's journal and record must
agree byte for byte apart from the clock. Then the Rust-written Job store is
placed where a standalone Swift daemon keeps its own: that daemon recovers the
Rust-admitted Jobs at startup, reads them as Rust reads them, and runs one. Both
daemons name /usr/bin/true as the analyzer, which prints nothing, so that run
ends in the analyzer's own refusal of an empty result.

Seeding moves every recorded retention deadline forward by one whole number
of days, the same for every index, so the earliest lands at least a week
after the run starts (`fixture-deadlines.py`): both daemons sweep expired
Artifacts at startup with the real clock, and the recorded ones lapse on
2026-09-21. Nothing either owner answers reads a deadline.

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
import re
import shutil
import signal
import socket
import sqlite3
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / 'rust/tests/fixtures/job-submit-analyzer'
ANALYZER = Path('/usr/bin/true')
_deadlines_spec = importlib.util.spec_from_file_location(
    'fixture_deadlines', Path(__file__).with_name('fixture-deadlines.py'))
fixture_deadlines = importlib.util.module_from_spec(_deadlines_spec)
_deadlines_spec.loader.exec_module(fixture_deadlines)
TIME = re.compile(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z')
TERMINAL = {'succeeded', 'failed', 'cancelled', 'abandoned', 'recovered', 'compensated'}


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


def untimed(text: str) -> str:
    return TIME.sub('<time>', text)


def untimed_value(value):
    if isinstance(value, dict):
        return {key: untimed_value(item) for key, item in value.items()}
    if isinstance(value, list):
        return [untimed_value(item) for item in value]
    return untimed(value) if isinstance(value, str) else value


def store(jobs_root: Path, scratch: Path) -> dict:
    """The admission index rows and every Job's files, byte for byte apart
    from the clock. The index is read from a copy, so the owner's files stay
    as the owner left them."""
    scratch.mkdir(mode=0o700)
    for database in jobs_root.glob('runtime-jobs.sqlite3*'):
        shutil.copyfile(database, scratch / database.name)
    connection = sqlite3.connect(scratch / 'runtime-jobs.sqlite3')
    try:
        rows = [
            {'jobId': job, 'idempotencyKey': key, 'requestHash': digest, 'state': state,
             'admissionSequence': sequence, 'version': version,
             'record': untimed(record if isinstance(record, str) else record.decode())}
            for job, key, digest, state, sequence, version, record in connection.execute(
                'SELECT job_id, idempotency_key, request_hash, state, admission_sequence, version, '
                'initial_record_json FROM runtime_job ORDER BY admission_sequence')]
    finally:
        connection.close()
    files = {}
    for job in sorted((jobs_root / 'jobs').iterdir()):
        for path in sorted(job.iterdir()):
            files[f'{job.name}/{path.name}'] = untimed(path.read_text())
    return {'rows': rows, 'files': files}


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
    # The requests a configured daemon answers in the oracle's order.
    cases = [case for case in json.loads((FIXTURE / 'cases.json').read_text()) if 'engine' not in case]
    checks: list[str] = []
    children: list[subprocess.Popen] = []
    summary: dict = {}

    moved_by = fixture_deadlines.shift(sorted((FIXTURE / 'artifacts').glob('*/index.json')))

    with tempfile.TemporaryDirectory(prefix='xpa014-job-submit-', dir='/private/tmp') as temporary:
        base = Path(temporary).resolve()
        state, home = base / 'state', base / 'home'
        home.mkdir(mode=0o700)
        clean = {key: value for key, value in os.environ.items()
                 if not key.startswith('ARKDECK_') and key != 'CFFIXED_USER_HOME'}
        clean.update(CFFIXED_USER_HOME=str(home), ARKDECK_ANALYZER_PATH=str(ANALYZER))
        admitted_case = next(case for case in cases if case['name'] == 'admitted')
        inputs_file = base / 'inputs.json'
        inputs_file.write_text(json.dumps(json.loads(admitted_case['params']['requestJson'])['inputs']))
        flag_form = ['--target', 'TGT-ORACLE', '--operation', 'analyzer.extract-crash-signature@1',
                     '--inputs-file', str(inputs_file), '--request-id', 'req-harness-cli',
                     '--idempotency-key', 'idem-harness-cli-0001']

        def check(name: str, condition: bool, detail: object = None) -> None:
            if not condition:
                raise AssertionError(f'{name}: {detail}')
            checks.append(name)

        def exchange(endpoint: Path, method: str, params: dict | None = None, timeout: float = 30) -> dict:
            request = {'protocolVersion': registry['currentVersion'], 'contractIdentity': identity,
                       'id': 'job-submit-harness', 'method': method}
            if params is not None:
                request['params'] = params
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(timeout)
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

        def cli(argv: list[str], env: dict, expected: int = 0) -> dict:
            completed = subprocess.run(argv, env=env, capture_output=True, timeout=60)
            if completed.returncode != expected:
                raise AssertionError((argv, completed.returncode, completed.stdout, completed.stderr))
            return json.loads(completed.stdout)

        # The oracle's reviewed plans name the plan its own analyzer and root
        # materialize. Each daemon here plans for /usr/bin/true under this root,
        # so its requests name the plan that daemon materializes.
        oracle_digest = json.loads(next(case for case in cases if case['name'] == 'duplicateWithReviewedPlan')
                                   ['params']['requestJson'])['reviewedPlanDigest']

        def admit(endpoint: Path) -> tuple[dict, list[str]]:
            live = exchange(endpoint, 'job.plan', admitted_case['params'])['result']['materializedPlanDigest']
            answers, jobs = {}, []
            for case in cases:
                params = case['params'] if 'params' in case else {'requestJson': ' ' * case['requestJsonSpaces']}
                if isinstance(params.get('requestJson'), str):
                    params = {'requestJson': params['requestJson'].replace(oracle_digest, live)}
                answers[case['name']] = exchange(endpoint, 'job.submit', params)
                result = answers[case['name']].get('result') or {}
                if result.get('deduplicated') is False:
                    jobs.append(result['jobId'])
            return answers, jobs

        def reads(endpoint: Path, jobs: list[str]) -> dict:
            return {job: {method: untimed_value(exchange(endpoint, method, {'jobId': job}))
                          for method in ('job.status', 'job.show')} for job in jobs}

        try:
            # Phase A: the standalone Swift daemon admits over the recorded store.
            seed(state, moved_by)
            swift_socket = state / 'agentd.sock'
            swift = start([str(swift_daemon), '--state-dir', str(state)], clean, swift_socket)
            swift_answers, swift_jobs = admit(swift_socket)
            swift_cli_answer = cli([str(swift_cli), 'job', 'submit', *flag_form, '--socket', str(swift_socket),
                                    '--output', 'json'], clean)
            swift_reads = reads(swift_socket, swift_jobs)
            stop(swift)
            swift_store = store(state, base / 'inspect-swift')
            state.rename(base / 'state-swift')

            # Phase B: the isolated Rust owner admits over a fresh copy at the same path.
            seed(state, moved_by)
            rust_socket = state / 'control.sock'
            rust_env = dict(clean, ARKDECK_DEVELOPMENT_STATE_ROOT=str(state), ARKDECK_ENDPOINT=str(rust_socket))
            rust = start([str(rust_daemon)], rust_env, rust_socket)
            rust_answers, rust_jobs = admit(rust_socket)
            cli_env = dict(clean, ARKDECK_ENDPOINT=str(rust_socket), ARKDECK_DAEMON_PATH=str(rust_daemon))
            rust_cli_answer = cli([str(rust_cli), '--output', 'json', 'job', 'submit', *flag_form], cli_env)
            repeated = cli([str(rust_cli), '--output', 'json', 'job', 'submit', *flag_form], cli_env)
            rust_reads = reads(rust_socket, rust_jobs)
            stop(rust)
            rust_store = store(state / 'jobs-state', base / 'inspect-rust')

            for name, answer in swift_answers.items():
                check(f'identical.{name}', rust_answers[name] == answer, {'swift': answer, 'rust': rust_answers[name]})
                oracle = next(case['response'] for case in cases if case['name'] == name)
                check(f'oracle.{name}', answer == oracle, {'live': answer, 'oracle': oracle})
            check('sameJobs', rust_jobs == swift_jobs and len(rust_jobs) == 4, (swift_jobs, rust_jobs))
            check('cli.submit', rust_cli_answer['result'] == swift_cli_answer['result']
                  and rust_cli_answer['result']['deduplicated'] is False, (swift_cli_answer, rust_cli_answer))
            check('cli.retryDeduplicates', repeated['result'] == dict(rust_cli_answer['result'], deduplicated=True), repeated)
            check('reads', rust_reads == swift_reads, {'swift': swift_reads, 'rust': rust_reads})
            check('store.rows', rust_store['rows'] == swift_store['rows'],
                  {'swift': swift_store['rows'], 'rust': rust_store['rows']})
            check('store.files', rust_store['files'] == swift_store['files'],
                  sorted(set(rust_store['files'].items()) ^ set(swift_store['files'].items())))

            # Phase C: a standalone Swift daemon recovers and runs the Rust-admitted Jobs.
            jobs_state = state / 'jobs-state'
            for database in jobs_state.glob('runtime-jobs.sqlite3*'):
                database.rename(state / database.name)
            (jobs_state / 'jobs').rename(state / 'jobs')
            swift = start([str(swift_daemon), '--state-dir', str(state)], clean, swift_socket)
            handed = reads(swift_socket, rust_jobs)
            check('handoff.reads', all(handed[job]['job.status']['result']['state'] == 'preflight'
                                       for job in rust_jobs), handed)
            ran = exchange(swift_socket, 'job.run', {'jobId': rust_jobs[0]}, timeout=120)
            check('handoff.run', ran.get('ok') is True and ran['result']['state'] in TERMINAL, ran)
            after = exchange(swift_socket, 'job.show', {'jobId': rust_jobs[0]})
            journal = [json.loads(line)['kind'] for line in
                       (state / 'jobs' / rust_jobs[0] / 'journal.jsonl').read_text().splitlines()]
            check('handoff.dispatchedOnce', journal.count('stepIntent') == 1 and 'stepOutcome' in journal, journal)
            stop(swift)
            summary = {
                'result': 'PASS', 'kind': 'isolated-host-test', 'requests': len(cases),
                'identicalAnswers': len(swift_answers), 'admittedJobs': len(rust_jobs), 'checks': len(checks),
                'handoff': {'job': rust_jobs[0], 'state': ran['result']['state'],
                            'failure': after.get('result', {}).get('job', {}).get('failure'),
                            'journalKinds': journal},
                'analyzer': str(ANALYZER), 'analyzerSHA256': sha256(ANALYZER),
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

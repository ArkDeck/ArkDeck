#!/usr/bin/env python3
"""Compare Rust `job.run` with the real Swift daemon, then hand the Rust-run
store to a Swift daemon that reads every Job and published Artifact.

The plan digest covers the source Artifact's absolute path, so the owners run
over one state root in turn: the standalone Swift daemon (`--state-dir`) first,
then the isolated Rust owner (`ARKDECK_DEVELOPMENT_STATE_ROOT`) over a fresh copy
of the same sources at the same path. Both name the run oracle's analyzer
(rust/tests/fixtures/job-run-analyzer/analyzer), which answers by the first line
of its source, and each admits the oracle's requests and runs them in the
oracle's order over its socket; each CLI then runs one succeeding and one
failing Job. The 30 s production timeout lane is left to the oracle replay,
which runs it at 2 s.

The Swift daemon composes a Session publication writer and the Rust owner does
not yet, so the comparison removes the publication facts (the `finalized`
record, the publication marker, the proposal file, the marker's extra record
version) and checks them separately. Everything else must agree byte for byte
apart from the clock: every answer, every `job.status`/`job.show`, the Job index
rows, every Job's journal and record, and every Artifact index and payload.
Finally the Rust-written store is placed where a standalone Swift daemon keeps
its own: that daemon reads each Rust-run Job, keeps the parked one parked, and
reads each Rust-published Artifact back through the Swift CLI.

The analyzer copy lives outside /private: Swift `FixedExecutableResolver`
resolves a /private/tmp path to /tmp, which then fails its own physical-path
identity check (`analyzer.toolIdentityDrift`). The state root stays in
/private/tmp, where its socket path fits.

Swift children get CFFIXED_USER_HOME inside the disposable root. Host-only: no
device, installed state or hardware evidence.
"""
from __future__ import annotations

import argparse
import hashlib
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
FIXTURE = ROOT / 'rust/tests/fixtures/job-run-analyzer'
SOURCES = ('job-oracle-source', 'job-oracle-source-removed')
TIME = re.compile(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z')
# The production timeout is 30 s; its lane runs in the oracle replay instead.
SKIPPED_MODES = {'sleep'}
# A rerun of a skipped Job reruns the other parked one.
RERUN_INSTEAD = {'timedOut': 'signalled'}
# The oracle composes a 32 KiB Artifact quota; both daemons here compose 8 GiB.
QUOTA_CASES = {'quotaExceeded'}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def untimed(text: str) -> str:
    return TIME.sub('<time>', text)


def untimed_value(value):
    if isinstance(value, dict):
        return {key: untimed_value(item) for key, item in value.items()}
    if isinstance(value, list):
        return [untimed_value(item) for item in value]
    return untimed(value) if isinstance(value, str) else value


def unpublished(value):
    """An answer without Session publication facts, which only Swift composes."""
    if isinstance(value, dict):
        return {key: unpublished(item) for key, item in value.items() if key != 'sessionPublication'}
    if isinstance(value, list):
        return [unpublished(item) for item in value]
    return value


def seed(state: Path, analyzer: Path, cases: list[dict]) -> None:
    """The oracle's sources as Swift published them before any run, the one
    a case later removes rebuilt from its mode."""
    state.mkdir(mode=0o700)
    artifacts = state / 'artifacts'
    artifacts.mkdir(mode=0o700)
    for job in SOURCES:
        destination = artifacts / job
        destination.mkdir(mode=0o700)
        for source in sorted((FIXTURE / 'artifacts' / job).iterdir()):
            shutil.copyfile(source, destination / source.name)
            (destination / source.name).chmod(0o600 if source.name == 'index.json' else 0o400)
    for case in cases:
        if 'removesSourcePayload' in case:
            path = artifacts / case['removesSourcePayload']
            path.write_bytes(f"{case['mode']}\nFault log list:\n******\n".encode())
            path.chmod(0o400)
    if not analyzer.exists():
        shutil.copyfile(FIXTURE / 'analyzer', analyzer)
        analyzer.chmod(0o700)


def store(jobs_root: Path, artifacts: Path, scratch: Path) -> dict:
    """The Job index rows, every Job's files and every Artifact file, with the
    Session publication facts separated from the rest. The index is read from
    a copy, so the owner's files stay as the owner left them."""
    scratch.mkdir(mode=0o700)
    for database in jobs_root.glob('runtime-jobs.sqlite3*'):
        shutil.copyfile(database, scratch / database.name)
    connection = sqlite3.connect(scratch / 'runtime-jobs.sqlite3')
    rows, publication = [], {}
    try:
        for job, key, digest, state, sequence, version, record in connection.execute(
                'SELECT job_id, idempotency_key, request_hash, state, admission_sequence, version, '
                'initial_record_json FROM runtime_job ORDER BY admission_sequence'):
            record = json.loads(record if isinstance(record, str) else record.decode())
            marker = record.pop('sessionPublicationRecord', None)
            publication[job] = marker is not None
            rows.append({'jobId': job, 'idempotencyKey': key, 'requestHash': digest, 'state': state,
                         'admissionSequence': sequence,
                         # Swift persists the publication marker once more.
                         'version': version - (1 if marker is not None else 0),
                         'record': untimed_value(record)})
    finally:
        connection.close()
    files, proposals, finalized = {}, [], {}
    for job in sorted((jobs_root / 'jobs').iterdir()):
        for path in sorted(job.iterdir()):
            name = f'{job.name}/{path.name}'
            if path.name == 'session-manifest.proposal.json':
                proposals.append(job.name)
            elif path.name == 'journal.jsonl':
                lines = path.read_text().splitlines()
                finalized[job.name] = [json.loads(line)['kind'] for line in lines].count('finalized')
                files[name] = untimed('\n'.join(line for line in lines
                                                if json.loads(line)['kind'] != 'finalized'))
            elif path.name == 'job-record.json':
                record = json.loads(path.read_text())
                record.pop('sessionPublicationRecord', None)
                files[name] = untimed_value(record)
            else:
                files[name] = untimed(path.read_text())
    published = {}
    # Dot entries are owner namespaces and caches (the Import skeleton, the
    # payload-verification cache), not Artifacts.
    for job in sorted(path for path in artifacts.iterdir() if not path.name.startswith('.')):
        for path in sorted(job.iterdir()):
            if not path.name.startswith('.'):
                published[f'{job.name}/{path.name}'] = (untimed(path.read_text())
                                                        if path.name == 'index.json' else sha256(path))
    return {'rows': rows, 'files': files, 'artifacts': published,
            'publication': {'markers': publication, 'proposals': proposals, 'finalized': finalized}}


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
    oracle = json.loads((FIXTURE / 'cases.json').read_text())
    cases = [case for case in oracle if case.get('mode') not in SKIPPED_MODES]
    by_name = {case['name']: case for case in oracle}
    checks: list[str] = []
    children: list[subprocess.Popen] = []
    summary: dict = {}

    tools = ROOT / 'rust/target' / f'job-run-harness-{os.getpid()}'
    shutil.rmtree(tools, ignore_errors=True)
    tools.mkdir(mode=0o700, parents=True)
    with tempfile.TemporaryDirectory(prefix='xpa014-job-run-', dir='/private/tmp') as temporary:
        base = Path(temporary).resolve()
        state, home, analyzer = base / 'state', base / 'home', tools.resolve() / 'analyzer'
        home.mkdir(mode=0o700)
        clean = {key: value for key, value in os.environ.items()
                 if not key.startswith('ARKDECK_') and key != 'CFFIXED_USER_HOME'}
        clean.update(CFFIXED_USER_HOME=str(home), ARKDECK_ANALYZER_PATH=str(analyzer))

        def check(name: str, condition: bool, detail: object = None) -> None:
            if not condition:
                raise AssertionError(f'{name}: {detail}')
            checks.append(name)

        def exchange(endpoint: Path, method: str, params: dict | None = None, timeout: float = 120) -> dict:
            request = {'protocolVersion': registry['currentVersion'], 'contractIdentity': identity,
                       'id': 'job-run-harness', 'method': method}
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

        def cli(argv: list[str], env: dict, expected: int) -> dict:
            completed = subprocess.run(argv, env=env, capture_output=True, timeout=120)
            if completed.returncode != expected:
                raise AssertionError((argv, completed.returncode, completed.stdout, completed.stderr))
            return json.loads(completed.stdout)

        def cli_request(name: str, mode_case: str) -> dict:
            document = json.loads(by_name[mode_case]['submit']['requestJson'])
            document.update(requestId=f'req-harness-{name}', idempotencyKey=f'idem-harness-{name}-0001')
            return {'requestJson': json.dumps(document, separators=(',', ':'), sort_keys=True)}

        def drive(endpoint: Path, artifacts: Path, run_cli) -> tuple[dict, dict, dict]:
            """Admit every case, run them in the oracle's order, then let the
            CLI run one succeeding and one failing Job."""
            jobs = {}
            for case in cases:
                if 'submit' in case:
                    accepted = exchange(endpoint, 'job.submit', case['submit'])
                    check(f'admitted.{case["name"]}', accepted.get('ok') is True
                          and accepted['result']['jobId'] == case['params']['jobId'], accepted)
                    jobs[case['name']] = accepted['result']['jobId']
            answers = {}
            for case in cases:
                if 'removesSourcePayload' in case:
                    (artifacts / case['removesSourcePayload']).unlink()
                if 'mode' in case:
                    params = {'jobId': jobs[case['name']]}
                elif 'rerun' in case:
                    params = {'jobId': jobs[RERUN_INSTEAD.get(case['rerun'], case['rerun'])]}
                else:
                    params = case['params']
                answers[case['name']] = exchange(endpoint, 'job.run', params)
            reads = {job: {method: exchange(endpoint, method, {'jobId': job})
                           for method in ('job.status', 'job.show')} for job in jobs.values()}
            ran = {}
            for name, mode_case, expected in (('cli-answered', 'answered', 0), ('cli-empty', 'emptyResult', 1)):
                accepted = exchange(endpoint, 'job.submit', cli_request(name, mode_case))['result']
                ran[name] = run_cli(accepted['jobId'], expected)['result']
            return answers, reads, ran

        try:
            # Phase A: the standalone Swift daemon runs over the oracle's sources.
            seed(state, analyzer, cases)
            swift_socket = state / 'agentd.sock'
            swift = start([str(swift_daemon), '--state-dir', str(state)], clean, swift_socket)
            swift_answers, swift_reads, swift_cli_runs = drive(
                swift_socket, state / 'artifacts',
                lambda job, expected: cli([str(swift_cli), 'job', 'run', '--job', job, '--socket',
                                           str(swift_socket), '--output', 'json'], clean, expected))
            stop(swift)
            swift_store = store(state, state / 'artifacts', base / 'inspect-swift')
            state.rename(base / 'state-swift')

            # Phase B: the isolated Rust owner runs over a fresh copy at the same path.
            seed(state, analyzer, cases)
            rust_socket = state / 'control.sock'
            rust_env = dict(clean, ARKDECK_DEVELOPMENT_STATE_ROOT=str(state), ARKDECK_ENDPOINT=str(rust_socket))
            rust = start([str(rust_daemon)], rust_env, rust_socket)
            cli_env = dict(clean, ARKDECK_ENDPOINT=str(rust_socket), ARKDECK_DAEMON_PATH=str(rust_daemon))
            rust_answers, rust_reads, rust_cli_runs = drive(
                rust_socket, state / 'artifacts',
                lambda job, expected: cli([str(rust_cli), '--output', 'json', 'job', 'run', '--job', job],
                                          cli_env, expected))
            stop(rust)
            rust_store = store(state / 'jobs-state', state / 'artifacts', base / 'inspect-rust')

            for case in cases:
                name = case['name']
                swift_answer, rust_answer = untimed_value(swift_answers[name]), untimed_value(rust_answers[name])
                check(f'identical.{name}', unpublished(rust_answer) == unpublished(swift_answer),
                      {'swift': swift_answer, 'rust': rust_answer})
                if name not in QUOTA_CASES and 'rerun' not in case:
                    check(f'oracle.{name}', unpublished(rust_answer) == unpublished(untimed_value(case['response'])),
                          {'live': rust_answer, 'oracle': case['response']})
            check('reads', unpublished(untimed_value(rust_reads)) == unpublished(untimed_value(swift_reads)),
                  {'swift': swift_reads, 'rust': rust_reads})
            check('cli.runs', unpublished(untimed_value(rust_cli_runs)) == unpublished(untimed_value(swift_cli_runs))
                  and rust_cli_runs['cli-answered']['state'] == 'succeeded'
                  and rust_cli_runs['cli-empty']['state'] == 'failed', (swift_cli_runs, rust_cli_runs))
            check('store.rows', rust_store['rows'] == swift_store['rows'],
                  {'swift': swift_store['rows'], 'rust': rust_store['rows']})
            check('store.files', rust_store['files'] == swift_store['files'],
                  sorted(set(map(str, rust_store['files'].items())) ^ set(map(str, swift_store['files'].items()))))
            check('store.artifacts', rust_store['artifacts'] == swift_store['artifacts'],
                  sorted(set(rust_store['artifacts'].items()) ^ set(swift_store['artifacts'].items())))
            # The one composed difference: Swift publishes a Session for every
            # terminal Job, and the Rust owner has no publication writer yet.
            terminal = [row['jobId'] for row in rust_store['rows'] if row['state'] in ('succeeded', 'failed')]
            check('publication.swift', all(swift_store['publication']['markers'][job]
                                           and swift_store['publication']['finalized'][job] == 1
                                           and job in swift_store['publication']['proposals']
                                           for job in terminal), swift_store['publication'])
            check('publication.rust', not any(rust_store['publication']['markers'].values())
                  and not any(rust_store['publication']['finalized'].values())
                  and not rust_store['publication']['proposals'], rust_store['publication'])
            unavailable = {'state': 'unavailable', 'reasonCode': 'noCurrentPublicationRecord',
                           'catalogGeneration': None, 'manifestSha256': None}
            check('publication.rustReads', all(reads['job.status']['result']['sessionPublication'] == unavailable
                                               for reads in rust_reads.values()), rust_reads)

            # Phase C: a standalone Swift daemon reads the Rust-run store.
            jobs_state = state / 'jobs-state'
            for database in jobs_state.glob('runtime-jobs.sqlite3*'):
                database.rename(state / database.name)
            (jobs_state / 'jobs').rename(state / 'jobs')
            swift = start([str(swift_daemon), '--state-dir', str(state)], clean, swift_socket)
            handed = {}
            for job, reads in rust_reads.items():
                status = exchange(swift_socket, 'job.status', {'jobId': job})
                check(f'handoff.status.{job}', status.get('ok') is True and status['result']['state']
                      == reads['job.status']['result']['state'], status)
                handed[job] = status['result']['state']
            parked = [job for job, state_name in handed.items() if state_name == 'waitingForRecovery']
            check('handoff.parkedStaysParked', len(parked) == 1, handed)
            read_back = 0
            for job in [job for job, state_name in handed.items() if state_name == 'succeeded']:
                index = json.loads((state / 'artifacts' / job / 'index.json').read_text())
                for row in index['artifacts']:
                    raw = subprocess.run([str(swift_cli), 'artifact', 'read', '--job', job, '--artifact',
                                          row['artifactID'], '--raw', '--socket', str(swift_socket)],
                                         env=clean, capture_output=True, timeout=60)
                    check(f'handoff.artifact.{row["artifactID"]}', raw.returncode == 0
                          and hashlib.sha256(raw.stdout).hexdigest() == row['sha256'], (raw.returncode, raw.stderr))
                    read_back += 1
            stop(swift)
            summary = {
                'result': 'PASS', 'kind': 'isolated-host-test', 'runs': len(cases),
                'identicalAnswers': len(swift_answers), 'jobs': len(rust_reads), 'checks': len(checks),
                'states': dict(sorted(__import__('collections').Counter(handed.values()).items())),
                'handoff': {'readJobs': len(handed), 'parked': parked, 'artifactsReadBack': read_back},
                'skippedModes': sorted(SKIPPED_MODES),
                'analyzerSHA256': sha256(analyzer),
                'rustDaemonSHA256': sha256(rust_daemon), 'rustCliSHA256': sha256(rust_cli),
                'swiftDaemonSHA256': sha256(swift_daemon), 'swiftCliSHA256': sha256(swift_cli),
                'deviceDispatchCount': 0,
            }
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=30)
                if child.stderr:
                    child.stderr.close()
            shutil.rmtree(tools, ignore_errors=True)

    if args.record:
        args.record.parent.mkdir(parents=True, exist_ok=True)
        args.record.write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print(json.dumps(summary, sort_keys=True))


if __name__ == '__main__':
    main()

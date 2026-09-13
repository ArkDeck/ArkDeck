#!/usr/bin/env python3
"""Compare Rust `job.run` and `job.cancel` with the real Swift daemon, then
hand the Rust-run store to a Swift daemon that reads every Job, result,
Session and published Artifact.

The plan digest covers the source Artifact's absolute path, so the owners run
over one state root in turn: the standalone Swift daemon (`--state-dir`) first,
then the isolated Rust owner (`ARKDECK_DEVELOPMENT_STATE_ROOT`) over a fresh copy
of the same sources at the same path. Both name the run oracle's analyzer
(rust/tests/fixtures/job-run-analyzer/analyzer), which answers by the first line
of its source, and each admits the oracle's requests and runs them in the
oracle's order over its socket; each CLI then runs one succeeding and one
failing Job and reads each one's result. The 30 s production timeout lane is
left to the oracle replay, which runs it at 2 s.

Each owner then cancels: a Job admitted and cancelled before it runs closes
with zero dispatch and is published as a cancelled Session, is cancelled again
and refused a run; the Jobs that ended or parked answer a cancellation with
nothing to do; an absent Job and parameters without a string Job identity are
refused; and each CLI cancels one more Job and reads its status.

Both owners publish a Session for every terminal Job, as the standalone Swift
daemon does, each under its own Sessions root (Swift's beside its state
directory, the Rust owner's inside its root). Everything must agree byte for
byte apart from the clock and what differs by construction: every answer, every
`job.status`/`job.show`/`job.result`/`job.evidence`, the Job index rows, every
Job's journal, record and Manifest proposal, every Artifact index and payload,
and every Session file with its mode. Each owner publishes at its own clock, so
each Manifest digest and each seal differ with its times and are compared as
labels, as are each Sessions root's path, its fresh inodes and each claim's
generation. Finally the Rust-written store is placed where a standalone Swift
daemon keeps its own: that daemon reads each Rust-run Job and its result as the
Rust owner did, keeps the parked one parked, answers a cancellation and a run
of the Rust-cancelled Job as the Rust owner did, lists and shows every
Rust-published Session with nothing unaccounted, and reads each Rust-published
Artifact back through the Swift CLI.

The analyzer copy lives outside /private: Swift `FixedExecutableResolver`
resolves a /private/tmp path to /tmp, which then fails its own physical-path
identity check (`analyzer.toolIdentityDrift`). The state root stays in
/private/tmp, where its socket path fits.

Swift children get CFFIXED_USER_HOME inside the disposable root. Host-only: no
device, installed state or hardware evidence.
"""
from __future__ import annotations

import argparse
import collections
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
# A Manifest digest, and each seal over a record or Journal, covers its times.
MANIFEST_KEYS = {'manifestSha256', 'manifestSHA256'}
SEALS = {'checkpointSeal', 'journalSeal'}
ABSENT_JOB = 'job-00000000000000000000000000000000'
CANCELLED = {'cancelRequested': True}
# The requests made once every case ran, as the cancellation oracle makes
# them: each names the Job of a case (`cancelled` is admitted for it) or
# carries its own parameters, and expects `ok` or the refusal code it names.
CANCELLATIONS = (
    ('cancelBeforeRun', 'job.cancel', 'cancelled', None, 'ok'),
    ('cancelAgain', 'job.cancel', 'cancelled', None, 'ok'),
    ('runAfterCancel', 'job.run', 'cancelled', None, 'resourceConflict'),
    ('cancelSucceeded', 'job.cancel', 'answered', None, 'ok'),
    ('cancelFailed', 'job.cancel', 'emptyResult', None, 'ok'),
    ('cancelParked', 'job.cancel', 'signalled', None, 'ok'),
    ('cancelAbsent', 'job.cancel', None, {'jobId': ABSENT_JOB}, 'notFound'),
    ('cancelWithoutJob', 'job.cancel', None, {}, 'invalidParams'),
    ('cancelNumericJob', 'job.cancel', None, {'jobId': 5}, 'invalidParams'),
)


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


def without_publication(value):
    """An answer without its Session publication fact: the run oracle
    composes no publication writer."""
    if isinstance(value, dict):
        return {key: without_publication(item) for key, item in value.items()
                if key != 'sessionPublication'}
    if isinstance(value, list):
        return [without_publication(item) for item in value]
    return value


def comparable(value, parent: str | None = None):
    """A value as both owners must agree on it: times as <time>, and as labels
    what differs by construction — each Manifest digest and seal (they cover
    each owner's own times), each Sessions root's path, its fresh inodes and
    each claim's generation. A refused marker's blank or zero stays."""
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if key in MANIFEST_KEYS and isinstance(item, str):
                result[key] = '<manifest>'
            elif key == 'sha256' and parent in SEALS:
                result[key] = '<seal>'
            elif key in ('inode', 'admissionGeneration') and item not in ('', '0'):
                result[key] = f'<{key}>'
            elif key == 'path' and parent == 'root' and item:
                result[key] = '<sessions>'
            else:
                result[key] = comparable(item, key)
        return result
    if isinstance(value, list):
        return [comparable(item, parent) for item in value]
    return untimed(value) if isinstance(value, str) else value


def differences(left: dict, right: dict) -> list[str]:
    return sorted(set(map(str, left.items())) ^ set(map(str, right.items())))


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


def file_value(path: Path):
    """A JSON document, or each record of a JSON Lines file, as both owners
    must agree on it; any other file by its digest."""
    if path.suffix == '.jsonl':
        return [comparable(json.loads(line)) for line in path.read_text().splitlines()]
    if path.suffix == '.json':
        return comparable(json.loads(path.read_text()))
    return sha256(path)


def store(jobs_root: Path, artifacts: Path, sessions: Path, scratch: Path) -> dict:
    """The Job index rows, every Job's files, every Artifact file and every
    Session file with its mode, each as both owners must agree on it. The index
    is read from a copy, so the owner's files stay as the owner left them."""
    scratch.mkdir(mode=0o700)
    for database in jobs_root.glob('runtime-jobs.sqlite3*'):
        shutil.copyfile(database, scratch / database.name)
    connection = sqlite3.connect(scratch / 'runtime-jobs.sqlite3')
    rows = []
    try:
        for job, key, digest, state, sequence, version, record in connection.execute(
                'SELECT job_id, idempotency_key, request_hash, state, admission_sequence, version, '
                'initial_record_json FROM runtime_job ORDER BY admission_sequence'):
            record = json.loads(record if isinstance(record, str) else record.decode())
            rows.append({'jobId': job, 'idempotencyKey': key, 'requestHash': digest, 'state': state,
                         'admissionSequence': sequence, 'version': version,
                         'record': comparable(record)})
    finally:
        connection.close()
    files = {}
    for job in sorted((jobs_root / 'jobs').iterdir()):
        for path in sorted(job.iterdir()):
            files[f'{job.name}/{path.name}'] = file_value(path)
    published = {}
    # Dot entries are owner namespaces and caches (the Import skeleton, the
    # payload-verification cache), not Artifacts.
    for job in sorted(path for path in artifacts.iterdir() if not path.name.startswith('.')):
        for path in sorted(job.iterdir()):
            if not path.name.startswith('.'):
                published[f'{job.name}/{path.name}'] = (untimed(path.read_text())
                                                        if path.name == 'index.json' else sha256(path))
    tree = {}
    for path in sorted(sessions.rglob('*')):
        mode = oct(path.lstat().st_mode & 0o777)
        relative = path.relative_to(sessions).as_posix()
        tree[relative] = ('directory', mode) if path.is_dir() else ('file', mode, file_value(path))
    return {'rows': rows, 'files': files, 'artifacts': published, 'sessions': tree}


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

        def drive(endpoint: Path, artifacts: Path, run_cli) -> tuple[dict, dict, dict, dict]:
            """Admit every case, run them in the oracle's order, make the
            cancellation requests, then let the CLI run one succeeding and one
            failing Job, read their results and cancel one more Job."""
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
            accepted = exchange(endpoint, 'job.submit', cli_request('cancelled', 'answered'))
            check('admitted.cancelled', accepted.get('ok') is True, accepted)
            jobs['cancelled'] = accepted['result']['jobId']
            for name, method, job, params, _ in CANCELLATIONS:
                answers[name] = exchange(endpoint, method, {'jobId': jobs[job]} if job else params)
            reads = {job: {method: exchange(endpoint, method, {'jobId': job})
                           for method in ('job.status', 'job.show', 'job.result', 'job.evidence')}
                     for job in jobs.values()}
            ran = {}
            # A failed analyzer Job never publishes its required product, so
            # its result's evidence needs attention and exits 2, not 1.
            for name, mode_case, run_exit, result_exit in (('cli-answered', 'answered', 0, 0),
                                                           ('cli-empty', 'emptyResult', 1, 2)):
                accepted = exchange(endpoint, 'job.submit', cli_request(name, mode_case))['result']
                ran[name] = run_cli(['job', 'run', '--job', accepted['jobId']], run_exit)['result']
                ran[f'{name}.result'] = run_cli(['job', 'result', '--job', accepted['jobId']],
                                                result_exit)['result']
            accepted = exchange(endpoint, 'job.submit', cli_request('cli-cancelled', 'answered'))['result']
            ran['cli-cancelled'] = run_cli(['job', 'cancel', '--job', accepted['jobId']], 0)['result']
            ran['cli-cancelled.status'] = run_cli(['job', 'status', '--job', accepted['jobId']], 0)['result']
            ran['cli-cancel-absent'] = run_cli(['job', 'cancel', '--job', ABSENT_JOB], 65)['error']['code']
            return answers, reads, ran, jobs

        try:
            # Phase A: the standalone Swift daemon runs over the oracle's
            # sources and publishes its Sessions beside its state directory.
            seed(state, analyzer, cases)
            swift_socket = state / 'agentd.sock'
            swift = start([str(swift_daemon), '--state-dir', str(state)], clean, swift_socket)
            swift_answers, swift_reads, swift_cli_runs, _ = drive(
                swift_socket, state / 'artifacts',
                lambda argv, expected: cli([str(swift_cli), *argv, '--socket', str(swift_socket),
                                            '--output', 'json'], clean, expected))
            stop(swift)
            swift_store = store(state, state / 'artifacts', base / 'Sessions', base / 'inspect-swift')
            state.rename(base / 'state-swift')
            (base / 'Sessions').rename(base / 'Sessions-swift')

            # Phase B: the isolated Rust owner runs over a fresh copy at the same
            # path and publishes its Sessions inside its root.
            seed(state, analyzer, cases)
            rust_socket = state / 'control.sock'
            rust_env = dict(clean, ARKDECK_DEVELOPMENT_STATE_ROOT=str(state), ARKDECK_ENDPOINT=str(rust_socket))
            rust = start([str(rust_daemon)], rust_env, rust_socket)
            cli_env = dict(clean, ARKDECK_ENDPOINT=str(rust_socket), ARKDECK_DAEMON_PATH=str(rust_daemon))
            rust_answers, rust_reads, rust_cli_runs, rust_jobs = drive(
                rust_socket, state / 'artifacts',
                lambda argv, expected: cli([str(rust_cli), '--output', 'json', *argv], cli_env, expected))
            stop(rust)
            rust_store = store(state / 'jobs-state', state / 'artifacts', state / 'sessions',
                               base / 'inspect-rust')

            for case in cases:
                name = case['name']
                swift_answer, rust_answer = swift_answers[name], rust_answers[name]
                check(f'identical.{name}', comparable(rust_answer) == comparable(swift_answer),
                      {'swift': swift_answer, 'rust': rust_answer})
                if name not in QUOTA_CASES and 'rerun' not in case:
                    # The run oracle composes no publication writer.
                    check(f'oracle.{name}', without_publication(untimed_value(rust_answer))
                          == without_publication(untimed_value(case['response'])),
                          {'live': rust_answer, 'oracle': case['response']})
            for name, _, _, _, expects in CANCELLATIONS:
                swift_answer, rust_answer = swift_answers[name], rust_answers[name]
                check(f'identical.{name}', comparable(rust_answer) == comparable(swift_answer),
                      {'swift': swift_answer, 'rust': rust_answer})
                check(f'expected.{name}', rust_answer == {'ok': True, 'result': CANCELLED}
                      if expects == 'ok' else rust_answer.get('error', {}).get('code') == expects,
                      rust_answer)
            check('reads', comparable(rust_reads) == comparable(swift_reads),
                  {'swift': swift_reads, 'rust': rust_reads})
            check('cancelled.state', rust_reads[rust_jobs['cancelled']]['job.status']['result']['state']
                  == 'cancelled', rust_reads[rust_jobs['cancelled']])
            check('cli.runs', comparable(rust_cli_runs) == comparable(swift_cli_runs)
                  and rust_cli_runs['cli-answered']['state'] == 'succeeded'
                  and rust_cli_runs['cli-empty']['state'] == 'failed'
                  and rust_cli_runs['cli-answered.result']['evidence']['status'] == 'verified'
                  and rust_cli_runs['cli-empty.result']['evidence']['status'] == 'artifactIntegrityFailed'
                  and rust_cli_runs['cli-cancelled'] == CANCELLED
                  and rust_cli_runs['cli-cancelled.status']['state'] == 'cancelled'
                  and rust_cli_runs['cli-cancel-absent'] == 'resourceNotFound',
                  (swift_cli_runs, rust_cli_runs))
            check('store.rows', rust_store['rows'] == swift_store['rows'],
                  {'swift': swift_store['rows'], 'rust': rust_store['rows']})
            check('store.files', rust_store['files'] == swift_store['files'],
                  differences(rust_store['files'], swift_store['files']))
            check('store.artifacts', rust_store['artifacts'] == swift_store['artifacts'],
                  differences(rust_store['artifacts'], swift_store['artifacts']))
            check('store.sessions', rust_store['sessions'] == swift_store['sessions'],
                  differences(rust_store['sessions'], swift_store['sessions']))
            # Every terminal Job is published once, a cancelled one included;
            # the parked one publishes nothing; each registration advanced the
            # catalog once.
            markers = {row['jobId']: row['record'].get('sessionPublicationRecord')
                       for row in rust_store['rows']}
            terminal = [row['jobId'] for row in rust_store['rows']
                        if row['state'] in ('succeeded', 'failed', 'cancelled')]
            parked = [row['jobId'] for row in rust_store['rows'] if row['state'] == 'waitingForRecovery']
            check('publication.receipts', bool(terminal) and all(
                markers[job] and markers[job]['phase'] == 'catalogPublished'
                and markers[job]['receipt']['catalogGeneration'] for job in terminal)
                  and all(markers[job] is None for job in parked), markers)
            catalog = rust_store['sessions']['.arkdeck-retention-catalog.json'][2]
            check('publication.catalog', catalog['generation'] == len(terminal)
                  and sorted(entry['sessionId'] for entry in catalog['entries'])
                  == sorted(f'session-{job}' for job in terminal), catalog)

            # Phase C: a standalone Swift daemon reads the Rust-run store, its
            # Sessions placed where that daemon keeps its own.
            jobs_state = state / 'jobs-state'
            for database in jobs_state.glob('runtime-jobs.sqlite3*'):
                database.rename(state / database.name)
            (jobs_state / 'jobs').rename(state / 'jobs')
            (state / 'sessions').rename(base / 'Sessions')
            swift = start([str(swift_daemon), '--state-dir', str(state)], clean, swift_socket)
            handed = {}
            for job, reads in rust_reads.items():
                status = exchange(swift_socket, 'job.status', {'jobId': job})
                check(f'handoff.status.{job}', untimed_value(status) == untimed_value(reads['job.status']),
                      {'swift': status, 'rust': reads['job.status']})
                handed[job] = status['result']['state']
                # Swift verifies the Rust-published products while it reads
                # the result the Rust owner answered.
                result = exchange(swift_socket, 'job.result', {'jobId': job})
                check(f'handoff.result.{job}', untimed_value(result) == untimed_value(reads['job.result']),
                      {'swift': result, 'rust': reads['job.result']})
            parked = [job for job, state_name in handed.items() if state_name == 'waitingForRecovery']
            check('handoff.parkedStaysParked', len(parked) == 1, handed)
            # Swift answers a cancellation and a run of the Rust-cancelled Job
            # as the Rust owner did.
            for name in ('cancelAgain', 'runAfterCancel'):
                _, method, job, _, _ = next(step for step in CANCELLATIONS if step[0] == name)
                answer = exchange(swift_socket, method, {'jobId': rust_jobs[job]})
                check(f'handoff.{name}', untimed_value(answer) == untimed_value(rust_answers[name]),
                      {'swift': answer, 'rust': rust_answers[name]})
            sessions = sorted(f'session-{job}' for job in terminal)
            listed = exchange(swift_socket, 'session.list', {'pageSize': 1000})
            check('handoff.sessions', listed.get('ok') is True
                  and sorted(item['sessionId'] for item in listed['result']['items']) == sessions, listed)
            for session in sessions:
                shown = exchange(swift_socket, 'session.show', {'sessionId': session})
                check(f'handoff.session.{session}', shown.get('ok') is True
                      and shown['result']['sessionId'] == session, shown)
            # Both Artifact censuses refuse an index whose published payload is
            # gone, and the `sourceRemoved` case removed one on purpose (the
            # first Swift daemon answered from the total it had cached before).
            # The payload is put back before the storage status is read.
            for case in cases:
                if 'removesSourcePayload' in case:
                    path = state / 'artifacts' / case['removesSourcePayload']
                    path.write_bytes(f"{case['mode']}\nFault log list:\n******\n".encode())
                    path.chmod(0o400)
            storage = exchange(swift_socket, 'runtime.storage.status', {})
            usage = storage.get('result', {}).get('sessionDomain', {}).get('usage', {})
            check('handoff.storage', storage.get('ok') is True
                  and usage.get('sessionCount') == str(len(sessions))
                  and usage.get('unaccountedSessionCount') == '0', storage)
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
                'cancellations': len(CANCELLATIONS),
                'identicalAnswers': len(swift_answers), 'jobs': len(rust_reads), 'checks': len(checks),
                'states': dict(sorted(collections.Counter(handed.values()).items())),
                'sessions': len(sessions),
                'handoff': {'readJobs': len(handed), 'parked': parked, 'sessionsListed': len(sessions),
                            'artifactsReadBack': read_back},
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

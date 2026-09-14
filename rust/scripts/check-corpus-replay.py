#!/usr/bin/env python3
"""Replay a Swift oracle against the isolated Rust daemon as real processes.

One harness for every recorded oracle (CHG-2026-074 r11, prompt §5.2), in
place of a script per slice. An oracle directory under rust/tests/fixtures
holds `cases.json`, whose `exchanges` are the control requests the Swift
oracle made in order, each with Swift's answer and, for a run, the mode the
fake HDC answered in; beside it the seed a daemon needs: the adopted Target
document (`targets-state/targets.json`) and the fake HDC (`hdc`, the driver
every HDC oracle pins, and the oracle's `hdc-answers.sh`).

The harness installs the fake at `HDCOracleFake`'s fixed root under its lock,
starts `arkdeck-agentd` over a fresh isolated root
(ARKDECK_DEVELOPMENT_STATE_ROOT) with the fake as its development HDC
(ARKDECK_DEVELOPMENT_HDC_PATH), and replays over the daemon's socket every
exchange whose method the Rust daemon serves. Each answer is compared at T1:
the ok flag, the error code and details, and the result, with every time read
as <time> and what is Swift's wording or its own clock's (a refusal's message,
a Manifest digest, a pager's revision and cursor) read as a label. A listing
ordered by creation time follows the daemon's clock, not the oracle's, so each
of its pages is compared with its items counted, and once the listing ends its
items are compared across its pages and must stand in the order the listing
declares over their own times.

An agent run answers once it owns its Job and runs the Job in the background,
so the oracle orders what the daemon does not: in `mode` held the fake keeps
the Job's first call until the harness releases it, `before` heldCall waits
for that call, and `before` release lets it go and waits until the execution
record holds the Job's end, as the oracle waits. Where the oracle labels the
Job state an accepted run read, that state must not be terminal. A request
naming `<nextCursor of X>` sends the cursor exchange X's page minted. The
fake must receive the oracle's calls, in order.

The daemon is then restarted over the same root, and every Job's status,
record, result and evidence, and every execution's status, must read as they
did before; the Rust CLI reads the first Job's result and evidence as the
socket did and, for an agent oracle, every execution's status and the first
Job's Artifacts, then runs a new `observe.device@1` execution to its end as
Golden Journey 1 enters (`agent run --operation … --target …`). Two startups
are refused: a development HDC without a development root, and one named by a
relative path.

Byte equality of what the Jobs and executions leave (T0) is the in-process
replays' (`cargo test -p arkdeck-hoststore --test observe_device --test
capture_diagnostics --test agent_execution --test agent_lifecycle`), which run
on the oracle's fixed clock; this harness runs on the host's. Host-only: the fake reaches no device, and nothing installed is
read or written.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
HDC_ROOT = Path('/private/tmp/arkdeck-hdc-oracle')
HDC_LOCK = Path('/private/tmp/arkdeck-hdc-oracle.lock')
TIME = re.compile(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z')
# Swift's wording, and values that cover the owner's own clock.
LABELS = {'message', 'manifestSha256', 'snapshotRevision', 'nextCursor'}
SERVED = {'job.plan', 'job.submit', 'job.run', 'job.result', 'job.evidence', 'artifact.list',
          'agent.run', 'agent.status', 'agent.list', 'agent.abandon'}
TERMINAL = {'planned', 'succeeded', 'recovered', 'failed', 'cancelled', 'interrupted'}
# An execution that has not yet recorded its Job's end.
UNSETTLED = {'orchestrating', 'creatingJob', 'jobOwned'}
READS = ('job.status', 'job.show', 'job.result', 'job.evidence')
CURSOR = re.compile(r'<nextCursor of (.+)>')
# Listings ordered by creation time: each item's identity and time, and the order.
LISTINGS = {'artifact.list': ('artifactId', 'createdAtUtc', 'createdAtDescArtifactIdAsc'),
            'agent.list': ('executionId', 'createdAt', 'createdAtDescExecutionIdAsc')}


def comparable(value, key: str | None = None):
    if key in LABELS and isinstance(value, str):
        return f'<{key}>'
    if isinstance(value, dict):
        return {name: comparable(item, name) for name, item in value.items()}
    if isinstance(value, list):
        return [comparable(item) for item in value]
    return TIME.sub('<time>', value) if isinstance(value, str) else value


def labelled(answer: dict, recorded: dict) -> dict:
    """The Job state an accepted run read while its Job started, as a label
    where the oracle labels it; the state must not be terminal."""
    result = answer.get('result')
    if not isinstance(result, dict) or (recorded.get('result') or {}).get('jobState') != '<jobState>':
        return answer
    if result.get('jobState') in TERMINAL:
        raise AssertionError(f"an accepted run read its Job {result.get('jobState')}")
    result = dict(result, jobState='<jobState>')
    if isinstance(result.get('job'), dict):
        result['job'] = dict(result['job'], state='<jobState>', outcome='<jobState>')
    return dict(answer, result=result)


def counted(page: dict) -> dict:
    """A listing's page with its items counted, not listed."""
    return comparable(dict(page, result=dict(page['result'], items=len(page['result']['items']))))


def wait_for(condition, seconds: float, failure: str) -> None:
    deadline = time.monotonic() + seconds
    while not condition():
        if time.monotonic() > deadline:
            raise AssertionError(failure)
        time.sleep(.02)


def install_fake(fixture: Path) -> None:
    """`HDCOracleFake.install`: the driver, the oracle's answers, no calls."""
    shutil.rmtree(HDC_ROOT, ignore_errors=True)
    HDC_ROOT.mkdir(mode=0o700)
    shutil.copyfile(fixture / 'hdc', HDC_ROOT / 'hdc')
    (HDC_ROOT / 'hdc').chmod(0o700)
    shutil.copyfile(fixture / 'hdc-answers.sh', HDC_ROOT / 'hdc-answers.sh')
    (HDC_ROOT / 'hdc-invocations.log').write_bytes(b'')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', type=Path, default=ROOT / 'rust/tests/fixtures/observe-device')
    parser.add_argument('--bin-dir', type=Path, default=ROOT / 'rust/target/debug')
    parser.add_argument('--record', type=Path, help='write the summary JSON here')
    args = parser.parse_args()
    fixture = args.fixture.resolve(strict=True)
    daemon = (args.bin_dir / 'arkdeck-agentd').resolve(strict=True)
    cli = (args.bin_dir / 'arkdeck').resolve(strict=True)
    registry = json.loads((ROOT / 'Packages/ArkDeckKit/Contracts/control-protocol.json').read_bytes())
    identity = hashlib.sha256(
        json.dumps(registry, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    oracle = json.loads((fixture / 'cases.json').read_text())
    checks: list[str] = []
    children: list[subprocess.Popen] = []

    def check(name: str, condition: bool, detail: object = None) -> None:
        if not condition:
            raise AssertionError(f'{name}: {detail}')
        checks.append(name)

    def compare(name: str, answer: dict, recorded: dict, shape=comparable) -> None:
        check(name, shape(answer) == shape(recorded),
              f"\n  swift {json.dumps(shape(recorded), sort_keys=True)}"
              f"\n  rust  {json.dumps(shape(answer), sort_keys=True)}")

    def exchange(endpoint: Path, method: str, params: dict | None = None) -> dict:
        request = {'protocolVersion': registry['currentVersion'], 'contractIdentity': identity,
                   'id': 'corpus-replay', 'method': method}
        if params is not None:
            request['params'] = params
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(120)
            connection.connect(str(endpoint))
            connection.sendall(json.dumps(request, separators=(',', ':')).encode() + b'\n')
            with connection.makefile('rb') as stream:
                reply = json.loads(stream.readline(8 * 1024 * 1024 + 1))
        return {key: reply[key] for key in ('ok', 'result', 'error') if key in reply}

    def start(env: dict, endpoint: Path) -> subprocess.Popen:
        child = subprocess.Popen([str(daemon)], env=env, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.PIPE)
        children.append(child)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise AssertionError(f'arkdeck-agentd exited: {child.stderr.read().decode(errors="replace")}')
            if endpoint.exists():
                try:
                    if exchange(endpoint, 'health').get('ok'):
                        return child
                except OSError:
                    pass
            time.sleep(.05)
        raise AssertionError('arkdeck-agentd did not serve health')

    def stop(child: subprocess.Popen) -> None:
        child.send_signal(signal.SIGTERM)
        child.wait(timeout=60)

    def refused_startup(env: dict, expected: str) -> None:
        completed = subprocess.run([str(daemon)], env=env, capture_output=True, timeout=60)
        stderr = completed.stderr.decode(errors='replace')
        check(f'startup refused: {expected}', completed.returncode != 0 and expected in stderr,
              (completed.returncode, stderr))

    summary: dict = {'fixture': str(fixture.relative_to(ROOT)), 'skipped': []}
    HDC_LOCK.touch(mode=0o600, exist_ok=True)
    with open(HDC_LOCK, 'r+b') as lock, \
            tempfile.TemporaryDirectory(prefix='xpa014-corpus-replay-', dir='/private/tmp') as scratch:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            install_fake(fixture)
            base = Path(scratch).resolve()
            state = base / 'state'
            state.mkdir(mode=0o700)
            (state / 'targets-state').mkdir(mode=0o700)
            shutil.copyfile(fixture / 'targets-state/targets.json',
                            state / 'targets-state/targets.json')
            # Owner-only, as the Target owner requires and Swift wrote it.
            (state / 'targets-state/targets.json').chmod(0o600)
            endpoint = state / 'control.sock'
            clean = {key: value for key, value in os.environ.items()
                     if not key.startswith('ARKDECK_') and key != 'CFFIXED_USER_HOME'}
            env = dict(clean, ARKDECK_DEVELOPMENT_STATE_ROOT=str(state),
                       ARKDECK_ENDPOINT=str(endpoint),
                       ARKDECK_DEVELOPMENT_HDC_PATH=str(HDC_ROOT / 'hdc'))

            calls = HDC_ROOT / 'hdc-invocations.log'
            daemon_process = start(env, endpoint)
            replayed, answers, held_from = 0, {}, 0
            # The first page of the listing each page belongs to, and each
            # listing's items so far as the daemon and Swift listed them.
            listings: dict[str, str] = {}
            listed: dict[str, tuple[list, list]] = {}
            for item in oracle['exchanges']:
                name, method = item['name'], item['method']
                if method not in SERVED:
                    summary['skipped'].append(name)
                    continue
                params = dict(item['params'])
                if 'mode' in item:
                    (HDC_ROOT / 'hdc-mode').write_text(f"{item['mode']}\n")
                    if item['mode'] == 'held':
                        (HDC_ROOT / 'released').unlink(missing_ok=True)
                        held_from = len(calls.read_bytes())
                if item.get('before') == 'heldCall':
                    wait_for(lambda: len(calls.read_bytes()) > held_from, 60,
                             f'{name}: the held Job never called the fake')
                elif item.get('before') == 'release':
                    (HDC_ROOT / 'released').write_bytes(b'')
                    # As the oracle does: until the run has returned and the
                    # execution record holds the Job's end (Swift finishJob).
                    # A status read says completed as soon as the Job is
                    # terminal, before its Session is published.
                    record = state / 'agent-executions' / 'execution-{}.json'.format(
                        hashlib.sha256(params['executionId'].encode()).hexdigest())
                    wait_for(lambda: json.loads(record.read_bytes())['state'] not in UNSETTLED, 120,
                             f'{name}: the execution never recorded its Job\'s end')
                opened = name
                if isinstance(params.get('cursor'), str) and (minted := CURSOR.fullmatch(params['cursor'])):
                    params['cursor'] = answers[minted[1]]['result']['nextCursor']
                    opened = listings.get(minted[1], minted[1])
                answer = exchange(endpoint, method, params)
                answers[name] = answer
                answer = labelled(answer, item['answer'])
                if method in LISTINGS and answer.get('ok') and item['answer'].get('ok'):
                    identity_key, created_key, order = LISTINGS[method]
                    listings[name] = opened
                    compare(f'{name}: T1 page', answer, item['answer'], counted)
                    ours, swift = listed.setdefault(opened, ([], []))
                    ours += answer['result']['items']
                    swift += item['answer']['result']['items']
                    if answer['result']['nextCursor'] is None:
                        def by_id(entry: dict) -> str:
                            return entry[identity_key]
                        check(f'{opened}: T1 listing', sorted(map(comparable, ours), key=by_id)
                              == sorted(map(comparable, swift), key=by_id), (ours, swift))
                        check(f'{opened}: listing order ({order})',
                              ours == sorted(sorted(ours, key=by_id),
                                             key=lambda entry: entry[created_key], reverse=True),
                              ours)
                else:
                    compare(f'{name}: T1 answer', answer, item['answer'])
                replayed += 1
            recorded, received = (fixture / 'hdc-invocations.log').read_bytes(), calls.read_bytes()
            check('the fake received the oracle\'s calls in order', received == recorded)
            jobs = oracle['jobs']
            executions = oracle.get('executions', {})
            reads = [(run, method, {'jobId': job}) for run, job in jobs.items() for method in READS]
            reads += [(run, 'agent.status', {'executionId': execution})
                      for run, execution in executions.items()]
            before = {(run, method): exchange(endpoint, method, params)
                      for run, method, params in reads}
            stop(daemon_process)

            daemon_process = start(env, endpoint)
            for run, method, params in reads:
                check(f'{run}: {method} after restart',
                      exchange(endpoint, method, params) == before[(run, method)])
            first = next(iter(oracle['exchanges']))['name'].split('.')[0]
            cli_env = dict(clean, ARKDECK_ENDPOINT=str(endpoint), ARKDECK_DAEMON_PATH=str(daemon))
            for command, method in (('result', 'job.result'), ('evidence', 'job.evidence')):
                completed = subprocess.run(
                    [str(cli), '--output', 'json', 'job', command, '--job', jobs[first]],
                    env=cli_env, capture_output=True, timeout=120)
                envelope = json.loads(completed.stdout or b'{}')
                check(f'CLI job {command}', completed.returncode == 0
                      and envelope.get('result') == before[(first, method)]['result'],
                      (completed.returncode, completed.stderr.decode(errors='replace')))
            for run, execution in executions.items():
                completed = subprocess.run(
                    [str(cli), '--output', 'json', 'agent', 'status', '--execution-id', execution],
                    env=cli_env, capture_output=True, timeout=120)
                envelope = json.loads(completed.stdout or b'{}')
                check(f'CLI agent status {run}', completed.returncode == 0
                      and envelope.get('result') == before[(run, 'agent.status')]['result'],
                      (completed.returncode, completed.stderr.decode(errors='replace')))
            if executions:
                listed = subprocess.run(
                    [str(cli), '--output', 'json', 'artifact', 'list', '--job', jobs[first]],
                    env=cli_env, capture_output=True, timeout=120)
                page = json.loads(listed.stdout or b'{}').get('result') or {}
                direct = exchange(endpoint, 'artifact.list',
                                  {'owner': {'kind': 'job', 'id': jobs[first]}, 'pageSize': 100})
                check('CLI artifact list', listed.returncode == 0
                      and sorted(item['artifactId'] for item in page.get('items', []))
                      == sorted(item['artifactId'] for item in direct['result']['items']),
                      (listed.returncode, listed.stderr.decode(errors='replace')))
                # Golden Journey 1's entry through the Rust CLI: a new execution
                # owns its Job, which runs on the fake to its end.
                run = subprocess.run(
                    [str(cli), '--output', 'json', 'agent', 'run', '--operation', 'observe.device@1',
                     '--target', oracle['target']['targetId'], '--execution-id', 'gj1-cli',
                     '--timeout', '2m'],
                    env=cli_env, capture_output=True, timeout=300)
                envelope = json.loads(run.stdout or b'{}')
                result = envelope.get('result') or {}
                check('CLI agent run', run.returncode == 0 and envelope.get('ok') is True
                      and result.get('state') == 'completed' and result.get('jobState') == 'succeeded'
                      and result.get('evidence', {}).get('status') == 'verified',
                      (run.returncode, run.stdout[-400:], run.stderr.decode(errors='replace')))
            stop(daemon_process)

            refused_startup(dict(clean, ARKDECK_ENDPOINT=str(base / 'refused.sock'),
                                 ARKDECK_DEVELOPMENT_HDC_PATH=str(HDC_ROOT / 'hdc')),
                            'a development HDC is configured only for an isolated development root')
            refused_startup(dict(env, ARKDECK_DEVELOPMENT_HDC_PATH='arkdeck-hdc-oracle/hdc'),
                            'ARKDECK_DEVELOPMENT_HDC_PATH must be an explicit absolute path')
            summary.update(replayed=replayed, checks=len(checks),
                           invocations=hashlib.sha256(received).hexdigest())
        finally:
            # A driver still holding a call leaves once released.
            if HDC_ROOT.is_dir():
                (HDC_ROOT / 'released').write_bytes(b'')
            for child in children:
                if child.poll() is None:
                    child.kill()
                    child.wait()
            time.sleep(.5)
            shutil.rmtree(HDC_ROOT, ignore_errors=True)
    if args.record:
        args.record.write_text(json.dumps(dict(summary, checkNames=checks), indent=2) + '\n')
    print(f"PASS: {summary['fixture']}, {summary['replayed']} exchanges replayed, "
          f"{len(summary['skipped'])} not replayed, {len(checks)} checks")


if __name__ == '__main__':
    main()

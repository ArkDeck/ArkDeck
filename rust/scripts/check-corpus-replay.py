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
a Manifest digest, a snapshot revision) read as a label. The fake must receive
the oracle's calls in the oracle's order. The daemon is then restarted over the
same root, and every Job's status, record, result and evidence must read as
they did before; the Rust CLI reads the first Job's result and evidence as the
socket did. Two startups are refused: a development HDC without a development
root, and one named by a relative path.

Byte equality of what the Jobs leave (T0) is the in-process replay's
(`cargo test -p arkdeck-hoststore --test observe_device`), which runs on the
oracle's fixed clock; this harness runs on the host's. Host-only: the fake
reaches no device, and nothing installed is read or written.
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
LABELS = {'message', 'manifestSha256', 'snapshotRevision'}
SERVED = {'job.plan', 'job.submit', 'job.run', 'job.result', 'job.evidence'}
READS = ('job.status', 'job.show', 'job.result', 'job.evidence')


def comparable(value, key: str | None = None):
    if key in LABELS and isinstance(value, str):
        return f'<{key}>'
    if isinstance(value, dict):
        return {name: comparable(item, name) for name, item in value.items()}
    if isinstance(value, list):
        return [comparable(item) for item in value]
    return TIME.sub('<time>', value) if isinstance(value, str) else value


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

            daemon_process = start(env, endpoint)
            replayed = 0
            for item in oracle['exchanges']:
                name, method = item['name'], item['method']
                if method not in SERVED:
                    summary['skipped'].append(name)
                    continue
                if 'mode' in item:
                    (HDC_ROOT / 'hdc-mode').write_text(f"{item['mode']}\n")
                answer = exchange(endpoint, method, item['params'])
                check(f'{name}: T1 answer', comparable(answer) == comparable(item['answer']),
                      f"\n  swift {json.dumps(comparable(item['answer']), sort_keys=True)}"
                      f"\n  rust  {json.dumps(comparable(answer), sort_keys=True)}")
                replayed += 1
            check('the fake received the oracle\'s calls in order',
                  (HDC_ROOT / 'hdc-invocations.log').read_bytes()
                  == (fixture / 'hdc-invocations.log').read_bytes())
            jobs = oracle['jobs']
            before = {(job, method): exchange(endpoint, method, {'jobId': job_id})
                      for job, job_id in jobs.items() for method in READS}
            stop(daemon_process)

            daemon_process = start(env, endpoint)
            for (job, method), answer in before.items():
                check(f'{job}: {method} after restart',
                      exchange(endpoint, method, {'jobId': jobs[job]}) == answer)
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
            stop(daemon_process)

            refused_startup(dict(clean, ARKDECK_ENDPOINT=str(base / 'refused.sock'),
                                 ARKDECK_DEVELOPMENT_HDC_PATH=str(HDC_ROOT / 'hdc')),
                            'a development HDC is configured only for an isolated development root')
            refused_startup(dict(env, ARKDECK_DEVELOPMENT_HDC_PATH='arkdeck-hdc-oracle/hdc'),
                            'ARKDECK_DEVELOPMENT_HDC_PATH must be an explicit absolute path')
            summary.update(replayed=replayed, checks=len(checks),
                           invocations=hashlib.sha256(
                               (HDC_ROOT / 'hdc-invocations.log').read_bytes()).hexdigest())
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                    child.wait()
            shutil.rmtree(HDC_ROOT, ignore_errors=True)
    if args.record:
        args.record.write_text(json.dumps(dict(summary, checkNames=checks), indent=2) + '\n')
    print(f"PASS: {summary['fixture']}, {summary['replayed']} exchanges replayed, "
          f"{len(summary['skipped'])} not served, {len(checks)} checks")


if __name__ == '__main__':
    main()

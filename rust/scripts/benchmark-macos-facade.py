#!/usr/bin/env python3
"""SPK-1's exact UDS instrument and 30-Job fixture, for both release backends."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from bench import harness
from bench.control import ControlClient


def measure(swift, facade, soak, output):
    report = {'schemaVersion': 'xpa003-ipc-comparison/1', 'buildConfiguration': 'release',
              'hardwareEvidence': False, 'samplesPerRow': 1000, 'runsPerBackend': 3,
              'pageSize': 50, 'backends': {}}
    baseline = json.loads((ROOT / 'scripts/bench/baselines/perf-baseline-2026-09-04.json').read_text())
    report['binarySHA256'] = {key: hashlib.sha256(path.read_bytes()).hexdigest()
                             for key, path in [('swift', swift), ('facade', facade), ('soak', soak)]}
    for backend in ['swift', 'facade']:
        runs = []
        for run in range(3):
            load = harness.assert_host_is_quiet()
            root = Path(tempfile.mkdtemp(prefix='xpa-bench-', dir='/private/tmp'))
            process = None
            try:
                harness.seed_state_directory(soak, root, 6, 10, 1)
                env = {k: v for k, v in os.environ.items() if not k.startswith('ARKDECK_')}
                if backend == 'facade':
                    env.update(ARKDECK_SWIFT_DAEMON=str(swift), ARKDECK_ENDPOINT=str(root / 'agentd.sock'))
                    command = [str(facade)]
                else:
                    command = [str(swift), '--state-dir', str(root)]
                process = subprocess.Popen(command, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                deadline = time.monotonic() + 30
                while True:
                    try:
                        with ControlClient(str(root / 'agentd.sock'), 1):
                            break
                    except (OSError, RuntimeError):
                        if process.poll() is not None or time.monotonic() > deadline:
                            raise RuntimeError('isolated daemon did not become ready')
                        time.sleep(.01)
                samples = {name: [] for name in ['ipc.health', 'ipc.jobList', 'ipc.jobStatus']}
                with ControlClient(str(root / 'agentd.sock')) as client:
                    page = client.call('job.list', {'pageSize': 50})
                    if len(page['items']) != 30 or page['hasMore']:
                        raise RuntimeError('SPK-1 comparison requires exactly 30 seeded Jobs')
                    job = page['items'][0]['jobId']
                    for _ in range(1000):
                        for name, method, params in [('ipc.health', 'health', None),
                                ('ipc.jobList', 'job.list', {'pageSize': 50}),
                                ('ipc.jobStatus', 'job.status', {'jobId': job})]:
                            _, elapsed = client.timed_call(method, params)
                            samples[name].append(elapsed * 1000)
                runs.append({'loadAverage': load, 'jobCount': 30, 'rows': {
                    name: {'p95ms': sorted(values)[math.ceil(len(values)*.95)-1], 'samplesMs': values}
                    for name, values in samples.items()}})
            finally:
                if process and process.poll() is None:
                    process.terminate()
                    process.wait(timeout=30)
                # The paired authority drains after pipe EOF; never reuse its state.
                time.sleep(.3)
                shutil.rmtree(root)
        comparisons = {}
        for name in runs[0]['rows']:
            p95 = statistics.median(run['rows'][name]['p95ms'] for run in runs)
            reference = baseline['metrics'][name]['aggregate']['p95']
            comparisons[name] = {'p95ms': p95, 'spk1P95ms': reference,
                                 'increasePercent': (p95/reference - 1)*100, 'passes20Percent': p95 <= reference*1.2}
        report['backends'][backend] = {'runs': runs, 'comparison': comparisons}
        output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({name: value['comparison'] for name, value in report['backends'].items()}, indent=2))
    return all(row['passes20Percent'] for row in report['backends']['facade']['comparison'].values())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['swift', 'facade', 'soak', 'out']:
        parser.add_argument('--'+name, required=True, type=Path)
    arguments = parser.parse_args()
    sys.exit(0 if measure(arguments.swift.resolve(), arguments.facade.resolve(), arguments.soak.resolve(), arguments.out) else 1)

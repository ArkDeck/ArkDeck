"""One fixed diagnostic run; never emits a baseline candidate."""
import json
import pathlib
import shutil
import sys
from bench import baseline, clocks, harness, metrics
from bench.__main__ import _toolchain_facts

daemon, soak, output = map(pathlib.Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=False)
toolchain = _toolchain_facts(daemon, soak)
toolchain.update(runtimeKind='rust', buildConfiguration='release')
raw = output / 'diagnostic-samples.jsonl'

def record(value):
    entry = dict(atUtc=clocks.utc_now(), purpose='single-fixed-window-diagnostic',
                 runIndex=0, toolchain=toolchain, **value)
    text = baseline.serialize(entry)
    with raw.open('a') as stream:
        stream.write(json.dumps(json.loads(text), sort_keys=True) + '\n')

context = metrics.RunContext(
    daemon_executable=daemon, soak_executable=soak, runtime_kind='rust',
    cold_start_samples=50, ipc_samples=1000, idle_seconds=600,
    calibration_samples=200, seed_seconds=2, seed_jobs_per_cycle=10,
    capture_recorder=record, require_quiet=True)
root = harness.temporary_state_directory()
try:
    samples, scale = metrics.execute_run(context, root)
    result = dict(purpose='single-fixed-window-diagnostic', baselineEligible=False,
                  reason='one diagnostic run, not three-run qualification',
                  toolchain=toolchain, host=harness.host_facts(), scale=scale,
                  samples=samples,
                  summaries={key: baseline.summarize_run(values) for key, values in samples.items()})
    (output / 'diagnostic.json').write_text(baseline.serialize(result))
    print(json.dumps(result['summaries'], indent=2))
except Exception as error:
    record(dict(kind='run', status='FAILED', errorType=type(error).__name__))
    raise
finally:
    shutil.rmtree(root)

// ArkDeck GJ-5 crash probe (added 2026-07-31).
//
// This application crashes itself shortly after launch so ArkDeck's bounded
// debug loop can be exercised against a real OpenHarmony cppcrash: the harness
// scans HiLog for a fault block, and only a native fault produces one.
//
// Whether it is armed is decided by FixtureMode.MODE, not by a flag of its own.
// See FixtureMode.ets for why that consolidation happened.
//
// The delay is deliberate. `debug.hap@1` installs, starts the ability, reads
// back that the process is running and takes a five-second bounded capture; a
// crash before that would fail the deployment job instead of leaving a fault
// block in the log buffer for the *next* observer to find.

import { hilog } from '@kit.PerformanceAnalysisKit';
import crashProbe from 'libcrashprobe.so';
import { CRASH_DELAY_MS, FixtureMode, MODE } from './FixtureMode';

const DOMAIN = 0x0000;
const TAG = 'ArkDeckCrashProbe';

export function armCrashProbe(): void {
  if (MODE !== FixtureMode.crashProbe) {
    hilog.info(DOMAIN, TAG, '%{public}s', 'crash probe disabled: fixture is in traceWorkload mode');
    return;
  }
  hilog.warn(DOMAIN, TAG, 'crash probe armed: aborting in %{public}d ms', CRASH_DELAY_MS);
  setTimeout(() => {
    hilog.fatal(DOMAIN, TAG, '%{public}s', 'crash probe firing');
    crashProbe.triggerNativeCrash();
  }, CRASH_DELAY_MS);
}

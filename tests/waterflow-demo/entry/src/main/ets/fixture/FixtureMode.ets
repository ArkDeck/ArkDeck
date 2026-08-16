// Device-side fixture selector.
//
// This one application serves two loops that want opposite things from it:
//
//   crashProbe     - ArkDeck's bounded debug loop needs a real cppcrash to work
//                    on, so the app arms a probe and aborts itself ~12 s after
//                    launch. The delay is load-bearing: debug.hap@1 installs,
//                    starts the ability, reads back that the process is running
//                    and takes a bounded capture, so crashing sooner fails the
//                    deployment job instead of leaving a fault block behind.
//
//   traceWorkload  - ArkTrace's real debug loop needs the opposite: a process
//                    that stays alive for the whole capture window and does the
//                    same amount of work every run, so two traces can be
//                    compared.
//
// They are one selector rather than two independent booleans on purpose. When
// they were separate, the crash probe was on by default and silently aborted
// three ArkTrace captures mid-window before anyone noticed it was armed. A mode
// cannot be half-set.

export enum FixtureMode {
  /// Abort shortly after launch. ArkDeck's crash journey.
  crashProbe,
  /// Stay alive and drive a fixed-cadence workload. ArkTrace's trace loop.
  traceWorkload,
}

export const MODE: FixtureMode = FixtureMode.crashProbe;

// --- crashProbe parameters ---------------------------------------------------

/// Milliseconds from launch to abort. See the note above on why this is not 0.
export const CRASH_DELAY_MS: number = 12000;
/// The signature the fault block carries, and therefore what a criterion declares.
export const CRASH_SIGNATURE: string = 'SIGABRT+WaterFlowCrashProbe_RecoverBack';

// --- traceWorkload parameters ------------------------------------------------

/// Feed reload cadence. Without a driver a trace of this app is a trace of an
/// idle device, and two such traces cannot be compared.
export const RELOAD_INTERVAL_MS: number = 500;

/// Which reload strategy LazyDataSource uses.
///
/// `true` reproduces the anti-pattern: every reload answers with
/// `onDataReloaded()`, so LazyForEach discards and rebuilds every item and the
/// nested WaterFlow is re-measured in full.
///
/// `false` compares incoming rows against the previous ones by identity
/// signature and emits per-index `onDataChange` only for rows that really
/// differ, emitting nothing when the payload is identical.
///
/// Flipping this true -> false is the change ArkTrace's Phase 6 loop applies.
/// Measured on a DAYU 200 over a 10 s window at the 500 ms cadence, the
/// application process went from 2.75 percent of one CPU to 0.49 percent, with
/// 97 percent of the baseline cost on the UI thread and named ArkUI slices
/// collapsing 3,348 -> 50.
export const USE_BLANKET_RELOAD: boolean = true;

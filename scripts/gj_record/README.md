# gj_record: the Golden Journey record generator

Phase A gap G9 (`docs/design/cross-platform/windows-phase-a-runbook.md` §4.0.6). This tool
builds the redacted `arkdeck.gj-headless-rerun/1` record (headless runbook §7) mechanically from
the Runtime's own outputs. Nobody types a Runtime fact or judges `REAL_DEVICE_PASS`. The tool is
stdlib-only and runs on Windows and macOS. Run it from `scripts/`.

## 1. Capture every step

Run each published CLI command of the Journey through `capture`. It runs the `arkdeck`
executable with an argument array, stdin closed, and does three things:

- writes stdout byte for byte to `<out>/<sequence>-<step>.json`;
- appends to `<out>/journal.jsonl` the exit code, the order, the UTC times, the CLI image's
  SHA-256, and the stdout's SHA-256;
- passes the CLI's own exit code back to the caller.

```powershell
python -m gj_record capture --out D:\gj-20261005 --step facts.version -- <rc>\bin\arkdeck.exe --version --output json
python -m gj_record capture --out D:\gj-20261005 --step gj1.observe -- <rc>\bin\arkdeck.exe agent run --operation observe.device@1 --target <TGT> --execution-id gj1-20261005 --maximum-wait 5m --output json
python -m gj_record capture --out D:\gj-20261005 --step gj1.har --quiet -- <rc>\bin\arkdeck.exe agent run --operation observe.device@1 --execution-id gj1-20261005-har --maximum-wait 10m --output json
```

- **Output directory.** `<out>` must lie outside the repository, because the raw outputs carry
  serials, connect keys and paths.
- **`--quiet`.** Keeps stdout out of the console. It is the HAR crash-resume step's "discard
  stdout": the record still reads that step's exit code and `newDispatchCount`.
- **Daemon image.** For a Windows `runtime service status`, `capture` hashes the daemon image
  the status names, while that image is the one that answered. The status itself prints no
  digest.
- **Step labels.** `--step` is a label for people. Judging reads each envelope's `command`, its
  arguments and its content.

### Fixed facts (every window)

`--version`, `runtime health`, `operation list`, `runtime service status` and `runtime hdc
status`, each with `--output json`.

`runtime health` is the Runtime's Catalog digest. The Rust `operation list` answers a bare array
with no digest.
The canonical operation comparison excludes descriptors with `aliasFor`, while the
Catalog digest continues to cover every descriptor, including aliases.

### Execution IDs

Executions are found by the IDs the runbook gives them. `<d>` is the record date without dashes.

| Journey | Executions |
| --- | --- |
| GJ-1 | `gj1-<d>` observe; `gj1-<d>-capture`; `gj1-<d>-har` (no `--target`) |
| GJ-2 | `gj2-<d>` `debug.hap@1`; `gj2-<d>-capture` app-scoped `capture.diagnostics@1` with HiLog, UI Dump and Trace |
| GJ-3 | `gj3-<d>` deploy; the fixture import `gj3-<d>-fixture` (`artifact import inspect`); `gj3-<d>-rollback` with that import's lease |
| GJ-4 | `gj4-<d>` `flash.full-restore@1`; `gj4-<d>-postflight` observe |
| GJ-5 | `gj5-<d>-baseline`, `-repro`, `-repro-capture`, `-analyze`, `-isolate`, `-patch`, `-build`, `-sign`, `-verify`, `-verify-capture` and `-negative` |

### Reads the criteria need

- `job result` for every Job.
- `artifact read` for every **published** Artifact, until `eof`. The tool joins the chunks and
  checks them against that inventory row's digest and byte count. Declared `missing` products
  remain in the raw inventory without a byte read only when `byteCount == "0"`, `sha256 == ""`
  and `bytesVerified == false`, with no successful read contradicting that declaration.
  Required names must be published; truncated, unknown and inconsistent rows fail. Job blockers,
  missing-required products and capture completeness still determine failure.
- `job show` for timeline criteria, or every `job timeline` page.
- The HAR's `agent status`, `human-action show`, `agent resume`, and `human-action show` again
  after the resume.
- `runtime service restart`, then `job show` and `job result` for both GJ-1 Jobs.
- `target show` before and after the replug.
- GJ-4's `artifact import inspect --import <consumed-import-id>` and every
  `artifact read --import <consumed-import-id> --artifact <receipt-artifact-id>
  --offset <nextOffset> --max-bytes 4194304` range through `eof`. These captured
  Runtime bytes must match the original flash Job's consumed lease, target,
  binding, authority Artifact digest and the receipt's whole SHA/count.
- GJ-5's negative case: every `job list --page-size 1000` page directly before and directly after
  it.

## 2. Assemble

```powershell
python -m gj_record assemble --out D:\gj-20261005 --date 2026-10-05 `
  --runtime-source-revision <protected-main sha the RC was built from> `
  --record ..\docs\design\references\v1.6-goal\gj-headless-rerun-2026-10-05-windows.json
```

### What makes `assemble` refuse

`assemble` writes nothing when any of these holds:

- **Edited or foreign outputs:**
  - a stdout file differs from the bytes the journal hashed;
  - a file is not a published CLI envelope;
  - the journal was captured with more than one CLI image;
  - `--version` names another image.
- **Not real-device work:**
  - a plan-only step (`job plan`);
  - a Job whose `executionMode` is not `execute`;
  - a development state root, which is rehearsal only;
  - an unverified daemon image;
  - a Job observed through an HDC other than the one `runtime hdc status` shows. That
    status must show an available HDC that is also the configured one.
- **Stale Catalog:**
  - the revision is not on protected `main` (`--protected-main`, default `origin/main`);
  - `main`'s Catalog has moved since that revision;
  - `runtime health` or any Job, execution or status answer names another Catalog digest;
  - `operation list` is not that Catalog's canonical operation set.

  The expected digest is read from `rust/crates/arkdeck-contract/src/catalog_generated.rs` at
  the revision, and recomputed from its canonical JSON as `scripts/catalog_gen/generate.py`
  computes it.
- **Redaction:** the record would carry a connect key, a serial, a USB identity, a display name
  or a path the raw outputs or arguments hold, or anything shaped like a drive, UNC, home or
  `%VAR%` path, or like an `address:port`.

### The four states

The record copies named fields only: SHA-256s, IDs, counts, states and UTC times. For each
Journey, every criterion is listed with whether it held and which captured files it was read
from. The state follows mechanically:

| State | When |
| --- | --- |
| `REAL_DEVICE_PASS` | every criterion holds |
| `BLOCKED_BY_PRODUCT_DEFECT` | the first failure is a value the Runtime published; it is recorded as `firstFailingCriterion` with its raw value, or "withheld" when the value is not a plain identifier |
| `IMPLEMENTING` | the first failure is a step that was not captured |
| `NOT_STARTED` | nothing of the Journey was captured |

`operationRealDeviceCoverage` marks an operation `realDevicePass` only when a Job on this digest
succeeded with no unknown.

## Where the criteria come from

Each criterion is the headless runbook's (§2–§6), read from the field or Artifact the Rust
Runtime publishes it in. Where the runbook's prose names a fact the Rust operation does not
publish, the criterion reads the execution that does. The criterion itself is never dropped.

- **GJ-2.** `debug.hap@1` publishes no UI Dump, Trace, liveness or crash index. Those come from
  the app-scoped `capture.diagnostics@1` (`gj2-<d>-capture`), as the 2026-09-09 macOS round
  composed them.
- **GJ-5.** Liveness and the crash index come from `-repro-capture` and `-verify-capture`.
  "Exactly one new crash-index entry" is counted against `-baseline`.
- **GJ-4.** No firmware version is hard-pinned. The version witness is the unique
  `const.ohos.fullname=` declaration in `system.img` inside the consumed archive's
  whole captured Runtime bytes. Machine readback, both `firmware` and
  `const.ohos.fullname` in `post-flash-facts.json`, and the
  independent postflight observe must equal it. Missing proof stays incomplete;
  inconsistent receipt/consumption/bytes or malformed/ambiguous declarations fail.
  Filenames, caller values and the device's existing version are never witnesses.
  The flash import cap is 8 GiB, each decoded chunk is at most 4 MiB, and gzip/tar
  scanning is bounded by 64 GiB expanded bytes and 1,024 plain regular members.
  No archive is extracted or run. Identical refreshed ranges are accepted; any
  changed duplicate or refused read fails. Existing journal loading retains the
  captured JSON replies in memory; this reader does not join their decoded image
  bytes. The public `flashImage` holds only derived profile, archive SHA/count and
  version. Runtime profile, AF-W1, validated bundle, HardwareCampaign and destructive
  admission gates remain prerequisites.
  The exact ArkForge flash observation uses its declared provider/tool provenance;
  its tool SHA is not compared with HDC. Every HDC observation still requires the
  registered HDC SHA; a wrong flash operation/provider/tool/target/binding refuses.
- **GJ-3 rollback fixture (G3).** The fixture applies to the current Target only when all of
  these hold:
  - its import is the pinned digest (`ROLLBACK_FIXTURE_SHA256`);
  - it was imported for this Target at the forward leg's binding revision;
  - the Runtime's ELF validation names a build ID;
  - its ABI is the forward leg's verified loaded ABI;
  - the rollback Job consumed that import's lease;
  - the rollback Job reached `atomic-publish`.

  A different fixture is a reviewed change to the pin, not an assembly option.
- **Per-step verification.** It is read from the `job show` timeline (`verified <step> [keys]`,
  `dispatched <step>; awaiting readback`), the only place the Runtime publishes it.

The runbook's "Artifact count of the same order as 08-28" is not a mechanical criterion. The tool
checks the named Artifacts instead.

## Tests

```sh
cd scripts && python -m unittest discover -s gj_record -t .
```

The tests run on synthetic journals in a temporary git repository. They start no device, no
daemon and no CLI.

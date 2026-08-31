# Trace capture, parsing, and Timeline in ArkDeck

> Status: current (2026-08-24)
> Product specification: [`arktrace-migration-spec.md`](./arktrace-migration-spec.md)
> Parser provenance: [`arktrace-trace-streamer.md`](./arktrace-trace-streamer.md)

ArkDeck has one Trace flow. Device work is performed by the published
`capture.diagnostics@1` Runtime operation; the resulting immutable Artifact is read through the
Artifact API, verified by byte count and SHA-256, and then parsed locally. The viewer and the
`arktrace` helper never run HDC or accept a shell command.

## Open an existing trace

Use **Trace → Open Trace…**, Finder's **Open With**, drag and drop, or a recent document. ArkDeck
recognizes `.htrace`, `.ftrace`, `.systrace`, and `.trace`. Opening a new file does not replace the
current document until source validation, parser identity validation, database preparation, and
the first viewer snapshot all succeed.

The first parse may take longer because ArkDeck creates a content-addressed SQLite database and
indexes it. Later opens reuse that Ready cache only when the source hash, parser identity, schema
adapter, and cache metadata all match. Trace cache settings are in the standard macOS Settings
window.

## Capture from the app

1. Open the **Trace** workspace and select an exact Runtime target and binding.
2. Refresh the probe. Select only tags reported as supported for that target.
3. Enter a duration within the published operation bounds. Seconds provide `15s`, `30s`, `45s`,
   and `60s` shortcuts; minutes provide `1 min`, `2 min`, and `3 min`. The UI still submits only
   canonical `durationSeconds` to Runtime. The buffer remains the read-only value converged by the
   probe.
4. Start capture. Unknown total work is shown as indeterminate with elapsed time.
5. ArkDeck waits for a terminal Job, selects one exact published raw `trace.htrace`, reads it with
   sensitive access enabled, and verifies offset, EOF, byte count, and SHA-256.
6. Only after that verification does the workspace switch to the Timeline. A failed or cancelled
   capture leaves the previously opened document intact.

The global Job inspector remains the authority for stages, cancellation policy, cleanup debt, and
terminal state. A Viewer error is not evidence that device cleanup succeeded.

The target section shows the Runtime-adopted HDC tool version, for example `hdc v3.2.0f`. This is
a target/binding fact; the Trace Viewer does not run another HDC probe.

## Headless real-device capture

Use an installed, signed ArkDeck runtime for product acceptance. First inspect the current catalog
and the operation's live input description:

```bash
arkdeck runtime service status
arkdeck doctor
arkdeck target list --json
arkdeck operation describe --operation capture.diagnostics@1 --json
```

Create an absolute-path JSON file whose tags came from the same target's current Trace probe. A
minimal trace-only request is:

```json
{
  "captureHilog": false,
  "crashLogs": false,
  "durationSeconds": 10,
  "hilogFilters": [],
  "redactionProfile": "standard",
  "traceBufferKB": 8192,
  "traceCategories": ["sched", "freq", "ace", "app"],
  "uiComponentTree": false,
  "uiDump": false,
  "uiScreenshot": false
}
```

Run the exact published operation. Never put a connect key, executable, argv, or remote path in the
input file:

```bash
arkdeck agent run \
  --operation capture.diagnostics@1 \
  --target <adopted-target-id> \
  --inputs-file /absolute/path/to/trace-inputs.json \
  --json
```

If ArkDeck pauses for trust, reconnect, or target selection, perform only the reported physical
action and use the emitted `agent resume` command. Do not restart the host command with guessed
identity. A successful receipt supplies the Job ID and current Catalog digest.

Inspect and export the one exact Trace Artifact:

```bash
arkdeck artifact list --job <job-id> --allow-sensitive --json
arkdeck artifact export \
  --job <job-id> \
  --artifact <trace-artifact-id> \
  --destination /absolute/path/to/export-directory \
  --allow-sensitive \
  --json
```

The accepted entry must be named `trace.htrace`, have raw role, sensitive privacy, published status,
`application/octet-stream` media type, nonzero bytes, and a lowercase 64-character SHA-256. Treat a
duplicate candidate, `outcomeUnknown`, or unresolved cleanup residue as a failed acceptance run.

## Parse from the developer CLI

Build the helper from ArkDeck's pinned ArkTrace revision and resolve its SwiftPM output directory:

```bash
git -C <ArkTrace-checkout> checkout 91a21d1d419c5fec8c56c8b7b742002325045861
swift build --package-path <ArkTrace-checkout> --product arktrace
swift build --package-path <ArkTrace-checkout> --show-bin-path
```

Pass the pinned parser by absolute path when using a bare SwiftPM executable:

```bash
/absolute/swiftpm/bin/path/arktrace \
  --trace-streamer "$PWD/Packages/ArkDeckKit/ThirdParty/TraceStreamer/macx/trace_streamer" \
  inspect /absolute/path/to/trace.htrace

/absolute/swiftpm/bin/path/arktrace \
  --json \
  --trace-streamer "$PWD/Packages/ArkDeckKit/ThirdParty/TraceStreamer/macx/trace_streamer" \
  summary /absolute/path/to/trace.htrace
```

Available commands are `doctor`, `licenses`, `inspect`, `summary`, `processes`, `threads`, `query`,
`context`, and `analyze`. Use `arktrace --help` for closed typed filters. Global hard bounds include
`--timeout-ms`, `--max-rows`, `--max-events`, and `--max-output-bytes`; `--no-cache` creates a
session-owned ephemeral database.

The bare ArkTrace SwiftPM executable is a developer artifact, not a complete distribution: it intentionally
lacks the reviewed license and self-test resource layout, so `licenses` and `doctor --self-test`
fail closed. The App carries its own fixed parser and licenses and does not use `PATH`.

## Timeline controls

### Timeline

| Keys | Action |
|---|---|
| <kbd>W</kbd> / <kbd>S</kbd> | Zoom in / out about the pointer |
| <kbd>A</kbd> / <kbd>D</kbd> | Pan backward / forward |
| <kbd>F</kbd>, <kbd>[</kbd>, <kbd>]</kbd> | Zoom to the selected range |
| <kbd>←</kbd> / <kbd>→</kbd> | Previous / next real event in the track |
| <kbd>↑</kbd> / <kbd>↓</kbd> | Adjacent visible track |
| <kbd>Option</kbd>+<kbd>←</kbd>/<kbd>→</kbd> | Pan by ~10% of the viewport |
| <kbd>+</kbd> / <kbd>-</kbd> | Zoom about the selection or viewport center |
| <kbd>Return</kbd> · <kbd>0</kbd> · <kbd>Esc</kbd> | Select focused event · reset zoom · clear selection |
| <kbd>,</kbd> / <kbd>.</kbd> | Scroll the nearest flag back into view |
| <kbd>Ctrl</kbd>+<kbd>,</kbd> / <kbd>Ctrl</kbd>+<kbd>.</kbd> | Jump to the previous / next flag |
| <kbd>M</kbd> / <kbd>Shift</kbd>+<kbd>M</kbd> | Mark the selection — temporary / kept |
| <kbd>Ctrl</kbd>+<kbd>[</kbd> / <kbd>Ctrl</kbd>+<kbd>]</kbd> | Jump to the previous / next mark |

### Pointer, on the timeline

| Keys | Action |
|---|---|
| Drag | Select a time range; drag either edge to adjust it |
| Scroll | Pan horizontally |
| <kbd>Option</kbd> or <kbd>Ctrl</kbd> + Scroll | Zoom about the pointer |
| Pinch | Zoom about the pointer |
| Click the time ruler | Place a flag at that instant |

### Search Results

| Keys | Action |
|---|---|
| <kbd>↑</kbd> / <kbd>↓</kbd> | Previous / next match, revealing it on the timeline |
| <kbd>Return</kbd> | Go to the selected match and move focus to the timeline |

The same catalog appears under **Help → Trace Keyboard Shortcuts**. The guides and help window
are contract-tested against one code-owned catalog.

## Privacy and troubleshooting

- Trace Artifacts are sensitive and stay local. Export is explicit; no Trace path uploads data.
- Parser missing or identity drift: rebuild or restore the reviewed pinned helper. Never substitute
  a same-named executable from `PATH`.
- Parser failure after a successful device Job: preserve the immutable Artifact and inspect the
  bounded parser diagnostic. Do not rerun device capture merely to hide a host parser defect.
- Cache validation failure: ArkDeck quarantines and rebuilds derived data. Deleting or editing the
  raw Trace is not a repair.
- Empty timed events can be a truthful capability result. It is distinct from malformed schema,
  truncated probing, or parser failure and is shown separately in the UI and machine result.

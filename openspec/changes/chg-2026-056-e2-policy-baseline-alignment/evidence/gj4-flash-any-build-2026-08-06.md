# GJ-4 Flash Recovery — a build the product had never seen, flashed end to end (2026-08-06)

## Status: `REAL_DEVICE_PASS`, and the claim this change was making is now measured

The `7.0.0.37` daily dated `20260805_180512` — published the day before, enumerated nowhere in
the product, carried under the vendor's own filename — was imported, planned, confirmed and
written to a physical DAYU200. The device now reports `OpenHarmony-7.0.0.37`.

No code change was made for that build. That is the whole of what removing the per-build pins was
for, and until this run it was an argument rather than a measurement.

- Baseline: `main@d5ca6ac1`
- Catalog digest: `e2f8eb6592aaeeec37c63a01708db2325b38c798b0f8272228ba0fccc2cfd0aa` (unmoved throughout)
- Target: `TGT-958780b2ffb7`, binding revision `2`
- Archive: `8aad39a0c35c4513b28cbbf21e0c863f9670ed93c7602a59d1b44fdd0bf1da7a`, 730,766,386 bytes
- Campaign: `ECAMP-8D98078469DF51F57528D278`, attempt **1 of 16**, `disposition=succeeded`
- Job: `job-002bffb9172ead9cbb729f156677a7c1`

```
verify-image-bundle  build=OpenHarmony-7.0.0.37  sha256=8aad39a0…
campaign reservation verified before first mutation
verified enter-loader-mode / wait-loader-disconnect / wait-loader-reconnect
verified rebind-loader-identity
verified flash-partitions            ← nine partitions written
verified verify-flash-readback
verified reboot-device / wait-for-hdc
verified rebind-and-verify-build     → ART-b13d00b0b4d46addff502ad1deed4dd8
verified capture-post-flash-diagnostics
terminal: succeeded
```

`rebind-and-verify-build` is the step that closes the argument. It expected `7.0.0.37` because
that value was scanned out of the archive's `system.img`, not because anyone typed it — and the
booted device answered the same. Post-flash verification against a derived version works on real
hardware.

Device readback after the flash, from `observe.device@1`:

```json
{ "firmware": "OpenHarmony-7.0.0.37", "model": "ohos",
  "value": "OpenHarmony-7.0.0.37" }
```

## Fourteen pins, and how each was found

Every one was found by running something. None was found by reading code — several were looked
for and missed by reading, repeatedly, including by a sweep that believed itself complete.

| Layer | Pins | Found by |
|---|---|---|
| CLI import: basename, file size, upload completion | 3 | importing the archive |
| Daemon import: candidate matched by digest before reading | 1 | importing the archive |
| Engine admission, authorization facts, plan document, profile lookup | 4 | `flash plan` |
| Preflight `archiveIntegrity` | 1 | `flash preview` |
| Engine execution contexts missing the derived version | 1 | `job plan` |
| Campaign lane admitter resolving a profile by digest | 1 | **running a campaign** |
| Dispatcher comparing two compiled-in constants | 1 | running a campaign |
| Runtime host: write step and readback step | 2 | **reaching the last step before the first write** |

The last four were unreachable by any earlier path. The campaign-lane one had no injectable seam
and so no test below a live campaign could have caught it; the runtime-host pair sat behind
`enter-loader-mode`, `wait-loader-disconnect`, `wait-loader-reconnect` and
`rebind-loader-identity`, all of which had to succeed first.

Twice the product refused to run at all rather than flash something unreviewed:
`candidateRejected("scopeDrift")`, once for the fix sitting uncommitted in the working tree and
once for a stray `log/` directory a tool had dropped in the repository root. Both refusals are the
rule working — an agent does not flash a device with code nobody has reviewed — and each cost a
merge to clear, which is the only human step this journey has.

The last obstacle was not a pin at all: **the daemon was still running the previous binary.** The
CLI had been rebuilt after every fix; the flash job executes in the daemon. The error text never
changed, which is what gave it away. Rebuild the daemon after changing runtime code, or you are
verifying the code you replaced.

## What is left hardcoded, and why it does not gate anything

Two sites still resolve a profile by matching a compiled-in build:

- `RockchipRuntimeComposition:311` maps an observed firmware fingerprint to a profile label for
  the facts record, falling back to `"unknown"`. Its own comment states the rule it obeys: the
  per-request `deviceProfile` input is what authorizes a write. An unenumerated build reports
  `unknown` and is flashed anyway — which is exactly what happened here.
- `ArkDeckCLIMain:938` prints one line of `printExactPlan` when it recognises the build, and
  omits it otherwise.

Neither refuses anything, and this flash is the proof: both treated `7.0.0.37` as unknown
throughout, and it was written to the device.

## Coverage, stated honestly

Proven by execution on this device: import, plan, plan document, preview and its four preflight
checks, engine admission, campaign admission, dispatch, partition write, readback, reboot, and
post-flash verification.

Read but not executed: the `flash continue` recovery path and the reconciliation readback, both
of which are only reached when an attempt fails part-way through. If a future window has an
attempt break mid-flight, those paths get their first real exercise — and on the record of this
change, that is where a fifteenth pin would show up if one exists.

## The other journeys on the new firmware

Re-run immediately after the flash, on `7.0.0.37`:

- **GJ-1** — `observe.device@1` and `capture.diagnostics@1` both succeeded, with real
  `hilog.txt`, `ui-dump.json` and `crash-index.txt`.
- **GJ-2** — the full `debug.hap@1` chain with `cleanupPolicy: uninstall`, finishing with
  `outstandingResidueCount: 0` and its teardown legs verified.
- **GJ-3** — **fails on this firmware.** `deploy.native-library.app-owned@1` publishes the library
  and reads its hash back, then refuses at `atomic-publish` with
  `nativePublishMismatch`. The captured diagnostics decode to
  `ARKDECK_CODE_SIGN_ERROR stage=enable code=22 errno=129` and
  `ARKDECK_CODE_SIGN_ERROR stage=verify code=30 errno=61` (`ENODATA`) — fs-verity is not enabled
  on the published file.

  > **Superseded, 2026-08-06.** This section originally read "the same library on the same code
  > path passed on `7.0.0.36` hours earlier, so this is a firmware behaviour change, not a
  > regression in this work." The first clause is unverified and the second is false. The device's
  > trusted-certificate table was compared between `7.0.0.35` and `7.0.0.37`: `.37` **adds** two
  > rows and removes none, so no tightening occurred, and neither build has ever trusted the
  > certificate the GJ-3 fixture is signed with. The `errno=129` quoted above was also read after
  > cleanup and did not come from the failing call. See
  > [gj3-code-sign-2026-08-06.md](gj3-code-sign-2026-08-06.md) for the measured cause.

  The product's conduct here is the right one and worth recording: it did not report success, it
  failed closed at the step that could not be verified, it captured the subprocess diagnostics
  that name the cause, and its compensation ran. Diagnosing the firmware change is separate work.

- **GJ-5** was not re-run: its fixture is the demo app's workspace, and `ERASE-USERDATA` removed
  the installed applications. Re-running it needs the workspace fixtures re-staged first.

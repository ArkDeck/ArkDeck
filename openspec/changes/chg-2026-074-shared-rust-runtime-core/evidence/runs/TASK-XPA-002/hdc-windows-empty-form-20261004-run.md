# TASK-XPA-002 — the Windows `[Empty]` listing is a server-startup race, sanitized run record, 2026-10-04

This record feeds CHG-2026-078 r3. It is not device evidence and not acceptance. Read-only `hdc`
use as AGENTS.md (#2454) allows, with the coordinator's exclusive grant of port 8710.

## What prompted it

The Windows daemon's managed server (CHG-2026-074 TASK-XPA-005, slice S1) ran `list targets -v`
with the registered c2 `hdc.exe` and no board attached. The stdout was
`5b 45 6d 70 74 79 5d 0d 09 68 64 63 0d 0a`, that is `[Empty]` CR TAB `hdc` CR LF (14 bytes), at
2026-10-04T08:48:51Z. The server had been started about 1 s earlier.

- **The server.** `hdc.exe -s 127.0.0.1:8710 -m`, launched by `ManagedServer::launch`.
  - environment: `PATH`, `SystemRoot`, `WINDIR`, `OHOS_HDC_SERVER_PORT=8710`, `TEMP`/`TMP`;
  - suspended start into a kill-on-close Job, stdin `NUL`.
- **The client.** `hdc.exe list targets -v`, with `PATH`, `SystemRoot`, `WINDIR` and
  `OHOS_HDC_SERVER_PORT=8710`, and no `TEMP`/`TMP`.

The sampling script with the normal environment (`windows-hdc-sample.ps1`, no board) had shown
only the two UART rows (`hdc-windows-sample-20261004-run.md`). The registry (1.0.0) classified
the new form `unknown`, as a residual CR.

## Reproduction

- **Who and where.** The agent, on the Windows 11 x64 reference host, 2026-10-04 at about
  09:00–09:15Z. No board was attached.
- **Tool.** Only the registered c2 tool: DevEco Studio's `sdk\default\openharmony\toolchains\hdc.exe`,
  SHA-256 `c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e`, checked before every
  run.
- **Port.** Before the first start, 8710 had no listener (only `TIME_WAIT` entries) and no `hdc`
  process existed. Each start refused to run if anything answered on 8710.
- **One round.** A script, kept outside the repository, ran each round as follows:
  1. start the agent's own server, `hdc.exe -s 127.0.0.1:8710 -m`, stdin `NUL`, no window, with
     the managed server's reduced environment (`PATH`, `SystemRoot`, `WINDIR`,
     `OHOS_HDC_SERVER_PORT=8710`, `TEMP`/`TMP`), or with the full user environment;
  2. poll a plain TCP connect until the listener answered (the "listener-waited" rounds);
  3. run `hdc.exe list targets -v` back to back for 6 s from the spawn, each run with stdin `NUL`,
     a 15 s timeout, and `PATH`, `SystemRoot`, `WINDIR`, `OHOS_HDC_SERVER_PORT=8710`, with or
     without `TEMP`/`TMP` (or the full environment);
  4. terminate only that server and wait until nothing answered on 8710.
- **Rounds.**
  - 15 listener-waited starts: 6 with the reduced client environment without `TEMP`/`TMP` (S1's
    client), 6 with it, and 3 with the full environment for server and client.
  - 2 exploratory starts that listed without waiting for the listener. A client run before the
    listener existed waited and returned the enumerated form after about 1.5 s.
  - 473 listings in all.
- **Afterwards.** No `hdc` process and no 8710 listener remained. The coordinator was told that
  8710 was free.

## Results (the 15 listener-waited starts, 425 listings)

| Fact | Value |
| --- | --- |
| Distinct stdout forms | two, every listing exit 0 with empty stderr |
| Form A | `[Empty]` CR TAB `hdc` CR LF, hex `5b456d7074795d0d096864630d0a`, 14 bytes, byte-identical to S1's |
| Form B | `COM1` TAB TAB `UART` TAB `Ready` TAB `unknown...` TAB `hdc` CR LF, then the same with `COM2`: 66 bytes, byte-identical to the registered `uartRowsOnly` fixture |
| Starts that showed form A | 15 of 15 (51 listings) |
| Listener answered after the spawn | 0.215 to 0.891 s |
| Last form A after the spawn | 0.452 to 1.257 s |
| Last form A after the listener answered | at most 0.712 s |
| First form B after the spawn | 0.967 to 1.495 s |
| Form A after a form B listing | never |
| Effect of the environment | none: the reduced server, the client with or without `TEMP`/`TMP`, and the full environment all showed form A first and then form B |

Conclusion: form A is what the registered server answers until it has enumerated, for about the
first second after it starts. It is not an answer about devices. On a host with an attached board
the same window would very likely print the same bytes. That was not sampled: no board was
attached, so nothing here proves it either way.

Not established:

- whether a host with no serial ports prints form A permanently;
- whether a different DevEco build behaves the same.

## Sanitization

- **Committed bytes.** Form A holds no identifier, so it is committed as is, as
  `rust/tests/fixtures/hdc-windows/c2/server-startup/list-targets-server-startup.stdout.bin` (and
  an empty `.stderr.bin`).
- **UART rows.** Form B is already registered (`c2/no-board/list-targets-empty.stdout.bin`). The
  only names in it are the host's `COM1`/`COM2`, which the registry keeps.
- **Not committed.** The raw per-listing log (timings, PIDs) and the scripts stay in the agent's
  scratch space. The maintainer's raw root `%LOCALAPPDATA%\ArkDeck-samples\hdc-c2-empty-20261004`
  was read for its summary only and copied nowhere.

## Decision taken from it (CHG-2026-078 r3)

- **The ruling.** Maintainer ruling 2026-10-04 ("按建议"): register exactly the observed `[Empty]`
  form as "no device"; every other form stays `unknown`.
- **The refinement.** That recommendation was made before this evidence. The coordinator applied
  the strictly more conservative reading, which the maintainer confirms by reviewing r3:
  - form A, exactly, is `notYetObservable` (`unknown`, retryable), never "no device" and never a
    disappearance;
  - a managed start settles past it for at most 3 s, more than twice the 1.257 s maximum;
  - past the bound every observation stays `unknown`;
  - every other `[Empty]` form stays `unknown`.

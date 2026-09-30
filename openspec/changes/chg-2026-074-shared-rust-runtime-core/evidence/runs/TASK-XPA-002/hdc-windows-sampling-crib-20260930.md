# TASK-XPA-002 — Windows HDC sampling crib (maintainer-run), 2026-09-30

WM0.5 platform fact of the Windows phase
(`docs/design/cross-platform/windows-phase-agent-prompt.md` §2.2 and WM0.5 "真机采样
crib", item 1). The agent drafted this crib and the capture script
`rust/scripts/windows-hdc-sample.ps1`; **the maintainer runs it**. The agent does
not run `hdc`, does not touch the board and only processes the files handed back.

This crib is not Windows acceptance, not a Windows HDC registration and not
device evidence. It produces raw host facts for a later, separate OpenSpec
integration change (see "What this sample feeds").

## What is sampled and why

`openspec/integrations/openharmony/profile.md` registers three macOS-only HDC
authorities, none of which may be relabelled as Windows evidence
(`evidence/xpa-002-readonly-foundation.md` §"Windows HDC registration scope
needed before acceptance"):

| macOS authority | Tool | What the Windows sample must show |
| --- | --- | --- |
| Golden fixture families + production read-only probe registry | hdc `Ver: 3.2.0d` | `hdc -v` → `Ver: X`; `hdc checkserver` → `Client version:Ver: X, server version:Ver: X` |
| Device-observation registry (`deviceObservationSnapshot`) | hdc `3.2.0f` | `list targets -v`: `[Empty]` marker (CRLF), 5-column tab-separated rows (LF), `Offline`/`Connected` state, row kept as `Offline` after removal |
| Commandless supervisor observation (`serverIdentityGeneration`) | hdc `3.2.0f` | one listener on `127.0.0.1:8710` owned by the selected executable; process identity stable across commands |

For each Windows candidate the script records, for the selected `hdc.exe` only:
the exact stdout/stderr **bytes** (`*.stdout.bin`, `*.stderr.bin`), exit code,
duration, whether the pipes closed, and the 8710 listener/`hdc` process state
**before and after every command** (the per-command brackets the macOS 3.2.0f
supervisor registration lacks, `DEV-1`); plus the tool's SHA-256, size,
Authenticode status, Mark-of-the-Web, version resource and sibling DLLs, and the
`OHOS_HDC_*` environment.

## Candidates (static facts, collected without running hdc)

| | Candidate 1 | Candidate 2 |
| --- | --- | --- |
| Source channel | `hdc.exe` placed by hand in a tools directory on D: (origin not recorded on the host) | DevEco Studio's bundled `sdk\default\openharmony\toolchains\hdc.exe`, toolchains package 26.0.0.43, apiVersion 26, Beta |
| Size | 5,448,704 bytes | 5,743,104 bytes |
| SHA-256 | `f6d6c47551d976f33b0f22b17a74f345c0788e59131873aa5f75d356f5141d9b` | `c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e` |
| Authenticode | NotSigned | NotSigned |
| Mark-of-the-Web | absent | **present** |
| Version resource | winpthread's (`OriginalFilename` WinPthreadGC, 1.0.0.0), not HDC's; timestamp normalised to 2001-01-01 | same winpthread resource |
| Sibling `libusb_shared.dll` | 202,240 bytes, SHA-256 `77d35ec3e2b3be8201aaab90ea2f8470c6d960be38bd941fc8c26bfcacace73b`, NotSigned | SHA-256 `4652cf440870e8d72db17a60dbb6f8a62bb89db30aa6af8b10c35347e5942c29`, NotSigned, no MotW |

Neither SHA-256 equals the macOS 3.2.0d (`48395ba8…d260`) or 3.2.0f
(`05b2bf7a…8f83`) executables; they are different binaries by construction
(different OS), so the macOS tuples cannot be borrowed.

**Consequence.** On Windows the HDC version cannot be read from file metadata:
the only version resource belongs to the bundled winpthread, and the file
timestamp is normalised. Only `hdc -v` output names the version. A Windows tuple
must therefore identify the tool by **executable SHA-256** (plus the `-v` bytes
observed with that hash), never by path, file version or timestamp; no signature
is available to anchor it either.

## Preconditions (maintainer)

1. Windows 11 x64 reference host, PowerShell 7 (`pwsh`), a normal (non-elevated)
   terminal. No admin rights, driver installs or policy changes are needed; if
   the board only works after a driver install, stop and report it instead.
2. A checkout that contains this commit (for example `D:\src\ArkDeck` after the
   merge, or this PR's branch).
3. **Quit DevEco Studio** (and any other HarmonyOS tool) so that it neither owns
   an HDC server nor holds the USB device. Do not kill anything from a script.
4. DAYU200 **unplugged**; its normal (HDC) image on board; the USB cable to hand.
5. Output roots outside every git work tree, one new root per candidate. The
   script refuses an existing root, a root inside a git work tree, and a second
   `hdc.exe` under the same root.

## Steps

Open one `pwsh` window. Replace `<candidate-1-dir>` with the tools directory on
D: and `<DevEco install>` with the DevEco Studio installation directory.

1. Go to the checkout and set the output parent:

   ```powershell
   cd D:\src\ArkDeck
   $samples = Join-Path $env:LOCALAPPDATA 'ArkDeck-samples'
   ```

2. Check that no HDC server runs and nothing owns port 8710 (read-only):

   ```powershell
   Get-NetTCPConnection -State Listen -LocalPort 8710 -ErrorAction SilentlyContinue
   Get-Process -Name hdc, devecostudio64 -ErrorAction SilentlyContinue
   Get-ChildItem Env:OHOS_HDC* -ErrorAction SilentlyContinue
   ```

   All three should print nothing. If any prints a row, **do not kill it**: write
   down what it shows (or take a screenshot), close its owner normally (quit
   DevEco Studio), and repeat this step. If a process remains, report it to the
   agent and stop. If `OHOS_HDC_SERVER_PORT` is set, run
   `Remove-Item Env:OHOS_HDC_SERVER_PORT` in this window only.

### Candidate 1 (hand-placed hdc.exe)

3. No board (starts a server, owned by candidate 1):

   ```powershell
   $hdc = '<candidate-1-dir>\hdc.exe'
   $root = Join-Path $samples 'hdc-c1-20260930'
   pwsh -NoProfile -File .\rust\scripts\windows-hdc-sample.ps1 -HdcPath $hdc -OutputDirectory $root -Phase no-board
   ```

   It prints the `sample.json` path. A yellow `WARNING` means the phase refused
   (reason in `sample.json` → `refused`); stop and hand back the root.

4. Plug the DAYU200 in, wait until it has booted (about 30–60 s; accept an
   authorisation prompt on the board if one appears), then:

   ```powershell
   pwsh -NoProfile -File .\rust\scripts\windows-hdc-sample.ps1 -HdcPath $hdc -OutputDirectory $root -Phase board-connected
   ```

5. Unplug the DAYU200, wait about 10 s, then:

   ```powershell
   pwsh -NoProfile -File .\rust\scripts\windows-hdc-sample.ps1 -HdcPath $hdc -OutputDirectory $root -Phase board-removed
   ```

6. Stop the server this root started (**required before candidate 2**, so that
   candidate 2's client does not talk to candidate 1's server):

   ```powershell
   pwsh -NoProfile -File .\rust\scripts\windows-hdc-sample.ps1 -HdcPath $hdc -OutputDirectory $root -Phase stop-server
   ```

   It refuses unless the 8710 listener is the exact process (PID, start time,
   executable SHA-256) that step 3 started. On refusal, stop and report.

### Candidate 2 (DevEco Studio's bundled hdc.exe)

7. Keep DevEco Studio closed. Repeat step 2, then steps 3–6 with:

   ```powershell
   $hdc = '<DevEco install>\sdk\default\openharmony\toolchains\hdc.exe'
   $root = Join-Path $samples 'hdc-c2-20260930'
   ```

   Step 6 is optional for the last candidate; skipping it leaves candidate 2's
   server running until logoff or until DevEco Studio's next session reuses or
   replaces it.

### Hand back

8. Tell the agent the two roots (`%LOCALAPPDATA%\ArkDeck-samples\hdc-c1-20260930`
   and `…\hdc-c2-20260930`) and anything unusual (a prompt on the board, a driver
   dialog, a refusal, a step skipped). Do **not** paste the files into a chat,
   issue or commit: they contain connect keys (board serials) and user paths.
   Each root holds `selected-tool.sha256`, `server-started-by-sampling.json` and
   one directory per phase with `sample.json` plus the `*.stdout.bin` /
   `*.stderr.bin` of every command.

## What the agent does with the files

Only file processing on the host; no `hdc`, no board.

1. **Redact** before anything enters the repository:
   - connect keys / serials in `list targets -v` output → a same-length
     placeholder (`a` repeated, as the macOS fixtures do), keeping every other
     byte (tabs, `CR`, `LF`, state literals) unchanged; record original length;
   - no SHA-256 of raw bytes that contain a connect key is committed (it would be
     a stable device identifier — XPA-004's target ID is a hash of the serial);
     only the redacted bytes' SHA-256 and the raw byte counts;
   - user paths (`tool.path`, listener/process paths, `hdcOnPath`) →
     `%USERPROFILE%`/`%LOCALAPPDATA%`-relative or `<candidate-1-dir>`;
     account and machine names never appear; the `Zone.Identifier` content is
     reduced to `ZoneId` and the host of `HostUrl`.
2. **Compare** each candidate with the macOS-registered families:
   - `-v` stdout: `Ver: X` form, trailing bytes (LF vs CRLF), stderr empty, exit 0;
   - `checkserver` with no server vs with the server up (does it start a
     server? — read from the per-command brackets), the
     `Client version:…, server version:…` form;
   - `list targets -v` with no board: the `[Empty]` marker and its terminator
     (CRLF on macOS 3.2.0f), or zero-byte stdout (**unknown**, never empty);
   - with the board: 5 tab-separated columns (connectKey / deviceName /
     transport / state / hostTag), row terminator (LF on macOS), `Connected`
     literal, transport and hostTag literals, row byte length;
   - after removal: the row kept with state `Offline` (not deleted), and whether
     the `[Empty]` marker is absent now that the server has seen a device;
   - any `CR` inside a field, non-empty stderr, non-zero exit, timeout, or pipes
     left open after the client exited (a server inheriting the client's
     handles) — each is a Windows-specific difference to report, not to smooth;
   - server identity: exactly one 8710 listener, owned by the selected
     executable's hash, same PID and start time across all phases; which command
     started it; the listening address (`127.0.0.1` vs `0.0.0.0`/`::`).
3. **Record** a sanitized run record next to this crib
   (`hdc-windows-sample-<date>-run.md`) with both candidates' tuples
   (SHA-256, `-v` bytes, source channel, signature, MotW), the comparison table,
   and every difference from macOS stated as found. Two different builds give
   two tuples; neither is chosen here.

## What this sample feeds

A **separate OpenSpec integration change** (WM1, "Windows HDC integration
change") that registers a Windows tuple — tool version, executable SHA-256,
endpoint and output families — in `openspec/integrations/openharmony/profile.md`
and `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`, with its own Windows
registry, sanitized resources and contract tests, as
`evidence/xpa-002-readonly-foundation.md` requires. That change decides which
candidate(s) to register and which families are `supported` on Windows. This PR
registers nothing, changes no registry, fixture, parser or status line, and the
existing macOS registrations keep their scope.

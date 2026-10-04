# TASK-XPA-002 — Windows HDC samples, sanitized run record, 2026-10-04

The processed result of `hdc-windows-sampling-crib-20260930.md` ("What the agent does with the
files"). It records both Windows candidates' tuples and compares every sampled family with the
macOS registrations in `openspec/integrations/openharmony/profile.md`. It registers nothing,
chooses no candidate, and changes no registry, fixture pack, parser or status line. It is not
Windows acceptance and not device evidence for any Catalog operation. The registration belongs
to CHG-2026-078 (TASK-WHR-001/002).

## Capture

- **Who.** Captured on 2026-10-04 by the agent, at the maintainer's instruction, with
  `rust/scripts/windows-hdc-sample.ps1` (schema `arkdeck-windows-hdc-sample/v2`). AGENTS.md
  (#2454) lets a Repo Agent run `hdc` read-only for sampling. The maintainer only plugged and
  unplugged the DAYU200. The maintainer reported no board prompt and no driver dialog.
- **Host.** The Windows 11 x64 reference host, 10.0.26200, PowerShell 7.6.6.
- **Roots.** `%LOCALAPPDATA%\ArkDeck-samples\hdc-c1-20261004` and `…\hdc-c2-20261004`, with all
  four phases each (`no-board`, `board-connected`, `board-removed`, `stop-server`). Every phase
  has `refused = null`.
- **Start state.** Each candidate's `no-board` phase began with no 8710 listener, no `hdc`
  process and no `OHOS_HDC_*` variable. Candidate 1 stopped its own server before candidate 2
  started.
- **Raw files.** They stay outside the repository.

The board was a DAYU200 on its normal HDC image, on the same physical USB port throughout. The
USB sample, `TASK-XPA-004/dayu200-usb-properties-20261004-run.md`, was taken between these phases:

| Moment (seconds after the first board arrival) | HDC phase | USB phase |
| --- | --- | --- |
| board arrives (attachment A) | — | — |
| +13 | c1 `board-connected` | — |
| +21 | — | `after` |
| +53 | board removed | — |
| +75 | c1 `board-removed` | — |
| +83 | — | `removed` |
| +381 | board arrives again (attachment B) | — |
| +430 | c2 `board-connected` | — |
| +439 | — | `replugged` |
| +611 | c2 `board-removed` | — |

So candidate 1 saw attachment A and candidate 2 saw attachment B. The USB sample shows that A
enumerated on the root hub's USB 2 port (`HS10`) and B on its USB 3 port (`SS10`) of the same
physical connector. The HDC row bytes are identical for both attachments (below).

## Processing and redaction

The roots were processed with `rust/scripts/windows_sample_process.py` from `origin/main`
`a3ca03c1`. Three defects of that script were corrected **in a scratch copy only**; the script
in the repository is unchanged. They are listed under "Findings for TASK-WHR-001".

Redaction applied:

- **Connect keys.** One connect key was found: the DAYU200's, 32 characters, lower-case hex
  (digits and `a`–`f`). It is replaced by 32 `a` characters, and every other byte is kept.
  Both candidates print the same key.
- **No hash of raw key-bearing bytes.** The SHA-256 of any raw stream that held the key is not
  recorded. Only the redacted bytes' SHA-256 and the raw byte count are.
- **UART rows.** `COM1` and `COM2` are the host's serial-port names, not board serials, so they
  are kept as they are.
- **Paths and process facts.**
  - Paths become `<candidate-1-dir>` (the tools directory on D:) and `<candidate-2-dir>` (the
    DevEco Studio installation directory).
  - PIDs become labels, and process start times become seconds from the first start.
  - `Zone.Identifier` is reduced to `ZoneId`.
- **Leak scan.** Every output file was searched, with ASCII case folded, in UTF-8 and UTF-16LE,
  for:
  - the connect key, the USB serials, and the account, machine and domain names;
  - the user directory and the two tool directories;
  - every other USB device's instance suffix.

  Nothing was found.

Sanitized resources (byte-exact apart from the key, CR/LF kept; `.gitattributes` marks `*.bin`
binary): `hdc-windows-sample-20261004/c1/` and `…/c2/`, each with `tool.json`, `summary.json`
and, per phase, `sample.json` and every command's `*.stdout.bin` / `*.stderr.bin`.

## Tuples

| | Candidate 1 | Candidate 2 |
| --- | --- | --- |
| Source channel | hand-placed `hdc.exe` in a tools directory on D: (origin not recorded on the host); the only `hdc.exe` on `PATH` | DevEco Studio's bundled `sdk\default\openharmony\toolchains\hdc.exe` (toolchains 26.0.0.43, apiVersion 26, Beta); not on `PATH` |
| Executable SHA-256 | `f6d6c47551d976f33b0f22b17a74f345c0788e59131873aa5f75d356f5141d9b` | `c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e` |
| Size | 5,448,704 B | 5,743,104 B |
| `-v` stdout | `Ver: 3.2.0b` CR LF (13 B), SHA-256 `010c1760565db96305ad6e527716400299169369d2fc5f82dde583af527f994f` | `Ver: 3.2.0g` CR LF (13 B), SHA-256 `78c4d7b4ffc0bb7bb0bac0512e5fe9da25be07c481ff7a41dfc9732f7da0a424` |
| Authenticode | NotSigned | NotSigned |
| Mark-of-the-Web | absent | present, `ZoneId=3`, no `HostUrl` |
| Version resource | winpthread's (`WinPthreadGC` 1.0.0.0); last-write time 2000-12-31 16:00 UTC | the same |
| Sibling `libusb_shared.dll` | 202,240 B, `77d35ec3…ce73b`, NotSigned | 202,240 B, `4652cf44…42c29`, NotSigned |

The static facts match the crib. These are two different builds and therefore two tuples.
Neither reported version is a macOS-registered one:

- `3.2.0b` is older than the macOS golden/read-only `3.2.0d`;
- `3.2.0g` is newer than the macOS device-observation/supervisor `3.2.0f`.

## Commands, as found (both candidates)

Every command:

- exited 0;
- did not time out;
- wrote 0 bytes to stderr;
- had both pipes closed within 5 s.

So the server did not inherit the client's handles. Every stdout ends in CR LF.

| Phase / command | argv | stdout bytes | Redacted stdout SHA-256 | c1 ms | c2 ms | 8710 listeners before → after |
| --- | --- | --- | --- | --- | --- | --- |
| no-board / `version` | `-v` | 13 | c1 `010c1760…f994f`, c2 `78c4d7b4…0a424` | 359 | 85 | 0 → 0 |
| no-board / `checkserver-no-server` | `checkserver` | 56 | c1 `a5235dbb…af1b3`, c2 `653e2fe8…8c37e` | 1442 | 1439 | **0 → 1** |
| no-board / `list-targets-first` | `list targets -v` | 66 | `31ab060e…db623` | 98 | 111 | 1 → 1 |
| no-board / `list-targets-empty` | `list targets -v` | 66 | `31ab060e…db623` | 105 | 51 | 1 → 1 |
| no-board / `checkserver-server-up` | `checkserver` | 56 | as above | 110 | 117 | 1 → 1 |
| board-connected / `list-targets-board-connected` (and `-again`) | `list targets -v` | 129 | `55f6ea08dde54a798535c7350526b5a6913c2a80d9ba9a318a5b21a699bde3da` | 103 / 90 | 105 / 52 | 1 → 1 |
| board-connected / `checkserver-board-connected` | `checkserver` | 56 | as above | 108 | 83 | 1 → 1 |
| board-removed / `list-targets-board-removed` (and `-again`) | `list targets -v` | 127 | `95f2d8900e51ab1e9d51d7c8dc1144c3294a8838af20cf0083b1fbda4ba72a4e` | **877** / 64 | 141 / 167 | 1 → 1 |
| board-removed / `checkserver-board-removed` | `checkserver` | 56 | as above | 100 | 107 | 1 → 1 |
| stop-server / `kill-server` | `kill` | 20 (`Kill server finish` CR LF) | `36525257…d2f7377` | 203 | 57 | 1 → 0 |

The `list targets -v` bytes are identical for the two candidates. The redacted bytes are:

```text
no-board (66 B, both calls):
COM1<TAB><TAB>UART<TAB>Ready<TAB>unknown...<TAB>hdc<CR><LF>
COM2<TAB><TAB>UART<TAB>Ready<TAB>unknown...<TAB>hdc<CR><LF>

board-connected (129 B):
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa<TAB><TAB>USB<TAB>Connected<TAB>localhost<TAB>hdc<CR><LF>   (63 B)
COM1<TAB><TAB>UART<TAB>Ready<TAB>unknown...<TAB>hdc<CR><LF>                                  (33 B)
COM2<TAB><TAB>UART<TAB>Ready<TAB>unknown...<TAB>hdc<CR><LF>                                  (33 B)

board-removed (127 B): the same, with the USB row's state `Offline` (61 B)
```

The board-removed bytes equal the board-connected bytes with `Connected` replaced by `Offline`.
The two UART rows are byte-identical in every phase.

## Server identity (both candidates)

- **Started by.** `checkserver` with no server running started it (listeners 0 → 1 inside that
  command's bracket, process start inside the command's window). `-v` started none.
- **Exactly one listener.** There was one 8710 listener on **`127.0.0.1`** (IPv4 loopback only;
  no `0.0.0.0`, `::` or dual-stack entry). Its owner was one `hdc` process whose image SHA-256
  equals the selected tool. It is the only `hdc` process, and the capture recorded no parent PID for it (`null`).
- **Stable across phases.** The same PID and creation time held in every bracket of the
  `no-board`, `board-connected` and `board-removed` phases, across the unplug and replug.
- **Stopped by `kill`.** `kill` stopped that exact process (0 listeners, no `hdc` process
  after).

## Comparison with the macOS-registered families

| Family / fact | macOS registered | Windows c1 and c2 (as found) | Same |
| --- | --- | --- | --- |
| `version`: form | `Ver: X` | `Ver: 3.2.0b` / `Ver: 3.2.0g` | yes |
| `version`: terminator | LF (`Ver: 3.2.0d` LF, 12 B golden fixture) | **CR LF** (13 B) | **no** |
| `version`: stderr / exit / server effect | empty / 0 / — | empty / 0 / starts no server | yes |
| `healthy` `checkserver`: form | `Client version:Ver: X, server version:Ver: X` | the same, with matching client and server text | yes |
| `checkserver`: terminator | LF (golden fixture) | **CR LF** (56 B) | **no** |
| `checkserver` with no server | not registered (the macOS golden fixture is the healthy form only) | **starts a server** and still prints the healthy form | Windows-only fact |
| `list targets -v`, no device ever seen | `[Empty]` CR LF (9 B) | **no `[Empty]` marker**: two `UART` rows (`COM1`, `COM2`), state `Ready`, hostTag `unknown...` | **no** |
| Zero-byte stdout | `unknown` | not observed | n/a |
| Row delimiter | TAB | TAB | yes |
| Column count | 5 (connectKey / deviceName / transport / state / hostTag) | **6**: the macOS five plus a sixth column whose value is `hdc` on every row | **no** |
| Row terminator | LF | **CR LF** on every row | **no** |
| `deviceName` | may be empty | empty on every row | yes |
| Transport literals | `USB` | `USB`, **`UART`** | **no** |
| State literals | `Connected`, `Offline` | `Connected`, `Offline`, **`Ready`** (UART rows) | **no** |
| hostTag literals | `localhost` | `localhost` (USB row), **`unknown...`** (UART rows) | **no** |
| Row bytes, 32-character key | `Connected` 58, `Offline` 56 | `Connected` 63, `Offline` 61 (= macOS + `<TAB>hdc` + CR) | **no** |
| CR inside a field | forbidden | none once rows are split on CR LF. A parser that splits on LF only would leave CR in the sixth field | — |
| Device removal | row kept, state flipped to `Offline`, byte-identical otherwise | the same | yes |
| `[Empty]` after a device was seen | never emitted again | not observable (never emitted at all on this host) | n/a |
| Row order | presentation only | the USB row first, then `COM1`, `COM2` | — |
| Duplicate connect key | `unknown` | none | — |
| Endpoint | `127.0.0.1:8710` (supervisor 3.2.0f) | `127.0.0.1:8710` | yes |
| Listener count / owner | exactly one, owned by the selected executable | the same | yes |
| Server process identity stable | required (pre/post) | stable across all phases, closing `DEV-1` for these tuples | yes |
| Per-command brackets | missing on macOS 3.2.0f (`DEV-1`) | present for every command | Windows-only fact |

## Differences from macOS, stated as found

1. **CR LF everywhere.** Every stdout of both Windows builds is CR LF terminated: `-v`,
   `checkserver`, every `list targets -v` row and `kill`. The macOS golden `version`/`healthy`
   fixtures and the 3.2.0f device rows are LF.
2. **A sixth column.** Every `list targets -v` row has a sixth TAB-separated column, `hdc`, in
   both 3.2.0b and 3.2.0g. The macOS 3.2.0f rows have five. A 5-column parser would read every
   Windows snapshot as `unknown` (column-count mismatch).
3. **UART rows and no `[Empty]` marker.** Both builds list the host's serial ports `COM1` and
   `COM2` as `UART` targets in state `Ready` with hostTag `unknown...`, before and after any
   device. On this host `list targets -v` therefore never prints `[Empty]`. With no board the
   output is 66 bytes, never empty or zero bytes. Whether a Windows host without COM ports
   prints `[Empty]` was not observed. The macOS closed sets (`USB`; `Connected`/`Offline`;
   `localhost`) would make every Windows snapshot on this host `unknown`.
4. **`checkserver` starts a server.** With no server running, `checkserver` starts one, about
   1.44 s for both builds, and prints the healthy form. On Windows it is a server-starting
   command, not a read-only probe, unless a server already exists. `-v` starts nothing.
5. **Unchanged from macOS.**
   - Removal behaviour: the row is kept and flipped to `Offline`, byte-identical otherwise.
   - The endpoint is IPv4 loopback `127.0.0.1:8710`, with one listener owned by the selected
     executable.
   - Every command has empty stderr and exit 0.
   - The pipes close after the client exits; the spawned server inherits no handle.
6. **Timing outlier.** The first `list targets -v` after the unplug took 877 ms on candidate 1
   (64 ms on the repeat; candidate 2: 141 ms). It produced the same bytes, with no error and no
   timeout.
7. **Identical across attachments.** The DAYU200's row is byte-identical whether the board
   enumerated on the USB 2 (attachment A, c1) or USB 3 (attachment B, c2) port.

## Findings for TASK-WHR-001 (`windows_sample_process.py` at `a3ca03c1`)

The script, as committed, would produce wrong fixtures from these roots. Each of the following
was corrected in a scratch copy for this run only:

1. **`connect_keys` takes the UART rows' `COM1`/`COM2` as connect keys.** It then rewrites them
   to `aaaa` in every fixture. The fixtures would no longer show the UART rows as they are, and
   the summary would report 3 keys, of lengths 4, 4 and 32. Correction: rows whose key is
   `COM<n>` are not redacted.
2. **USB `keep_chain` matches `DEVPKEY_Device_Parent` case-sensitively.** `Parent` spells the
   root hub as `…\4&73f3995&0&0`, while its instance ID is `…\4&73F3995&0&0`. The hub chain is
   therefore dropped, and `Parent` becomes `<other-device>`. Correction: compare instance IDs
   ignoring ASCII case.
3. **USB `clean_node` empties every list that holds a backslash.** That removes
   `HardwareIds`/`CompatibleIds`, so the summary's `hardwareIds` is `[]`, along with the
   device's own entries in the hub's `Children`. Correction: filter only instance-ID-shaped
   items (`ENUM\hardware\suffix`), ignoring case.
4. **Minor: GUID labels miss their closing `>`** (`<container-1`). The copy writes
   `<container-1>`. The label is applied to every GUID-shaped value, including the public
   class and bus-type GUIDs, not only container IDs.

The leak scan of the script and the independent scan above both pass on the corrected output.

## Not decided here

- Which candidate(s) to register.
- Which families are `supported`.
- How a Windows parser treats the sixth column, the `UART`/`Ready`/`unknown...` rows and CR LF.

These belong to CHG-2026-078 and the maintainer. No macOS value was used as Windows evidence.

## Local targeted checks

| Command | Result |
| --- | --- |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | exit 0 (`check_sdd: 0 error(s), 0 warning(s)`) |
| `git diff --check` | clean |

No Rust, Swift or contract input changed, so no cargo, Swift or generator check applies. CI: the PR's run, recorded by a follow-up.

# TASK-XPA-003 — SPK-2 run record

Change: CHG-2026-074-shared-rust-runtime-core (@r6 at the time of the runs; recorded by r7).
Spike recorded here: SPK-2 (design §J.3), the feasibility gate of this task. This is a spike
record, not the task's implementation record: `TASK-XPA-003` stays `blocked` on `TASK-XPA-002`.
Host measurement only — not hardware, platform or conformance evidence (POL-VERIFY-001,
POL-MODE-001). No device was contacted. The production LaunchAgent of the developer host was
replaced by the spike listener for three windows and restored from its own plist after each.

## Environment

| Fact | Value |
| --- | --- |
| Host | macOS 26.6.2 (25G83), Darwin 25.6.0, arm64, 8 CPUs |
| Rust | 1.98.0 (`rustup` toolchain `1.98.0-aarch64-apple-darwin`), release build, no crates |
| Swift | 6.3.3 (`xcrun swiftc -O`), raw `xpc_connection_*` C API |
| Signing identities | `Developer ID Application: Hanfeng Fu (8AQTYW5FKR)`; `Apple Development: Hanfeng Fu (ZUP86546UG)` for one negative variant |
| Production App | `/Applications/ArkDeck.app` `com.arkdeck.desktop` 0.1.0, Developer ID 8AQTYW5FKR |
| Entitlements under test | `ArkDeckApp/ArkDeckApp.entitlements` blob `864bd123090f17889afd22ca6120d841f4b49712`, SHA-256 `9b6f01b786cb03bfd236d72bc8154663f4969149ee6ebd44df340bd75cbaadef`; embedded as signed: SHA-256 `05a2a2633a9d10b1add503531e89872b7cd4276b21bb3160e81363b39d744e4a` |
| Catalog digest | unchanged; nothing here publishes or dispatches an operation |
| Device | none — `Hardware required:no` for the spike |

## Artefacts (`spk-2/`)

| File | SHA-256 |
| --- | --- |
| `listener/src/main.rs` | `dc3c9271446f32dd2f3b38ced538b4ca290e1d35673c91775ba1e01570de61ad` |
| `listener/Cargo.toml` | `15c8f5131573f7bd4aaddd5d4b2906dcf5ec9795638c0db412d6bd1811828ed0` |
| `client/main.swift` | `bb6e3f94cbd3cb0573464de9a12e0a290c9587acf485d52fb0001a8766202236` |
| `client/build.sh` | `1a45af183113e3f2d023ff1dc436af5f899086829f732e72cfe4a64c2a7e02fd` |
| `client/no-mach-lookup.entitlements` | `28ca4ddb9358a1c697266c29f5f686de846c18b7e83958239037c5d8d3148c33` |
| `launchd/com.arkdeck.agentd.spk2.plist` (paths templated as `__SPK2_ROOT__`) | `8bc758da9eeac907c53025dc2c1e7de97cec3204554ef3bc492174fc2f21939e` |
| `launchd/com.arkdeck.agentd.spk2-none.plist` | `65fc731d898eac4491aaba21a4911c7b4bcbc7e5fdf7f81f8339e0878f196feb` |
| `run-spike.sh` | `cd42945ac86d57d2ddfd0da8cc25bf2eee1905c81cdf420d437bf2fd66905471` |
| `results/a-client-roundtrips.json` (headline, window 1) | `3e933b583ab104183be0e39d6d93bd4d586f2c2c092ea8c76c742d2fc90e7379` |
| `results/a2-roundtrips-req.json` / `a2-roundtrips-noreq.json` (window 3) | `69c05f3c6f4c1760bf46b1d077c57290073ca2ccbb48d82232250a7815966cef` / `ca0de9d2684b074268df28b61517bbbd9a3138789686e636c5b7421e2ff32bb4` |
| `results/a2-fresh-req.json` / `a2-fresh-noreq.json` | `9f2e880bf9885ff65afc89da46c69bce8cac9f70f52e0375fd5ae91113b9a97c` / `fe54058fbfd103dd57c9babb063e6be67256ed095b650ef18e568c655663d2ba` |
| `results/listener-window1.stderr.log` / `-window2-` / `-window3-` / `listener-none-window3.stderr.log` | `f5b5071ad8789f86d5d4e2ac83e255ec481b15696b8315b0553ae194dd30a7cc` / `a5830494d459fb398dabc8cbdcca368b61cb05ccf67b24841da22048f0670667` / `b6edc288d59b7044dfc9e9886b615c4bcb7b52b172e7525822f76ef265696595` / `37d9c405fdf610564c3eb65b96daf5693b2301e7c565bba583b3289533131dbb` |
| signed listener binary of window 3 (not committed) | `90e8dcefe57cbd0d837b91a0b736889d40d09d442d65ac879de68fd448ea7222` |

The other `results/*.json` files (probes, sizes, pins, NSXPC baselines) are committed next to
these; each carries the client's self-reported identity and pid, which pair with the listener
logs. Scratchpad paths are templated as `__SPK2_ROOT__` and the home directory as `~`.

## SPK-2 result

`PASS`. Full report: `docs/design/cross-platform/spk-2-macos-libxpc-mach-service.md`.

| Criterion | Evidence |
| --- | --- |
| connect without entitlement changes | variants A and A2 (Developer ID, sandbox, byte-identical entitlements): 1,000 replies each, 0 errors; variant D (same, minus the mach-lookup exception): `XPC_ERROR_CONNECTION_INVALID` in 0.056 ms, no accept in the listener log; production `ArkDeck.app` accepted (`listener-window3.stderr.log`, pid 45724) |
| wrongly signed peer refused | ad-hoc sandboxed (B), Developer ID with another identifier (C), bare ad-hoc (F): listener `XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT` "Peer Forbidden", 0 messages; client `XPC_ERROR_CONNECTION_INTERRUPTED` then `_INVALID` within 1.2–6.1 ms; same-team Apple Development (E) admitted by the OU-only requirement |
| 1,000 round trips p95 ≤ 8 ms | window 1: p50 0.0110 / p95 0.0129 / p99 0.0150 ms; window 3: p95 0.0165 ms (requirement on), 0.0155 ms (off); 4 MiB replies p95 2.64–4.79 ms |

## Commands run, and their results

| Command | Result |
| --- | --- |
| `cargo +1.98.0 build --release` (listener) | exit 0; two dead-code warnings in the first build, none after the window-3 edit |
| `codesign --force --sign "Developer ID Application: …" --identifier com.arkdeck.spk2-listener --options runtime` | exit 0; `codesign --verify --strict` exit 0 |
| `sh client/build.sh` (six variants, `codesign --verify --strict` each) | exit 0 |
| `csreq -r='<requirement>' -t` on the window-3 requirement | exit 0; on the PlistBuddy-mangled window-2 text: exit 1, `Requirement syntax error` |
| `run-spike.sh baseline` (NSXPC vs the production Swift daemon, before window 1) | `runtime.storage.status`@2.0.0 persistent p95 0.797 ms, per-request p95 0.789 ms; `target.list`@1.0.0 persistent p95 0.243 ms, per-request p95 0.436 ms; 0 errors, 0 refusals |
| window 1: `swap-in`, `measure` (A roundtrips / fresh / sizes / pin-right / pin-wrong / C / F), `swap-out`, `verify` | A: exit 0 for all seven; B, D, E stalled at sandbox initialisation (see below) and were killed; production restored 05:41:21Z; `health ok=True` after the socket reappeared |
| window 2 | not counted: the listener's requirement string had lost its quotes (`requirementSet=22`, EINVAL) and every peer was cancelled; only D's result (no accept, `_INVALID` in 0.026 ms) is independent of the requirement and is kept as `d-nolookup-probe2.json` |
| window 3: `swap-in`, B / C / D / E / F probes, A2 roundtrips / fresh / sizes / pin-right / pin-wrong, `ArkDeck.app` launched 8 s and quit, requirement-off plist bootstrapped, A2 fresh / roundtrips, `swap-out`, `verify` | exit 0 for all fourteen client runs; production restored 05:55:20Z; `UDS health ok=True status=ok rtt=1.832 ms` |
| `launchctl print gui/501/com.arkdeck.agentd` after each restore | `program = …/Helpers/ArkDeckAgent.app/Contents/MacOS/arkdeck-agentd`, `state = running` |

Production-daemon windows (UTC): 05:24:48–05:41:21 (window 1), 05:48:16–05:49:54 (window 2),
05:54:55–05:55:20 (window 3). The App was not running during any window except the two
deliberate eight-second launches (windows 2 and 3); the second is the one recorded above.

## Deviations and defects in the spike itself

- Variants B, D and E, first built under A's bundle identifier with a different signature or
  entitlement set, hung before `main` in `_libsecinit_appsandbox` (`results/b-adhoc-hang-sample.txt`);
  each signed variant now has its own identifier. Cause not proven from the unified log.
- An attempt to remove the spike's own sandbox container with `rm -rf` was refused on the
  protected metadata and left variant A unable to start; A2 (`com.arkdeck.spk2-client2`)
  replaced it. The `com.arkdeck.spk2-*` containers remain under `~/Library/Containers`.
- `PlistBuddy -c Set` stripped the quotes of the requirement string (window 2); the plists are
  written with `plistlib` and validated with `csreq` since.

## AC conclusion

- XPA-AC-6 (local IPC identity, XPC leg): the wrongly signed XPC peer is refused before any
  handler runs, on the host, by libxpc; the task's own acceptance still runs this against the
  façade in its black-box suite. Not claimed as satisfied for the task.
- XPA-AC-5 (IPC budgets): the raw Mach transport with a trivial handler is ≥ 10× below the
  cheapest SPK-1 UDS row; the façade's forwarding overhead budget is derivable from the numbers
  above. Not a baseline row; SPK-1's harness never declared the XPC leg (its documented gap).
- `TASK-XPA-003` status: still `blocked` (awaits `TASK-XPA-002` and maintainer review of the
  change); the SPK-2 condition in its status line is met.

## Golden Journey

Not applicable. No Golden Journey hop is advanced and no `REAL_DEVICE_PASS` is claimed.

## Stop condition

Not triggered: no authority or durable write exists in the listener, no entitlement was
widened, and no reply claimed zero dispatch for a frame the listener had answered.

# SPK-2 — a Rust process vends the launchd Mach service

Spike of `CHG-2026-074-shared-rust-runtime-core`; results recorded under the task it unlocks,
`TASK-XPA-003`. Design input: `docs/design/cross-platform/rust-core-cross-platform-architecture.md`
sections F.2 (IPC identity), J.3 (spike table), K (risk R3) and L.1 items 3 and 6.
Run record: `openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-003/spk-2-run.md`.
Sources, LaunchAgent templates, raw results and listener logs:
`openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-003/spk-2/`.

> Host measurement only. Nothing here is hardware, platform or conformance
> evidence (POL-VERIFY-001, POL-MODE-001). No device was contacted. The
> production LaunchAgent of the developer host was booted out for three windows
> so that a Rust process could hold the `com.arkdeck.agentd` Mach service, and
> was bootstrapped back from its own untouched plist after each window.

## Verdict

**SPK-2 passes all three criteria of the spike table.**

| Criterion (design §J.3) | Result |
| --- | --- |
| The sandboxed App connects with the existing entitlements, none added | A client bundle signed with the App's Developer ID and the byte-identical `ArkDeckApp/ArkDeckApp.entitlements` ran in its App Sandbox container and completed 1,000 round trips with zero errors. The same bundle without the one `mach-lookup.global-name` exception never reached the listener (`XPC_ERROR_CONNECTION_INVALID` in 0.056 ms). The production `ArkDeck.app` (`com.arkdeck.desktop`, unmodified) connected too and passed the requirement. |
| A wrongly signed peer is refused | An ad-hoc signed sandboxed bundle, a Developer ID bundle with another identifier and a bare unsandboxed tool were each refused by libxpc before their first frame reached the handler (`XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT`, description `Peer Forbidden`); the listener logged zero messages from them. |
| 1,000 round trips p95 ≤ 8 ms | p50 0.011 ms, p95 0.013 ms, p99 0.015 ms, max 0.030 ms on a persistent connection (119-byte request, 112-byte reply). A second run on a second client identity: p95 0.017 ms. Even a 4 MiB reply stays at p95 2.6–4.8 ms. |

Neither failure condition occurred: no new entitlement was needed, and the App-facing
semantics the design needs (one request frame in, one response frame out, refusal before dispatch)
are reproduced without NSXPC.

## Environment

| Fact | Value |
| --- | --- |
| Host | macOS 26.6.2 (25G83), Darwin 25.6.0, arm64, 8 CPUs; one-minute load 3–4 at the start of each window |
| Listener | Rust 1.98.0 (`cargo +1.98.0 build --release`), no third-party crate, signed `Developer ID Application: Hanfeng Fu (8AQTYW5FKR)` as `com.arkdeck.spk2-listener`, hardened runtime |
| Client | Swift 6.3.3 (`xcrun swiftc -O`), `import XPC`, raw `xpc_connection_*` C API; one binary packaged into six identities (table below) |
| launchd | the production job `gui/501/com.arkdeck.agentd` booted out; a spike plist with the same `Label` and `MachServices` key bootstrapped in its place; production bootstrapped back from `~/Library/LaunchAgents/com.arkdeck.agentd.plist` |
| Production App | `/Applications/ArkDeck.app`, `com.arkdeck.desktop` 0.1.0, Developer ID 8AQTYW5FKR, hardened runtime |
| Entitlements under test | `ArkDeckApp/ArkDeckApp.entitlements` at blob `864bd123090f17889afd22ca6120d841f4b49712`, SHA-256 `9b6f01b786cb03bfd236d72bc8154663f4969149ee6ebd44df340bd75cbaadef`, copied byte for byte |
| Clock | `CLOCK_UPTIME_RAW`; percentiles by nearest rank, as SPK-1 |
| Device | none |

## What was built

**Listener** (`spk-2/listener/src/main.rs`, about 500 lines). `xpc_connection_create_mach_service`
with `XPC_CONNECTION_MACH_SERVICE_LISTENER`; for every new peer connection it checks
`xpc_connection_get_euid` against its own euid (design §F.2 layer one), calls
`xpc_connection_set_peer_code_signing_requirement` once before `xpc_connection_activate` (layer
two), and answers each message dictionary `{frame: data, pad?: uint64}` with a reply dictionary
`{frame: data, serial: uint64}` or `{error: string}`. A frame is refused structurally when it is
empty, larger than 4 MiB (design §F.2 frame cap) or not brace-delimited; the listener never
parses the JSON beyond copying the request `id` into its canned response. Event-handler blocks
are laid out by hand per the public Block ABI (`_NSConcreteStackBlock`, a plain-data capture,
no copy/dispose helper): libxpc `Block_copy`s them, so the peer connection pointer and the
facts logged at accept time travel with the block, which is the only way to attribute an
error event (they carry no connection) to a peer. Every accept, message, refusal and error is
one JSON line on stderr, which launchd's `StandardErrorPath` turns into the run log.

**Client** (`spk-2/client/main.swift`). Modes `roundtrips`, `fresh` (a new connection per
request, the App's `NSXPCConnection`-per-request pattern today), `sizes`, `probe` (one request,
bounded wait, reports reply / error / timeout) and `nsxpc` (the same request over
`NSXPCConnection` against whatever daemon holds the service). It reports its own identity from
the Security framework (`SecCodeCopySigningInformation`: identifier, Team ID, certificate chain,
entitlement keys) and the sandbox container it runs in, so every result pairs with the listener
log by pid.

| Variant | Identifier | Signature | Entitlements | Purpose |
| --- | --- | --- | --- | --- |
| A / A2 | `com.arkdeck.spk2-client` / `com.arkdeck.spk2-client2` | Developer ID 8AQTYW5FKR, hardened runtime | production file, byte-identical | the expected client |
| B | `com.arkdeck.spk2-adhoc` | ad-hoc | production file | fails `anchor apple generic` |
| C | `com.arkdeck.spk2-impostor` | Developer ID 8AQTYW5FKR | production file | fails the `identifier` clause |
| D | `com.arkdeck.spk2-nolookup` | Developer ID 8AQTYW5FKR | production file minus the `mach-lookup.global-name` exception | shows the exception is what grants the lookup |
| E | `com.arkdeck.spk2-devcert` | Apple Development ZUP86546UG (Team 8AQTYW5FKR) | production file | same team, development certificate |
| F | `com.arkdeck.spk2-bare` | ad-hoc, no bundle | none (not sandboxed) | what any local process can do |

The listener's requirement for the measured windows was
`anchor apple generic and certificate leaf[subject.OU] = "8AQTYW5FKR" and (identifier "…" or …)`
naming A, A2, B, D, E and `com.arkdeck.desktop`: the same shape as the production
`ArkDeckHelperIdentity.daemonCodeRequirement`, so B fails only on its anchor, C only on its
identifier, and D never reaches the requirement at all.

## Results

### Connecting with the existing entitlements

| Client | Sandbox container | Outcome | Time to outcome |
| --- | --- | --- | --- |
| A (`spk2-client`) | yes | 1,000 replies, 0 errors, every reply carries the request id | see round trips |
| A2 (`spk2-client2`) | yes | 1,000 replies, 0 errors | see round trips |
| D (no lookup exception) | yes | `XPC_ERROR_CONNECTION_INVALID`; the listener never saw a connection from that pid | 0.056 ms |
| `ArkDeck.app` (production, NSXPC) | yes | connection accepted, requirement satisfied, six NSXPC messages received | — |

The one entitlement the App already carries is therefore both necessary and sufficient for a
launchd-vended Mach service held by a Rust process; nothing about the vending process's language
or framework is visible to the sandbox.

### Refusing wrongly signed peers

| Peer | Listener log | Client sees | Time |
| --- | --- | --- | --- |
| B ad-hoc, sandboxed | `peer.accepted` then `XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT` "Peer Forbidden", 0 messages | `XPC_ERROR_CONNECTION_INTERRUPTED`, then `XPC_ERROR_CONNECTION_INVALID` | 6.1 ms |
| C Developer ID, other identifier | same | same | 1.9 ms / 3.6 ms (two windows) |
| F bare ad-hoc, unsandboxed | same | same | 1.2 ms / 1.3 ms |
| E Apple Development, same team | accepted, replied | reply | 2.1 ms |

Three facts about the API, all measured rather than read:

- The refusal happens at the peer's first message, inside libxpc, on the listener's side: the
  message is dropped, the error event is delivered to the peer connection's handler, and the
  connection is invalidated. The handler never sees the frame, so "zero dispatch" is a property
  of the transport, not of the façade's code.
- The client is not told why. It sees an interruption without a reply, then invalidation. The
  App's transport must therefore treat "interrupted before any reply" as a refusal, which is what
  `RuntimeXPCRequestTransport.Failure.unavailable` already does.
- **E is admitted.** An Apple Development certificate of the same team carries the same
  `subject.OU`, so the production-shaped requirement (`anchor apple generic and certificate
  leaf[subject.OU] = <team> and identifier <id>`) accepts development-signed builds of the App.
  That is convenient for Xcode builds and is exactly the current `daemonCodeRequirement` shape;
  whether a release daemon should additionally require the Developer ID intermediate
  (`certificate 1[field.1.2.840.113635.100.6.2.6]`) is a maintainer choice under design §L.1
  item 3, not something this spike decides.

### Round trips

Persistent connection, `runtime.storage.status`-shaped request of 119 bytes, 112-byte reply,
100 warm-up round trips discarded, n = 1,000.

| Run | p50 | p95 | p99 | max |
| --- | ---: | ---: | ---: | ---: |
| A, requirement on (window 1) | 0.0110 ms | 0.0129 ms | 0.0150 ms | 0.030 ms |
| A2, requirement on (window 3) | 0.0135 ms | 0.0165 ms | 0.0236 ms | 0.270 ms |
| A2, requirement off (window 3) | 0.0106 ms | 0.0155 ms | 0.0182 ms | 0.025 ms |

A new connection per request (n = 200) is where the requirement costs something:

| Run | p50 | p95 | p99 |
| --- | ---: | ---: | ---: |
| A, requirement on (window 1) | 1.011 ms | 1.097 ms | 1.137 ms |
| A2, requirement on (window 3) | 1.099 ms | 1.138 ms | 1.179 ms |
| A2, requirement off (window 3) | 0.042 ms | 0.066 ms | 0.093 ms |

The `xpc_connection_set_peer_code_signing_requirement` call itself returns in 25–76 µs (median
of ten accepts; 3.4 ms on the process's first call); the evaluation is paid once per connection
at the first message, about 1.05 ms on this host, and not again on the same connection. The App
today opens one `NSXPCConnection` per request (`XPCConnectionBox.swift`); against a hardened
listener that pattern would spend a hundred times more on identity than on the request.

Reply size (A2, requirement on, n = 100 each, warm):

| Reply | p50 | p95 | p99 |
| --- | ---: | ---: | ---: |
| 112 B | 0.0090 ms | 0.0110 ms | 0.0121 ms |
| 4 KiB | 0.0126 ms | 0.0147 ms | 0.0195 ms |
| 64 KiB | 0.0537 ms | 0.0614 ms | 0.0688 ms |
| 1 MiB | 0.640 ms | 0.650 ms | 0.685 ms |
| 4 MiB | 2.79 ms | 4.79 ms | 6.52 ms |

Window 1 measured the same rows at 0.0095 / 0.0149 / 0.0466 / 0.612 / 2.64 ms p95. A 4 MiB
request (the design's frame cap) is accepted and answered in 0.30 ms; a 4 MiB + 1 byte request
is refused as `frameSizeOutOfRange` in 0.037 ms before any byte is interpreted.

For scale, the same sandboxed client measured the production Swift daemon over
`NSXPCConnection` before the first window (real handler work included, n = 1,000):

| Request | Reply | Persistent p50 / p95 / p99 | New connection per request p50 / p95 |
| --- | ---: | --- | --- |
| `runtime.storage.status` @2.0.0 | 803 B | 0.573 / 0.797 / 1.867 ms | 0.633 / 0.789 ms |
| `target.list` @1.0.0 | 387 B | 0.230 / 0.243 / 0.274 ms | 0.290 / 0.436 ms |

Against SPK-1's UDS `health` row (p95 0.112 ms), the raw Mach transport with a trivial handler
is an order of magnitude below the cheapest real reply; XPA-AC-5's "within +20% of the SPK-1
baseline per row" leaves the façade about 20–50 µs of forwarding overhead per constant-size
reply, which a same-host socket hop fits.

### The client can pin the daemon

`xpc_connection_set_peer_code_signing_requirement` is symmetric. Set on the client's connection
before activation:

| Client requirement | Outcome |
| --- | --- |
| `… and identifier "com.arkdeck.spk2-listener"` (the listener's real identity) | reply, 4.2–4.5 ms including the one-time evaluation |
| `… and identifier "com.arkdeck.agentd"` (the Swift daemon's identity) | `XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT` "Peer Forbidden" delivered to the client in 5.4–5.6 ms instead of the reply |

This is the macOS counterpart of the two-layer server authentication design §F.2 requires on
Windows: a sandboxed App can refuse to talk to any process holding the service name that is
not the product's signed daemon, by Team ID and identifier, without a PID lookup. It also
means the identifier the App pins must cover both the façade and the Swift daemon of the same
release (one `identifier` clause each, or one shared signing identifier), or the rollback drill
of XPA-AC-9 refuses its own rollback target.

### What the un-migrated App sends to a raw listener

While the Rust listener held the service, the production App was launched for eight seconds
and quit. It connected (pid 45724, requirement satisfied) and sent six messages, each a
five-key dictionary:

```text
"f"        => uint64 33
"root"     => data, 168–264 bytes, bplist17 ("bplist17" magic, NSXPC-encoded invocation)
"proxynum" => uint64 1
"replysig" => string v24@?0@"NSData"8@"NSString"16   (the reply block of sendRequestFrame:with:)
"sequence" => uint64 1
```

The listener answered `{error: "malformedFrame"}`; the App reported the Runtime unreachable and
quit cleanly. Two consequences for `TASK-XPA-003`: the NSXPC and raw-libxpc wire formats are
indeed disjoint (design §G.1, risk R17: the App and the Swift daemon's listener switch in one
PR), and a raw listener can recognise an NSXPC client by these keys and answer a structured
"transport mismatch" instead of letting the App time out, which is the "never a silent hang"
requirement of that task's rollback acceptance.

## Findings for `TASK-XPA-003`

1. `xpc_connection_set_peer_code_signing_requirement` (macOS 12+) is available, returns 0 for a
   valid requirement and 22 (`EINVAL`) for a syntactically invalid one, must be called once per
   peer connection before activation, and refuses inside libxpc before the handler runs. A
   non-zero return must be fatal for that peer: window 2 of this spike carried a
   quote-stripped requirement string by mistake, the call returned 22 and the listener cancelled
   every peer, which is the correct failure mode and why window 2 is recorded but not counted.
2. `xpc_connection_get_euid`, `get_pid`, `get_egid`, `get_asid` are public and sufficient for
   layer one. `xpc_connection_get_audit_token` is exported but not in the public header; with
   the built-in requirement there is no reason to call it.
3. The production-shaped requirement admits same-team Apple Development signatures. Decide
   (design §L.1 item 3) whether release builds add the Developer ID intermediate clause.
4. Reuse the App's connection. The requirement costs about 1 ms per connection and nothing
   per message; the per-request connection pattern of `XPCConnectionBox.swift` should not
   survive the move to `xpc_connection`.
5. Pin the daemon from the App with the same API; make the requirement cover the façade and
   the same-release Swift daemon.
6. Enforce the 4 MiB frame cap on the data length before parsing; it costs nothing and the
   transport carries 4 MiB replies in under 5 ms p95.
7. Recognise NSXPC dictionaries (`proxynum` / `replysig` / `sequence` keys) on the raw listener
   and answer a structured mismatch; treat "interrupted before any reply" on the client as a
   refusal.
8. The Windows-style `doctor` report for a squatted service name has no macOS analogue here:
   launchd hands the name to exactly one job per session, and a sandboxed client can reach only
   that job. The same-user boundary statement of design §L.1 item 17 stands unchanged.

## What went wrong, and what it cost

- **Same identifier, different signature, stalls before `main`.** Variants B, D and E were first
  built under A's identifier `com.arkdeck.spk2-client` with a different signature or
  entitlement set. Each hung at launch in `_libsecinit_appsandbox` (stack sampled, recorded as
  `spk-2/results/b-adhoc-hang-sample.txt`) — the sandbox's container initialisation, before any
  XPC call — and its `alarm` watchdog could not end it. Giving every signed variant its own
  identifier removed the stall. The cause is not proven from logs; it is consistent with the
  container's recorded code requirement disagreeing with the new signature. It is out of scope
  here, but it is why an App re-signed under another identity should get a fresh container.
- **An attempt to delete the spike's own container with `rm -rf` was a mistake.** It removed
  part of `~/Library/Containers/com.arkdeck.spk2-client`, could not remove the protected
  metadata (`Operation not permitted`), and left A unable to start afterwards; A2 with a fresh
  identifier replaced it for window 3. The spike containers `com.arkdeck.spk2-*` remain in
  `~/Library/Containers` and can be removed in Finder.
- **`PlistBuddy -c Set` strips double quotes** from the value, which turned the requirement
  string into invalid syntax (finding 1). The spike plists are now written with `plistlib`, and
  the requirement text is validated with `csreq -r=<text> -t` before a window opens.
- **The production daemon was down for 16.5 minutes in window 1** (05:24:48–05:41:21 UTC),
  almost all of it the stalls above and a directory listing that hung on the damaged container;
  windows 2 and 3 took 98 s and 25 s. The daemon was restored from its own plist each time and
  answered `health` over the Unix socket afterwards. No App was running during the windows
  except the two eight-second launches described above.

## Reproducing

```bash
# from the evidence directory of TASK-XPA-003; replace __SPK2_ROOT__ in the plists
cargo +1.98.0 build --release --manifest-path spk-2/listener/Cargo.toml
codesign --force --sign "Developer ID Application: <team>" --identifier com.arkdeck.spk2-listener \
  --options runtime target/release/spk2-listener
sh spk-2/client/build.sh <spk2-root>          # builds and signs the six client variants
sh spk-2/run-spike.sh <spk2-root> baseline    # NSXPC against the production daemon
sh spk-2/run-spike.sh <spk2-root> swap-in     # bootout production, bootstrap the spike plist
sh spk-2/run-spike.sh <spk2-root> measure
sh spk-2/run-spike.sh <spk2-root> swap-out    # bootstrap production again
sh spk-2/run-spike.sh <spk2-root> verify      # health over the Unix socket
```

Run every client under a watchdog (`perl -e 'alarm 25; exec @ARGV' …`), give every signed
variant its own bundle identifier, and never list or delete anything under
`~/Library/Containers` from the orchestration shell.

# TASK-XPA-016 — M2 run record: the pointer-gesture and port-rule providers

Change: CHG-2026-074-shared-rust-runtime-core@r11. Milestone M2 (GJ-2), lane B's platform
executor: the device actions of `input.tap@1`, `input.long-press@1`, `input.swipe@1`,
`port-forward.create@1` and `port-forward.remove@1` ported from Swift's HDC provider as two
additive modules, with T1 argv parity proved by replaying the Swift oracles recorded in the
previous slice Job by Job over the shared fake HDC driver. Host measurement only — not
hardware, platform or conformance evidence (POL-VERIFY-001, POL-MODE-001). No device, no HDC
server, no daemon.

Base: protected main `68e8241a` (#1954). Branch
`agent/xpa-016-pointer-port-forward-provider-20260914`, stacked on the oracle slice
(`agent/xpa-014-pointer-port-forward-oracle-20260914`) whose fixtures it replays. Files:
`arkdeck-provider-hdc/src/pointer_input.rs` (new), `src/port_forward.rs` (new), `src/readback.rs`
(new: `Reconcile`, Swift's `ProviderReconcileOutcome`), `tests/pointer_input.rs` (new),
`tests/port_forward.rs` (new), the export block in `lib.rs`, this record, one README section.
Neither module is macOS-gated (no platform API); the replays are. No `arkdeck-hoststore`,
`arkdeck-agentd`, `arkdeck-control`, Swift or contract change.

## What was missing

The interaction map (lane B, 2026-09-14) found no `uinput`, `fport` or `rport` lowering
anywhere under `rust/crates/` — only the hoststore's WAL argument shapes for the three
intents — while the oracle slice had just recorded Swift's T0 oracles of the five operations.

## What Rust now has

`arkdeck_provider_hdc::PointerAction` over `PointerInput` (`pointer_input.rs`) and
`PortAction` over `PortRule` (`port_forward.rs`):

| Action | Swift argv (after `-t <key>`) | Budget | Verdict |
| --- | --- | --- | --- |
| `PointerAction` tap | `shell uinput [-D <display>] -T -c <x> <y>` | 30 s | `pointerInputRejected` on `parameter error` (the first line as the detail); verified on `click coordinate`; otherwise unknown "uinput did not acknowledge the tap it was given; …" — the exit status never consulted |
| `PointerAction` long press | `shell uinput [-D <display>] -T -d <x> <y> -i <hold> -u <x> <y>` (`hold` = the caller's `durationMs` or 800) | 30 s | as above on `touch down` and `touch up`; `loweredHoldMs` in the summary |
| `PointerAction` swipe | `shell uinput [-D <display>] -T -m <x> <y> <toX> <toY> <durationMs>` | 30 s | as above on `startx:` and `endx:` |
| `PortAction::Create` | `fport tcp:<local> tcp:<remote>` (forward) / `rport tcp:<remote> tcp:<local>` (reverse) | 30 s | `portForwardFailed` (`tcp:<localPort>`) on a non-zero exit, else verified with `localPort` |
| `PortAction::Remove` | `fport rm <tuple>` | 30 s | the same |
| `PortAction::ReadPresence` | `fport ls` | 30 s | unknown "port-forward presence readback is not trustworthy" unless exit 0, untruncated and UTF-8; else `present` true/false — a row with the direction's tag and the exact tuple in order |

`PointerInput::new` is `HDCPointerInputSpec.init` with Swift's bounds in Swift's order of
refusal and its `outOfBounds(field:detail:)` texts; `from_inputs` is `pointerInputSpec` (the
operation names the gesture; `<key> is required for a pointer input`, `<key> must be an
integer`/`a string`); `frame_age_ms` and `refuse_if_stale` the freshness gate at dispatch
(`inputExpired: the frame this gesture was mapped against is <age> ms old, beyond the 1000 ms
freshness bound; refresh the screen and send a new gesture`; no claim without an epoch);
`persisted`/`from_persisted` the `hdc.injectPointerInput` intent (`persisted pointer gesture is
invalid`). `PointerAction::for_step` builds the `injectPointerInput` step's action at dispatch
time; `readback` is none and `reconcile` is permanently unknown ("an injected pointer gesture
has no observable readback"). `PortRule::new`/`from_inputs` are `HDCPortForwardSpec` and
`portForwardSpec` (`1024...65535`; "direction, localPort and remotePort are required for a port
rule"); `PortAction::for_step` maps `createPortForward`, `removePortForward` and, for the two
operations only, `verifyRemoteState`; `readback`, `desired_presence`, `conclude` and
`reconcile_without_readback` are Swift's reconciliation table (`postconditionPresent`,
`ConfirmedNotExecuted`, "device mutation needs a readback pass before it can be concluded",
"readback was not paired with a mutation"); `persisted` the three intents.

## Measurement

`tests/pointer_input.rs` and `tests/port_forward.rs` install each oracle's own
`hdc-answers.sh` on the shared fake driver (`/private/tmp/arkdeck-hdc-oracle`, under its lock)
and drive every Job as Swift's engine drove it — the evidence preflight through `Action`
(the device probe every Job; the model and firmware reads only where the oracle's session did
not carry them), the mutation and its readback through the new actions — in the oracle's mode,
checking every verdict and conclusion and comparing the argv the driver logged with the
oracle's `hdc-invocations.log` segment by segment:

| Oracle | Job | Mode | Verdicts checked | Lines |
| --- | --- | --- | --- | --- |
| pointer-input | tap | normal | verified: `gesture` tap, `frame` 1280x2832, `x`/`y` | 4 |
| pointer-input | longPress | normal | verified: `loweredHoldMs` 1200, `durationMs` 1200, `displayId` 2 | 2 |
| pointer-input | swipe | normal | verified: `toX`/`toY`, `loweredHoldMs` 500 | 2 |
| pointer-input | rejected | rejected | `pointerInputRejected` "parameter error, unable to run" | 2 |
| pointer-input | otherGesture | otherGesture | unknown; no readback; reconcile still unknown | 2 |
| pointer-input | expired, outOfFrame | — | `for_step` refuses with the text the oracle's `job.plan` refusal carries under "typed plan preflight failed before authorization: " | 0 |
| port-forward | createForward, removeForward | normal | verified `localPort`; readback `present` true / false; `ConfirmedCompleted` | 5 + 5 |
| port-forward | createReverse, removeReverse | normal | the same over `rport` and the flipped tuple | 5 + 5 |
| port-forward | createRefused, removeMissing | createRefused / normal | `portForwardFailed`; without a readback the intent stays unknown | 4 + 4 |
| port-forward | ruleUnlisted | ruleUnlisted | verified; readback `present` false → `ConfirmedNotExecuted`; the compensation's remove verified and its readback absent → `ConfirmedCompleted` | 7 |
| port-forward | readbackUnanswered | readbackUnanswered | verified; readback unknown "not trustworthy"; conclusion still unknown | 5 |

All 12 and all 40 recorded lines matched on the first run.

```
cargo test -p arkdeck-provider-hdc --lib -- pointer_input:: port_forward::   11 passed (6 + 5)
cargo test -p arkdeck-provider-hdc --test pointer_input                      1 passed (5 Jobs + 2 refusals, 12/12 lines)
cargo test -p arkdeck-provider-hdc --test port_forward                       1 passed (8 Jobs, 40/40 lines)
cargo test -p arkdeck-provider-hdc                                           every suite of the crate green
cargo clippy -p arkdeck-provider-hdc --all-targets -- -D warnings            clean
cargo fmt --all --check                                                      clean
```

The eleven unit tests port the Swift contract cases (`DeviceProviderContractTests`,
`PointerInputChannelRoutingContractTests`' argv shapes): every refusal of the spec in Swift's
order; the inputs read with Swift's refusals and the freshness gate on the provider's clock
(inclusive at 1000 ms, no claim without an epoch); the positional argv with the display
selector first; the verdict from the acknowledgement lines (verbatim device output of
2026-08-25), the rejection, silence, another gesture's echo, non-UTF-8; the persisted round
trip; the stamp parser; the rule's bounds and input refusals; the canonical full-task tuples;
the readback parse on tuple order and direction, the device's own row shape, an untrusted
readback; the readback table and its conclusions; the persisted forms.

## Declared differences from Swift (T1/T2)

- `for_step` takes the provider's clock as a value (`now_utc`); Swift reads it from
  `ProviderExecutionContext`. The freshness gate is otherwise the same, including Swift's
  rounding of the age to milliseconds.
- `PointerInput::from_persisted` reads absent integers as zero before the bounds check, as
  Swift's decoder does; the bounds refuse them.
- `PortAction::conclude` is the provider's half of Swift's `concludeReadback` (the
  intent-to-readback pairing is the engine's); `reconcile_without_readback` its `reconcile`.

## What stays with other owners

- The engine half — the typed plan's preflight at `job.plan`/`job.submit`, the port-rule
  readback gate (`portForwardReadbackMismatch` with its two details) and `compensate-port-rule`
  with `verify-port-rule-compensation`, the lineage block after an unknown outcome, the
  persistent shell channel routing of pointer injection over
  `arkdeck_platform::DeviceShellChannel` (Swift's `PointerInputChannelDispatcher`), the WAL
  argument shapes already in `arkdeck-hoststore`, the `port-rule-readback.json` product — lane
  A; the daemon-level replay of both fixtures through `check-corpus-replay.py` follows that
  wiring.

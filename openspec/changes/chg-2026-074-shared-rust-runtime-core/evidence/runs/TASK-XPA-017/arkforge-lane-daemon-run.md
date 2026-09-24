# The ArkForge lane daemon on the Rust Runtime (TASK-XPA-017, M4-2b)

With `ARKDECK_ARKFORGE_BUNDLE_PATH` naming a validated ArkForge release bundle,
either Rust composition now owns one `arkforged` generation, as Swift's daemon
does. It starts the bundle's daemon in `<state>/arkforge`, pairs it, proves it
ready, and stops it after its own drain. Nothing is dispatched through the
lane yet.

The flash facts and reads build on it:

- the facts measure the bundle's `arkforged`, so `flash.prerequisites` no longer
  answers that no lane is configured once a bundle is named;
- the live probe's Loader observation is Swift's dual-source one: the
  Runtime's USB census and the lane daemon's own `discoverDevices` must agree;
- `flash.device-access` reads the daemon this Runtime started.

Without a bundle, both compositions say why there is no lane, in Swift's
words, and start nothing.

Base: protected `main` `cc5b5670` (#2151, M4-2a). Routed methods stay
**100/105**, executable operations 15/30, and no contract input changes.

| Already on `main` | This change | Still remaining (M4) |
|---|---|---|
| The ArkForge dependency at the Swift pin and `flash.device-access` over the public socket (#2151); the facts' two ports (#2150) | Pairing `arkforged` in the platform layer; the release bundle reader in `arkdeck-contract`, shared by the CLI and the daemon; the lane's composition, readiness and stop; Swift's dual-source Loader observation; both compositions starting, reporting and stopping the lane | The upstream ArkForge client API, `flash.lanePlanPreview` and SPK-9's device-free evidence against a real `arkforged` (M4-3); permits, execution and recovery through the lane (M4-4) |

## Swift, as ported

**Pairing** (`arkdeck_platform::ManagedServer::launch_paired`; Swift
`IdentityBoundDaemonLauncher`)

- *Launch.* The daemon is spawned from the verified bundle member's retained
  inode, in its own process group, in the runtime directory. It gets one
  secret on stdin, and nothing but the pipe's read end crosses
  (`POSIX_SPAWN_CLOEXEC_DEFAULT`).
- *Liveness.* The write end stays with the owner. Its close is the daemon's
  end of input: the proof its owning generation is gone.
- *Partial secret.* A child the whole secret did not reach is stopped, and the
  launch is refused.
- *Stop.* It closes the liveness first, then sends TERM to the group, waits
  half a second, then sends KILL and waits half a second more. These are
  Swift's graces (`stopDaemonProcessGroup`).
- *Blocking input.* The shared capture pipes set `O_NONBLOCK` on their read
  end, and that flag is shared with a child through the open file. So the
  stdin pipe comes from its own `input_pipe`, blocking. The platform test
  caught it: a stand-in reading its stdin with `cat` ended at once.

**The release bundle** (`arkdeck_contract::arkforge_bundle`)

- The CLI's port of Swift `ArkForgeReleaseBundleReader.load` moved unchanged
  into the contract crate, with Foundation's lexical and resolving path
  arithmetic (`foundation_path`). The CLI's `runtime service` leaves and the
  daemon read a bundle through that one reader.
- The CLI's own helpers now re-export those functions; its bundle messages are
  byte for byte what they were.

**The lane** (`arkdeck_provider_arkforge::{LaneInputs, Lane}`; Swift
`ArkForgeLaneComposition`)

- *Inputs.* A retired lane name refuses by name. No bundle path is no lane; an
  empty one is a partial configuration. The bundle must verify and publish
  `org.openharmony.dayu200`, and the daemon's bytes are measured again. The
  campaign is read as given. The refusals are Swift's `Absence` texts.
- *Before the launch.*
  - The DeviceProfile is read, and exactly one `profile.id` and one
    `profile.version` are taken from its `profile:` block (Swift's line reader).
    The id must be DAYU200's.
  - The running `arkdeck-agentd` digest and the managed-control HDC digest
    must both be present.
  - Stale `controller.sock` and `public.sock` files are removed, so the wait
    below can only find the daemon launched here.
- *Arguments.* `--runtime-dir`, `--profile`, `--pair-from-stdin <epoch>`, and
  `--hardware-campaign` only when one is named. A fresh 32-byte secret goes on
  stdin; the epoch is the start time in seconds.
- *Socket wait.* It looks for the controller socket every 50 ms for up to 10 s,
  and stops early if the daemon has already ended.
- *Readiness.* A controller session must be acknowledged. Then Swift's
  `verifyReadiness`: the daemon is ready, bound to `arkforged-native-rockusb`,
  and its toolchain digest is the bundle daemon's. The refusals are Swift's
  texts.
- *Failures.* Every failure after the launch stops the generation before
  refusing.
- *Assessment only.* Without a campaign the lane reports Swift's line saying
  Flash is unavailable.

**The dual-source Loader observation** (`arkdeck_hoststore::ArkForgeLoader`,
`arkdeck_provider_arkforge::{confirm_loader, select, topology_digest}`; Swift
`ProductArkForgeLoaderObserver`, `ArkForgeObservationSelection`)

- *The census half.* The Runtime's census must hold exactly the bound Loader.
  Its serial digest must be the bound identity, and its port the admitted one
  when one is admitted.
- *The ArkForge half.*
  - One public `discoverDevices` session, bounded at 15 s.
  - Exactly one observation at that port, matched by
    `SHA-256("arkforge/v1/device-facts\0" ‖ locationID_be32)`.
  - That observation is a `rockusb-loader`, identified by serial and topology,
    with a well-formed descriptor and `usb.identity` `0x2207:0x350a`.
- Each refusal is Swift's words. The facts compose this observer whether or
  not a lane runs: without a daemon on the socket every observation refuses,
  and the probe reports the board absent.

**Compositions** (`arkforge_lane::compose`)

- *Isolated development owner.* The lane runs in `root/jobs-state/arkforge`, with
  the development HDC's digest as the managed-control tool.
- *Production composition.* Written, not activated. The lane runs in
  `…/ArkDeck/Agentd/arkforge`, with the registered HDC's digest. The two
  `ARKDECK_ARKFORGE_*` names leave its "set but not ported" list; it reads
  them, with the retired names, from its environment snapshot.
- *Both.* The facts get the bundle's measured daemon (Swift's
  `rockchipResolver`, from the inputs even when the launch fails) and the
  dual-source Loader observation. Device access reads the same directory.
  Swift's start-up lines go to stderr. After the drain, the lane's daemon is
  stopped before the managed HDC server, in Swift's order.

## Declared differences

Each is either fail-closed or T2:

- **Readiness from the public session.** ArkForge's Rust `ControllerClient`
  keeps no acknowledgement. The lane opens a controller session to prove it is
  served, then reads the readiness from a public session. `arkforged` publishes
  one service-wide readiness on every session (its `HelloAck` built from
  `service.readiness()`), so the facts are the same. M4-3's upstream client
  change is to expose the controller acknowledgement.
- **The controller session is not kept.** Swift keeps it for the lane host's
  jobs. Nothing runs a job through the lane yet.
- **The pairing secret is not retained.** It is drawn, written to the daemon
  and dropped. Nothing mints a permit in this slice; M4-4's authority will hold
  it for the lane's life, as Swift's `makeAuthority` does.
- **The daemon's environment.** Rust's identity-bound spawn gives its base
  (`PATH=/usr/bin:/bin`, `LANG=C`, `LC_ALL=C`). Swift passes the parent's
  `PATH`, `HOME`, `TMPDIR` and `LANG`. `arkforged` takes its runtime directory
  and profile from its arguments (T2).
- **The daemon's output.** Rust captures up to 1 MiB of each stream and drains
  the rest; Swift lets the daemon write to agentd's own streams (T2).
- **An exited daemon is not waited for.** The socket wait ends as soon as the
  daemon has exited, with Swift's refusal, rather than after the full 10 s.

## SPK-9

Not closed here. No real `arkforged` was run:

- its `discoverDevices` reads the host's USB devices through IOKit;
- the maintainer's ruling Q1=B asks to stop before anything opens a device.

This slice gives the plumbing SPK-9's device-free evidence will run through:
the pairing, the readiness fields `PublicClient::runtime_info` shares with
Swift's `HelloAck`, and the public session. All of it is exercised against a
stand-in daemon speaking ArkForge's own codec. M4-3 closes SPK-9, with the
upstream client change and the preview chain.

## Verification

**Local targeted checks.** `CARGO_BUILD_JOBS=2`, own target
`/private/tmp/arkdeck-m4-rust-target`, logs `/private/tmp/arkdeck-m4-afd-*.log`.

| Check | Command | Result |
|---|---|---|
| fmt | `cargo fmt --all --check` | exit 0 |
| clippy | `cargo clippy -p arkdeck-platform -p arkdeck-contract -p arkdeck-provider-arkforge -p arkdeck-hoststore -p arkdeck-cli -p arkdeck-agentd --all-targets -- -D warnings` | exit 0 (`afd-clippy.log`) |
| Crate tests | `cargo test --no-fail-fast -p <crate>` | exit 0 each: `arkdeck-platform` 181 (with the paired launch: secret, working directory, end of input), `arkdeck-contract` 50, `arkdeck-provider-arkforge` 19 (8 unit, 5 device access, 1 permit vectors, 5 end-to-end lane), `arkdeck-hoststore` 558 (with the 3 dual-source Loader cases), `arkdeck-cli` 251 (the moved bundle reader under the runtime service leaves), `arkdeck-agentd` 143 (`afd-test-<crate>.log`) |
| End-to-end lane | `cargo test -p arkdeck-provider-arkforge --test lane`: a verified bundle whose daemon is the test binary itself, playing `arkforged` | 5 passed: one paired, ready generation, with the secret on stdin only and Swift's arguments, answering device access and gone after its stop; a stale socket never taken for it; a daemon not ready or bound to another toolchain stopped and refused; an exited daemon refused at once; nothing launched before the profile, both digests and the daemon's bytes are proved |
| Mutations | seven, each against its own tests: a refused lane's daemon left running, a stale socket kept, the readiness digest unchecked, the first of two observations at a port taken, the admitted port unchecked, TERM before the end of input, a nonblocking stdin | 7/7 caught; every source restored by digest (`afd-mutations.log`) |
| Dependency policy | `cargo deny --locked check`; `cargo vet --locked --no-registry-suggestions` | exit 0; no new crate |
| Pin | `python3 rust/scripts/check-arkforge-pin.py` | exit 0 |
| Read-only host check | `rust/scripts/check-readonly.py --bin-dir <this build>` (validation venv), its boundary table included: `arkdeck-provider-arkforge` over the contract and the platform, `arkdeck-hoststore` now also over it | PASS on macOS; 134 control responses, unchanged (`afd-readonly.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | exit 0 (`afd-sdd.log`) |
| Leftovers | `pgrep -f pair-from-stdin` after the runs | none of this slice's stand-ins; the one match is the installed Swift daemon's own `arkforged`, which nothing here touched |

Not run locally: `check-contracts.py`'s views, and the Linux and Windows jobs
(the lane is macOS-only; the provider's public-socket code builds everywhere).
CI runs them.

**CI.**

- *First push* (`4f60f6e9`, #2152, run 36049602838): red on macOS only, in
  `a_daemon_that_is_not_ready_is_stopped_and_refused`.
  - The case waited for the stand-in's end-of-input marker. Only a stand-in
    that reads its end of input before TERM reaches it writes one, and the
    stop sends TERM right after closing the input, as Swift's
    `Handle.terminate` does. On the runner, TERM won.
  - The fix is in the test, not the stop. The stand-in now holds a lock for its
    whole life, and the cases check that it is free once the refusal returns:
    the generation has ended. That the input is closed first stays the
    platform's paired-launch test's proof, with a stand-in ignoring TERM.
  - The fix is checked both ways. With a stand-in pausing 300 ms after its end
    of input, TERM always wins: the old check fails and the new one passes.
    With a refused generation leaked instead of stopped, the new check fails.
    Five plain runs pass (`/private/tmp/arkdeck-m4-lanefix-*.log`).
- *Second push*: pending.

No device, installed service, real `arkforged` or App was used, and nothing
here is device evidence.

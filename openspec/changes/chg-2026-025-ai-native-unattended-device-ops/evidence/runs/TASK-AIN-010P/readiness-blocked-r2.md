# TASK-AIN-010P readiness audit r2 — still blocked, on one gate instead of three (2026-08-07)

Re-measured every gate `readiness-blocked-r1.md` recorded on 2026-07-29 rather than carrying its
conclusions forward. Two of the three blockers have cleared on their own; one has not moved at
all, and its root cause is now identifiable.

Host-only observation throughout. HDC command dispatch: 0. Device command dispatch: 0. No
process was started, no server was started, adopted or restarted, and nothing was written outside
this document.

## Gate-by-gate, measured today

| Gate | r1 (2026-07-29) | r2 (2026-08-07) |
| --- | --- | --- |
| Approval / dependency / collision | satisfied | **satisfied** |
| Exact tool bytes | satisfied | **satisfied**, byte-identical |
| Production selection | blocked | **blocked, unchanged** |
| Server / tool environment | blocked | **satisfied** |
| Durable target / build | blocked | **partly satisfied** — target yes, build no |

### Approval / dependency / collision — satisfied

`TASK-AIN-010` and `CHG-2026-043 TASK-HSO-002` remain done. `CHG-2026-051` is now **archived**
(`openspec/changes/archive/2026-07-30-chg-2026-051-agent-hardware-evidence`), which r1 listed as
an unmet dependency. All three allowed new-source directories and the task-local test file are
still absent, so there is still no new-file collision.

### Exact tool bytes — satisfied, and unchanged since r1

The DevEco HDC at the system toolchain path is mode `0755` and hashes to
`05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83` — **byte-for-byte the tuple
r1 registered for `3.2.0f`**. Nine days and several device windows have not moved it.

### Production selection — blocked, and now with a named cause

The persisted `ArkDeck.HDC.userConfiguredPaths` in the `com.arkdeck.desktop` domain still
resolves to a single path that **does not exist**, and `ARKDECK_HDC_PATH` is unset. Production
discovery therefore still cannot select the real candidate above.

r1 described this as "an old fake fixture". What it actually is, read out today: a path under the
**UI-test runner's container** (`…hdcuitests.xctrunner/Data/tmp/arkdeck-picker-fixture-<n>/…`),
i.e. a per-run temporary fixture belonging to a test harness. The literal path is a user absolute
path and stays out of the repository, per r1's own rule.

That makes this more than a stale preference. A UI test wrote into the **product's real
persisted preferences domain** and left a dangling pointer there; every run since has inherited
it. The gate is blocked by test-harness residue, not by anything about the device.

The residue outlived its author. Neither `arkdeck-picker-fixture` nor `userConfiguredPaths`
appears anywhere in `ArkDeckAppUITests/` or `ArkDeckApp/` on `main@7ee6d0ed` — the test that
seeded this path is gone from the tree, and current UI tests build their temporary roots from
the runner's own process ID instead. So "fix the test" is not the remedy: the write already
happened, the value is durable on this host, and nothing in the product clears or revalidates
it. Two candidate unblocks, neither taken here because both are outside this task's
pre-readiness paths:

1. point the preference at the real system toolchain path (an operator action, one-off,
   host-only); or
2. have the resolver read a protected configuration rather than a user-writable preference —
   which is what the r1 audit's "product-owned bootstrap" remediation asked for, and the only
   one of the two that prevents recurrence.

### Server / tool environment — satisfied

r1 found no listener on the exact endpoint and no selected-executable server process. Today
there **is** an existing HDC server listening on `127.0.0.1:8710`, and its loaded image is the
DevEco SDK toolchain `hdc` — the same candidate family whose bytes are pinned above. It was
already running, started by another session; this audit neither started it nor issued it a
command, so `TASK-HSO-002`'s existing-commandless-identity precondition is met without violating
it.

Stated honestly, two limits: the running process's executable was identified by its loaded image
path, not by re-hashing the running binary; and its presence is incidental to another session
rather than a durable precondition. A readiness that pins this gate must re-establish it at its
own window.

### Durable target / build — target yes, build still unknown

This is the gate that moved most. r1 found no session, device-binding or target-selection state
at all, and concluded the registrar caller could not obtain the values it needs.

Today the runtime target store holds **one adopted durable target**, `TGT-958780b2ffb7`, binding
revision `2`, tool version `3.2.0f`, adopted `2026-07-31T02:43:19Z` — i.e. **created after the
r1 audit**, by the bootstrap path `CHG-2026-048` (T09: `createDurableTarget` →
`persistInitialBinding`) delivers. The chicken-and-egg r1 named is resolved in the product: a
resolver can now dereference a maintainer-selected target by target ID without the caller
supplying a session root. The record's connect key is a device serial and is not reproduced here.

What is still missing is the other half: **fresh firmware/build confirmation**. Pinning device
presence, serial digest and build for a `3.2.0f` machine confirmation requires a registered
`list targets -v`, which is a device command this task forbids while blocked. Recent windows on
this device recorded OpenHarmony `7.0.0.34`/`7.0.0.37`, but r1's rule stands and is repeated
here: historical build evidence does not substitute for a fresh machine confirmation.

## Status

**Blocked.** One hard blocker (production selection) and one gate that can only close inside a
readiness window (build confirmation). The remediation r1 demanded — a D1 scope revision
authorizing a product-owned bootstrap — has been substantially delivered by `CHG-2026-048`, whose
result is on disk and measured above; whether that discharges 010P's requirement is a governance
judgment for the maintainer, not a conclusion this audit may draw.

Nothing here pins exact argv, budgets, storage layout, an evidence instance or a privacy
allowlist, and nothing here establishes output/support authority for any probe.

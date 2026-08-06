# `flash continue`, executed for the first time (2026-08-06)

## Why this window existed

Two evidence documents in a row recorded the same gap: `flash continue` and the reconciliation
readback were read but never executed, because every flash had succeeded on its first attempt.
A recovery path nobody has run is a recovery path nobody knows works.

- Baseline: `main@947677e2`
- Device: DAYU200, `OpenHarmony-7.0.0.34`, target `TGT-958780b2ffb7`, binding revision `2`

## Constructing an interrupted attempt without risking the device

The plan's own step list decides where an interrupt is safe:

```
step rk-rf002-request-destructive-confirmation  effect=hostOnly
step rk-rf002-enter-loader                      effect=deviceMutation
step rk-rf002-ppt-precheck                      effect=readOnly
step rk-rf002-wlx-1-uboot                       effect=destructive   ← first write
```

Anything before `wlx-1-uboot` writes no partition. A second fact decides *what* to interrupt:
a campaign attempt executes on the engine lane, in the daemon, with no in-process fallback —
so killing the CLI would only cost the caller its receipt while the daemon finished the flash.
The daemon is the thing to stop.

The signal used was the device leaving hdc-normal mode, which is `enter-loader` completing and
still two steps ahead of any write. `rkdeveloptool` was confirmed absent from the process table
at the moment of the kill: **no partition was written**.

## What `flash continue` does, now measured

```
campaign ECAMP-BAC3B3C7C52040061DEEBFE7   terminal: true   reserved attempts: 1/16
#1 candidatePrepared   #2 attemptReserved ordinal=1   #3 attemptTerminal ordinal=1
                                                          disposition=outcomeUnknown

$ arkdeck flash continue --campaign-id ECAMP-BAC3B3C7C52040061DEEBFE7 …
arkdeck flash: campaignStopped("terminalOrExpired")
  [ok] rockUSBToolAliveness / hdcToolAliveness / archiveIntegrity
  [ok] targetPresence: bound target readable in loader mode at USB topology 17956864
```

**It refuses, and refusing is right.** An attempt whose outcome was never observed is not
retry-safe, so the campaign is terminal and continuation cannot reflash on top of a state
nobody established. The preflight still ran green first, so the refusal is a decision rather
than an inability.

`arkdeck flash reconcile` reported `no unresolved flash sessions`: the attempt died before it
wrote anything a session journal could reconcile. So the reconciliation readback remains
unexercised even now, and this document does not claim otherwise.

## The defect this found

The refusal said `terminalOrExpired`. Two situations, one word, and they need opposite next
moves:

- **terminal** — the campaign has stopped for good. Establish what the device is, then start a
  new campaign.
- **expired** — the confirmation window lapsed. Nothing about the device changed; preview and
  confirm again.

An agent told only `terminalOrExpired` can choose neither, so it stops for a human — in the one
place whose whole purpose is recovering without one. The two guards immediately below it already
named themselves exactly (`repeatedSafeNoEffect`, `attemptBudgetExhausted`); this one was the
outlier. It is now two guards: `campaignTerminal:<disposition>` and
`confirmationExpired:<validUntil>`, each carrying the fact that decides the next move.

Same family as the rest of this change window: one value standing for two different facts.

## Device recovery

The board was left in Loader mode with `7.0.0.34` intact. Recovery used the sanctioned path
rather than a manual tool: a fresh preview and campaign, `ECAMP-90269BFCC9396F3479B7B03B`,
job `job-969bbe09527a8c3f4d8faa1f89a66ffd`, attempt 1 of 16, terminal `succeeded`. The device
boots and reports `OpenHarmony-7.0.0.34`.

## An operator error worth recording

Checking the device state, `rkdeveloptool` was invoked directly from the shell — the Homebrew
copy on `PATH`, not the one the product installs and pins. macOS Gatekeeper blocked it and the
command hung on a dialog. The product's own tool was fine throughout, as every preflight in
this document shows. The lesson is narrow and real: ask the product for device state; do not
reach around it for a binary it did not vouch for.

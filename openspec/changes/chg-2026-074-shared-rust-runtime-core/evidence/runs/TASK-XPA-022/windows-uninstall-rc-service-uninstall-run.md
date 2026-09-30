# TASK-XPA-022 — `uninstall-rc.ps1` stops the installation's daemon with `runtime service uninstall`

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase, follow-up of #2404 (the RC
uninstall script) and #2411 (`runtime service uninstall` on Windows). Host: the Windows 11 x64
reference host, non-elevated. No device was contacted, no `hdc` ran, and nothing installed was
read or written: every installation was an xcopy-shaped directory below `D:\temp` over its own
isolated development state root. Host tests are not Windows acceptance.

Basis: decision 11 (the client-started daemon), maintainer ruling 17 (the daemon's signer pin),
the lead's direction once #2411 merged (switch the script to the CLI's stop and keep skipping
another installation's daemon), and the delegated minor decisions below.

## What changed

`windows/scripts/uninstall-rc.ps1` stopped a daemon running from the installation by setting
its stop event itself. Now:

1. As before, the daemon's instance document (the account root's, or `-DevelopmentStateRoot`'s)
   names a pid, and the process must run the installation's `arkdeck-agentd.exe`. A daemon of
   another installation is left alone and named in the answer.
2. A validly signed image is stopped by the installation's own `bin\arkdeck.exe runtime service
   uninstall`, with only the inputs that pin it: `ARKDECK_DAEMON_PATH` (the image) and
   `ARKDECK_DAEMON_SIGNER_SHA256` (the SHA-256 of its signer certificate, as
   `windows-dev-identity.ps1` pins one), over the same state root. Every other `ARKDECK_` and
   `OHOS_HDC_` variable is removed for the call and restored after it. The CLI proves the
   daemon's identity on its pipe, requires the instance document to name the serving pid,
   refuses while a Runtime Job is active or unclosed, and then requests the stop and awaits the
   single-instance guard.
3. Exit 0 must stop the instance's own pid (or find no daemon). Exit 75 refuses the uninstall
   ("refused to stop while Runtime Jobs are active or unclosed"). Any other exit also refuses it,
   with the CLI's stderr, and nothing is removed.
4. An unsigned image (`NotSigned`), which no CLI proves, is asked to stop through its stop event
   as before. Any other signature status refuses, and nothing is signalled.

The answer's `daemon` gains `stopRequest` (`runtimeServiceUninstall` or `stopEvent`), and for
the CLI path `stoppedPid` and `drain`.

## Delegated minor decisions (pending the next rulings batch)

1. **"Not ours, skip" is decided before the CLI runs**, from the instance document's pid image,
   as CI2 advised: exit 69 cannot tell another installation's daemon from a failed proof, so after
   that check every non-zero exit fails closed.
2. **The pin is the installed image's own signer certificate**, not the user's configured
   inputs: the uninstall concerns exactly that image, and the configured pins may be absent (an
   xcopy RC is pointed at its daemon by `ARKDECK_DAEMON_PATH` only for its clients).
3. **An unsigned image keeps the stop-event path.** A CLI refuses such a daemon (`-SigningMode
   none`), yet one started directly must still be stoppable before its directory is removed.

## Measured on Windows

Installations built from this revision's `arkdeck.exe` and `arkdeck-agentd.exe`, the daemon
signed with the host-trusted development signer where signed:

| Case | Result |
| --- | --- |
| A signed installation whose daemon its CLI started (`doctor`) | exit 0; `stopRequest: runtimeServiceUninstall`, `stoppedPid` the instance's pid, `drain: complete`; the daemon exited, the directory was removed, the state root kept |
| An unsigned installation's daemon, started directly | exit 0; `stopRequest: stopEvent`; exited; removed |
| Another installation's daemon over the same root | exit 0; `running: false` with its `instancePid` and the note; it kept running and its directory stayed. Its own uninstall then stopped it through the CLI |
| An installation whose `bin\arkdeck.exe` is missing | refused; the daemon kept running and nothing was removed. With the CLI restored, the uninstall succeeded |
| A CLI answering exit 75 (a stand-in printing the Job refusal) | refused with "refused to stop while Runtime Jobs are active or unclosed" and the CLI's stderr; the daemon kept running and nothing was removed. With the real CLI, the uninstall succeeded |

The CLI's own exit 75 over current Jobs is measured by #2411
(`windows_service_uninstall_process.rs`).

## Local checks

See the commit message.

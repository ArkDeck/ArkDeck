# TASK-RKFUI-001A HDC → Loader characterization probe

This is the one-run E1 harness authorized by CHG-2026-026. The r5 closure pins the HDC client
and pre-existing server to the exact authorization merged as
`PR#481@0f0a79aff7ede1519b9fbc0cbdca12b5c687ef07`:

- absolute path:
  `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`;
- reported version: `Ver: 3.2.0f`;
- SHA-256: `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`.

The old `Ver: 3.2.0d` /
`48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260` pair is a
fail-closed drift case, not a fallback pin. This is not a generic HDC or Rockchip command
wrapper.

CHG-2026-026 r6 adds the authorization merged as
`PR#491@37e16c5dd42951c02422627b9f7ca0d72a5cdafc`. It closes clean
`rkdeveloptool` source provenance through one protected-main reviewed tuple:

- artifact SHA-256:
  `bbd7bdc0fb121d414fb61085e77211cc1fdd9a3b6c6b285c54380f70e56c9923`;
- upstream commit: `304f073752fd25c854e1bcf05d8e7f925b1f4e14`;
- source acceptance: `PR#445@cbad982cc211c7d8579a025b8c35f4ed1a519f16`;
- reviewed evidence:
  `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001/clean-discovery-repin-2026-07-24.md`,
  SHA-256 `d0b5089954e19a4aba354846fe6108b2d5c89bfc12ab0396c2cd7eb4a082189a`.

The registry does not independently create approval: the trust root remains protected `main`
plus maintainer PR review/merge. The probe verifies the exact registry tuple and reviewed
evidence bytes before external commands, then separately verifies the selected executable's
regular-file/executable status, hash, version, ad-hoc signature and absent quarantine. It never
derives source from the executable parent, an ancestor `.git`, a live checkout HEAD or
`/usr/bin/git`. Moving the same exact binary under an unrelated Git repository therefore does
not change the source-provenance verdict.

The production command surface is closed:

- fixed pinned HDC executable;
- fixed read-only target and firmware observations;
- exactly one possible E1 argv:
  `hdc -t <durable-connect-key> shell reboot loader`;
- exact clean `rkdeveloptool` plus `["ld"]` for bounded read-only observation;
- no HDC server start/stop/migration/reconfiguration;
- no `ppt`, `wlx`, `rd`, Flash, erase, format, unlock, update, host shell, `sudo`, helper, driver,
  ACL/group or system-rule mutation.

CHG-2026-026 r4 registers two exact `ld` line-termination families: every non-empty record in
one complete stdout uses LF, or every record uses CRLF. A final terminator is mandatory. Bare CR,
mixed LF/CRLF, missing final terminators and empty records remain blocked. This normalization
does not change device semantics: Maskrom and every non-`0x2207:0x350a + Loader` observation
remain ineligible.

Before dispatch the harness verifies the r6 authorization closure, window and every target/tool
pin, acquires a
per-target mutation lane, durably saves `OriginalTargetSnapshot`, revision-1
`CurrentDeviceBinding`, impact confirmation, the global `maxRuns=1` reservation, and the exact
`enterUpdater` intent. A reservation is never refunded; a crash or failed attempt cannot be
retried without another readiness PR.

Raw connect-key, serial and location bytes are written with mode `0600` under:

```text
~/Library/Application Support/ArkDeck/Characterization/TASK-RKFUI-001A/
```

This directory is outside every git repository. Only `sanitized-receipt.json`, which contains
digests and semantic observations, may be copied into task evidence.

Host-only tests:

```bash
python3 -m unittest scripts/rockchip_loader_transition_probe/test_probe.py -v
python3 scripts/rockchip_loader_transition_probe/probe.py selftest-host
```

Future E1 run (only after TASK-RKFUI-001D is marked done by a separate D0 status PR, while the
window is valid, after a fresh real-USB E0 preflight proves zero pre-existing RockUSB candidates,
and after the per-device typed capability evidence gate has been accepted through a
maintainer-merged PR):

```bash
python3 scripts/rockchip_loader_transition_probe/probe.py characterize \
  --rkdeveloptool /absolute/path/to/pinned/rkdeveloptool \
  --impact-confirmation ENTER-LOADER-WILL-DISCONNECT-HDC
```

The command must run in an environment that can reach the already-running localhost HDC server.
It never starts one. Exit `0` means a final capability verdict was produced (which may still be
`unsupported`); exit `1` is a fail-closed preflight/run result; exit `2` is a harness or usage
error. Console output never contains raw target identity.

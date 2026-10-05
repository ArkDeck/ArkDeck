# Windows GJ-1 preflight — 2026-10-05

This record retains the coordinator's preflight facts for inclusion with the
doctor repair. It does not record a completed Journey or hardware acceptance.
The first six software layers were merged through the native stack, reaching
protected main `e957da597d23c001157a05c7ba0a8ce1b3d38d3d` (#2585). The later
Artifact RSS repair (#2587) reached main
`7816eb37521a827c536bedd6a3461570d5d2e699` after the RC below was built.
The RC physical-path repair (#2588) then reached protected main
`91d3446d9f3a94281dd7a2f0cdec6a1a069a3f7f`.

## Preflight facts and blocker

- The development-signed xcopy RC was built from protected main
  `e957da597d23c001157a05c7ba0a8ce1b3d38d3d`. The coordinator verified its
  manifest: **364 files and three signatures**. The package revision remains
  explicit; the later RSS-only commit is not relabelled as its source.
- Before starting the account Runtime, the coordinator verified no listener
  on port 8710 and no DevEco process. This is a point-in-time startup fact.
  The account Runtime subsequently owns its managed HDC server.
- The registered Windows `c2` HDC was observed through that account Runtime:
  `availability: available`, `ownership: arkDeckManaged`,
  `serverHealth: unknown`, `reasonCode: hdc.identityObserved`.
- `doctor` returned exit **69**, `healthRequirementFailed`. The source
  diagnosis is `Host::doctor_facts` in
  `rust/crates/arkdeck-agentd/src/host.rs`: the full owner-backed Artifact,
  discovery, cleanup and recovery facts are gated to macOS. Windows falls
  through to default facts and discovery based only on `self.provider`, even
  when its managed HDC and durable owners are composed. The successful HDC
  identity observation does not make that doctor result a pass.
- Preflight stopped before any GJ Job submission or dispatch. No
  `REAL_DEVICE_PASS` or hardware acceptance evidence was produced. The
  original raw capture remains private and unmodified. This draft did not
  read the account Runtime or raw capture and made no Runtime/HDC calls.

Account, serial, connect-key, machine-name and user-directory values are omitted.
The doctor repair and its tests belong in the same implementation layer as this
record; this preflight result does not claim that repair has passed.

## Local targeted checks

The coordinator built the RC using
`python D:/src/ArkDeck-wt/tools/gj1/build_rc.py`, which checks clean protected
main and invokes `windows/scripts/package-rc.ps1 -SigningMode development -Smoke`
through the shared slot runner. Build log:
`D:/src/ArkDeck-wt/tools/logs/rc-build-e957da597d23.log`. The package verification
counts and doctor exit above are the coordinator's reported observations;
they were not rerun for this draft.

The original build produced the signed package but exited 1 at its smoke's
logical/physical image-path comparison. The TASK-XPA-022 path repair subsequently
smoked that byte-unchanged ZIP successfully in a quiet window: first doctor,
installed App UIA, running doctor, normal uninstall and all original cleanup
assertions passed. The initial path failure and the intervening parallel
account-tree cleanliness failure remain recorded; neither is relabelled as a
successful run. The GJ-1 account-doctor blocker above is a separate result.

The preceding software increments retain their exact commands, exits and local
logs in their respective TASK-XPA-008/010/011/012/025 run records. In particular,
the RSS increment passed 27 daemon-free Windows checks and the Ubuntu harness
lane (277 tests: 264 passed, 13 explicit skips), with fmt, SDD and diff checks
passing. Its earlier signed-daemon 1 MiB correctness check remains separate
from reference performance or device acceptance.

For this preparation, only source and read-only GitHub metadata were inspected.
No test, build, doctor retry, daemon start, agentd/hoststore suite, port-8710
probe or acceptance command was run. Doctor-fix validation is not yet part of
this record. No task status, ruling, platform, coverage or baseline was edited.

## CI

Read-only PR metadata confirms the final heads below were merged and both
required aggregates (`guard`, `swift`) succeeded. The additional harness run
is recorded where applicable. Skipped lanes are not represented as executed.

| PR | Final head | Guard run (SUCCESS) | Swift run (SUCCESS) | Harness run (SUCCESS) |
| --- | --- | --- | --- | --- |
| [#2579](https://github.com/ArkDeck/ArkDeck/pull/2579) | `cf13e6e1d5b9a7d1c1088b11cd07f583a4e76cc5` | [37263980331](https://github.com/ArkDeck/ArkDeck/actions/runs/37263980331) | [37263980574](https://github.com/ArkDeck/ArkDeck/actions/runs/37263980574) | — |
| [#2580](https://github.com/ArkDeck/ArkDeck/pull/2580) | `9ff969911316ff080ed235c0368dcc57daf06bee` | [37264532417](https://github.com/ArkDeck/ArkDeck/actions/runs/37264532417) | [37264532739](https://github.com/ArkDeck/ArkDeck/actions/runs/37264532739) | — |
| [#2582](https://github.com/ArkDeck/ArkDeck/pull/2582) | `f5cff0e0e8ffa9a26d932af4ac250360f0725ee3` | [37265058050](https://github.com/ArkDeck/ArkDeck/actions/runs/37265058050) | [37265058218](https://github.com/ArkDeck/ArkDeck/actions/runs/37265058218) | — |
| [#2583](https://github.com/ArkDeck/ArkDeck/pull/2583) | `e773ce5ee09ca9aa131727eaeb458027ab153474` | [37265636576](https://github.com/ArkDeck/ArkDeck/actions/runs/37265636576) | [37265636814](https://github.com/ArkDeck/ArkDeck/actions/runs/37265636814) | — |
| [#2584](https://github.com/ArkDeck/ArkDeck/pull/2584) | `ced9d7669f45738740f8dff1afe5feb270b351dd` | [37272867698](https://github.com/ArkDeck/ArkDeck/actions/runs/37272867698) | [37272868063](https://github.com/ArkDeck/ArkDeck/actions/runs/37272868063) | — |
| [#2585](https://github.com/ArkDeck/ArkDeck/pull/2585) | `6df51fb094143510b73560ef3b121e9854948e86` | [37272905509](https://github.com/ArkDeck/ArkDeck/actions/runs/37272905509) | [37272905790](https://github.com/ArkDeck/ArkDeck/actions/runs/37272905790) | [37272905527](https://github.com/ArkDeck/ArkDeck/actions/runs/37272905527) |
| [#2587](https://github.com/ArkDeck/ArkDeck/pull/2587) | `75f5586a8642c9e94b989ed0483d37e49218711e` | [37278341322](https://github.com/ArkDeck/ArkDeck/actions/runs/37278341322) | [37278341738](https://github.com/ArkDeck/ArkDeck/actions/runs/37278341738) | [37278341334](https://github.com/ArkDeck/ArkDeck/actions/runs/37278341334) |
| [#2588](https://github.com/ArkDeck/ArkDeck/pull/2588) | `9edb1c076faf217b9143f54f9e63a8a543124d9f` | [37279331550](https://github.com/ArkDeck/ArkDeck/actions/runs/37279331550) | [37279331826](https://github.com/ArkDeck/ArkDeck/actions/runs/37279331826) | — |

These results verify the recorded software heads. The upcoming doctor repair
has no PR/head/run result in this draft. CI success does not complete GJ-1,
grant device authority or replace the Runtime's acceptance evidence.

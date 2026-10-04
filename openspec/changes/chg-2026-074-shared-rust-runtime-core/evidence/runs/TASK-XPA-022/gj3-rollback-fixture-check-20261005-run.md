# TASK-XPA-022: the GJ-3 rollback fixture check (phase A G3), 2026-10-05

Stacked on the G9 generator (`gj-record-generator-20261005-run.md`).

## What macOS had

There was no check. The macOS rounds judged the fixture by hand:

- 2026-08-05 (`runs/TASK-DHA-001/gj3-native-debug-real-device-pass-2026-08-05.md`): the fixture
  was built so that every host check accepts it (a valid `armeabi-v7a` ELF32 with a GNU build ID
  and a code sign block) while its `DT_NEEDED libarkdeck_ghost.so` cannot resolve on the device.
- 2026-09-09 (`runs/TASK-XPA-003/run.md`): its SHA-256 was matched to that same fixture,
  `260a533a…6d3a`.

## The minimal check

It is part of `gj_record assemble`'s GJ-3 criteria. It reads the fixture import's `artifact import
inspect` (`gj3-<d>-fixture`) and the rollback Job's `job show`. The fixture applies to the
current Target only when all of these hold:

- **Pinned digest.** The import is the pinned digest. `ROLLBACK_FIXTURE_SHA256` is the macOS
  fixture; another fixture is a reviewed change to the pin.
- **This Target.** It was imported for this Target at the forward leg's binding revision.
- **Valid ELF.** The Runtime's own ELF validation in the import receipt names a build ID.
- **ABI.** Its ABI equals the ABI the forward leg's library was verified loaded under in the
  target process (`verification-report.json` `abi`). That is the target's ABI as the device
  showed it, not a typed value.
- **Lease.** The rollback Job's materialized `libraryArtifactLease` is that import's lease.
- **Published first.** The rollback Job verified `atomic-publish` before it rolled back. A
  fixture refused at admission (on ABI, for example) proves only that refusal.

Any failure leaves GJ-3 not `REAL_DEVICE_PASS`, with the failing criterion named.

## Not checked, because the Runtime does not publish it

- The import receipt's validation carries no code-sign verdict and no `DT_NEEDED` list.
- That the fixture fails on the device is proved by the rollback leg itself: `start-target`
  failed, then `rollback-native-library` was verified.

## Docs

The phase A runbook's §4.3 lists the fixture import steps and the check. G3 is marked closed in
§4.6, §4.7 and §7.

## Checks

- `cd scripts && python -m unittest discover -s gj_record -t .`: 36 tests OK. The 5 new tests
  cover a fixture for another ABI, an unpinned fixture, a rollback that consumed another lease,
  a missing fixture import (`IMPLEMENTING`), and a failure before publication.
- `PYTHONUTF8=1 sh scripts/check-sdd.sh`, and `git diff --check`.

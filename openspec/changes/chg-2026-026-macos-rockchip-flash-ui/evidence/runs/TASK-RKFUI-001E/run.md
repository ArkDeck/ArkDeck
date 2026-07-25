# TASK-RKFUI-001E — read-only Sandbox selection characterization

- Captured:2026-07-25T01:58:31Z–2026-07-25T01:59:23Z
- Executor:agent（两次 `NSOpenPanel` 选择由维护者完成）
- Evidence class:`signedSandboxHostOnlySelectionCharacterization`
- Result:`blocked`
- Hardware required/used:no/no

## Input closure

- proposal r7 merge OID:
  `c8a7db7c33b1d7651117ff94498ae548fae963f8`；evidence-only 分支从后续
  `main` `cc5e6f359c73f37e34fcc4f055429abc0f94e8e0` 创建，前者是其 ancestor，后续提交
  只涉及 CHG-2026-031，与本任务 allowed paths 不重叠。
- current proposal/design/tasks/verification blobs:
  `6c8c938d85ce6efe4ad0a1d6adae4d1e6460df1d` /
  `4ef1cd0a36feb72e18427573db107f4d26da76fd` /
  `2856bd5645b92b6f6deb6c055fae1e1fa6a50bfe` /
  `1974766d44163f0d0de23aca467db5e48411a77a`。
- r7-pinned Probe inputs 在 characterization 开始前精确命中：
  `probe.py` `b703baecb0c80a18e73b40028163cc1adda22133`；
  `RockchipE0ProbeApp.swift` `2c763da059c7adf65a4aec170e71c042dbed4288`；
  `Probe.entitlements` `dab555e5b3d03480ab43403ae25a34a6e6822e11`；
  `test_probe.py` `3ffc0f7ac675af1bf9ed3b6e21daf1c059feec2a`。
- characterization candidate 只把
  `com.apple.security.files.user-selected.read-write` 替换为
  `com.apple.security.files.user-selected.read-only`；其余五项 entitlement、bundle ID、
  Hardened Runtime 与 App source blob 保持不变。candidate 的临时
  `probe.py`/entitlements/tests/README/fixture-source blobs 分别为
  `0a3b7baf29c1687a0f9684fe08655f16819c2446` /
  `f2c71dc71c38abe01829e6000d10ae49a2272f04` /
  `f28057827ff93471d8b02e81da2294b6e70369f9` /
  `8b11ccf712a869f9b4465121068e09bb4293017c` /
  `85d79bf61086acbaf0c63af01d2352b021a1ed64`。这些 implementation 变更未提交到本
  evidence-only PR。
- PR #509 historical evidence 保持 immutable；其 Markdown/JSON blobs 仍为
  `4c376fbfee73933b8c9da315d6c60dab2eed2f8a` /
  `13ad77c6b5be0c503506f0ddc70665c48e42c122`。

## Environment

- macOS `26.5.2` (`25F84`), arm64
- Xcode `26.6` (`17F113`)
- Apple Swift `6.3.3`
- Apple clang `21.0.0` (`clang-2100.1.1.101`)
- Python `3.14.6`

## Build and closed fixture

Commands used path placeholders in this repository-safe record; all concrete build/run paths
were beneath one fresh private-temp directory and were not committed:

```text
python3 scripts/rockchip_e0_probe/probe.py build-fixture \
  --output-root <private-temp>/fixture
python3 scripts/rockchip_e0_probe/probe.py build \
  --output-root <private-temp>/direct-app
python3 scripts/rockchip_e0_probe/probe.py build \
  --output-root <private-temp>/symlink-app
```

- `candidate-fixture-source.c` was compiled twice in the host-only test and produced the same
  signed bytes; the selected fixture SHA-256 was
  `ac16dc31b98440622c19af303c4c5082a872669dffe88fab36a9b0b3bbec257b`, not the registry
  pin `bbd7bdc0…9923`.
- The target was a regular executable named `rkdeveloptool`, ad-hoc signed with CDHash
  `5646303119253586ce9c21f8440def813a259801`, signature-valid and quarantine-absent. The
  second selector was an exact one-layer symlink resolving to that same target.
- Two fresh App bundles independently passed `codesign --verify --deep --strict`, exact
  six-entitlement equality and Hardened Runtime checks. Both executable hashes were
  `76954b9d6c383568226c681a7d4aca95fd82246b2e7d5eea130200f8a260437c`.
- No `user-selected.executable`, `LSFileQuarantineEnabled`, excluded-path setting, xattr write,
  pinned-tool copy/rebuild/download, helper or broker was used.
- The first sandbox-contained GUI orchestration attempt exited before `NSOpenPanel`
  (`probe host exited -6`) because the command sandbox could not host the GUI. It created no
  selection/bookmark/receipt and accessed no fixture/device. The two evidence runs below were
  then launched through the approved GUI execution boundary, each with a fresh App bundle.

## Run matrix

### Canonical direct

```text
python3 scripts/rockchip_e0_probe/probe.py characterize \
  --app <private-temp>/direct-app/RockchipE0ProbeApp.app \
  --fixture-root <private-temp>/fixture \
  --selector canonicalDirect \
  --receipt <private-temp>/direct-selection-receipt.json \
  --raw-root <private-temp>/direct-raw
```

- `selectionCompleted=true`, selected entry matched the canonical fixture and resolved to the
  expected target; `securityScopeStarted=true`.
- `.withSecurityScope` bookmark creation/resolution returned
  `bookmarkCreationOrResolutionFailed`, so `bookmarkCreated=false`.
- The App therefore never reached its hash/signature/quarantine preflight:
  `appObservedSHA256=null`, `appObservedSignatureIntegrityValid=null`,
  `appObservedQuarantinePresent=null`; the required
  `preflightFailure=executableHashMismatch` was not observed.
- Host checks still proved target hash/size/CDHash/signature unchanged and quarantine absent
  both before and after selection.
- Verdict:`blocked`.

### Single-layer symlink

```text
python3 scripts/rockchip_e0_probe/probe.py characterize \
  --app <private-temp>/symlink-app/RockchipE0ProbeApp.app \
  --fixture-root <private-temp>/fixture \
  --selector singleLayerSymlink \
  --receipt <private-temp>/symlink-selection-receipt.json \
  --raw-root <private-temp>/symlink-raw
```

- Host pre/post checks proved the selector remained a one-layer symlink and resolved to the
  same fixture. The App selection completed and `securityScopeStarted=true`.
- The receipt shows that the returned URL did not preserve the lexical symlink entry but did
  resolve to the canonical target (`selectedExpectedEntry=false`,
  `selectedResolvedTarget=true`), which is consistent with `NSOpenPanel` normalization.
- Bookmark creation/resolution again returned `bookmarkCreationOrResolutionFailed`;
  `bookmarkCreated=false`. Hash/signature/quarantine App preflight was not reached, and
  `executableHashMismatch` was not observed.
- Host checks again proved target hash/size/CDHash/signature unchanged and quarantine absent
  before and after.
- Verdict:`blocked`.

## Safety and dispatch accounting

Both sanitized receipts record every counter below as zero:

```text
selectedProcess ldReadOnly usb network hdc device deviceMutation destructive
sudoOrPrivilegeElevation helper driverInstall systemRuleMutation groupMutation
aclMutation xattrWrite
```

The fixture was never executed. No HDC, `rkdeveloptool`, USB/device, E1/E2, mutation,
destructive, privilege, install, system-rule/group/ACL or network operation was dispatched.
Raw stdout/stderr were empty. No locator, full path, raw xattr payload, serial or LocationID is
stored in evidence.

## Verification

```text
python3 -m unittest scripts/rockchip_e0_probe/test_probe.py -v
# 9 tests, PASS
```

The transient candidate tests explicitly verified the exact six-key entitlement map,
read-write/executable-writing entitlement absence, Info.plist quarantine-override absence,
deterministic wrong-hash fixture build and the all-zero characterization dispatch surface.

The final evidence-only tree also passed:

```text
python3 -m unittest scripts/rockchip_e0_probe/test_probe.py -v
# 6 baseline tests, PASS
ARKDECK_PYTHON=<existing-sdd-venv>/bin/python sh scripts/check-sdd.sh
# 0 errors, 0 warnings, 111 acceptance IDs
git diff --check
# PASS
```

Repository-safe JSON assertions independently rechecked both blocked verdicts, bookmark failure,
unchanged bytes/signatures, pre/post quarantine absence, exact read-only entitlement maps,
forbidden entitlement absence, all-zero counters and privacy booleans. Committed sanitized
receipts and fixture source are byte-identical to the private-temp run outputs.

## AC conclusion and handoff

- TASK-RKFUI-001E result:`blocked`. Neither selector satisfied the required
  bookmark + `executableHashMismatch` conjunction.
- This run does not prove or disprove selection-time quarantine behavior after a successful
  read-only bookmark round-trip, because both cases stopped earlier. It is not real E0,
  real-hardware, USB access, external executable launch or product-delivery evidence.
- Per r7 sequencing, the read-only entitlement/Probe candidate is not retained. This PR contains
  only fail-closed evidence and does not modify TASK status. TASK-RKFUI-001 remains blocked;
  any remediation or alternative product boundary requires a new D1 governance/readiness PR.

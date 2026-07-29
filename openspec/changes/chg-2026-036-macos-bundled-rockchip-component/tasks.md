# CHG-2026-036 Tasks

> r1 proposal PR 只登记 change package。六个任务全部保持 `blocked`；正式 approval、
> 每个 D1 readiness、implementation/evidence、D0 done、verification 与 archive
> 分别使用独立 PR。任一任务不得把后继任务的工作投机堆入同一 PR。

## TASK-BRC-001 — 闭合 source、license、dependency 与 distribution 决策

- Status:done（r1 D0 status-only；仅在维护者对本单文件 PR 的 exact head
  review/merge 后生效。结论完全由已合入的 readiness + decision/evidence 与
  deterministic checks 决定，不增加 scope、risk acceptance、authorization 或
  product/build/device effect。）
- Historical Status:blocked → ready（CHG-2026-036 r1 proposal #535 与
  approval-only #536 只批准 change scope；D1 readiness #537 exact head
  `34aa3d140e6e094d811550354a29df55a74215a1` 经 `lvye` APPROVED，并以
  `e32cdaba9f465fc2e264f8b61ad135efab3487a8` 合入后，TASK-BRC-001 才
  `ready`。）
- Completion record:
  - **Decision acceptance:closed。**D1 decision/evidence #538 exact head
    `44970db58cfe39c241e3b3961c52e976b79fff68` 经 `lvye` 于
    `2026-07-25T08:51:02Z` APPROVED，并以
    `4a461ba40f532500e635509455acae95376757ca` 于
    `2026-07-25T08:51:08Z` 合入 protected `main`；readiness 与 decision merge
    均为本状态 PR audit base 的 ancestor。该 merge 使 record 的
    `proposedDisposition: accept` 生效，不再是 Agent 自报。
  - **Evidence identity:closed。**
    `docs/release/rockchip-component-distribution.md` blob =
    `60dd039582b216d0b2fb21336fe4ee0abc9b0f7c`；
    `evidence/runs/TASK-BRC-001/run.md` blob =
    `bab53f9da272d0dbeabdf43cbe90bfc20d16422b`；本状态修改前
    `tasks.md` blob = `824b0daea22df803fa4c84ab6849420942e376e7`。
    三个 objects 均由 decision merge 引用或承载，内容与 #538 exact head 一致。
  - **Deliverable/AC gate:closed。**accepted record 固定
    `rkdeveloptool@304f073752fd25c854e1bcf05d8e7f925b1f4e14`、
    `macOS 14.0+ / arm64`、signed libusb 1.0.30 static、Apple
    system-provided libiconv、SPDX 2.3、GPL-2.0 §3(a) same-release complete
    corresponding source、five-year minimum retention、owner/SLA 与 atomic
    App/component/source/SBOM update/rollback；run 对
    `BRC-SUPPLY-001`、`BRC-HANDOFF-001`、本任务 slice 的
    `AC-FLASH-013-01`/`AC-UX-007-01` 给出 PASS，并明确未声称其余
    runtime/platform/hardware slice。
  - **No-effect/scope gate:closed。**decision/evidence 只新增上述 record/run；
    ArkDeck/App/rkdeveloptool/libusb build/launch、binary/package/sign/notary/install/
    update、HDC/process/USB/device、E1/E2/destructive 与 privilege/system mutation
    counters 全为 0；Core/spec/contracts、HDC、CHG-2026-026、product、registry、
    hardware matrix 零变化。本 D0 PR 只修改当前 `tasks.md` 的 TASK-BRC-001
    status/completion record。
  - **Deterministic checks:closed。**audit base
    `4a461ba40f532500e635509455acae95376757ca` 上，readiness/decision ancestry、
    exact blobs、accepted disposition、AC mapping 与 open-PR path ownership
    均复核；`scripts/check-sdd.sh` = 0 error / 0 warning / 111 acceptance IDs，
    `scripts/test_check_pr_paths.py` = 24/24 PASS，`git diff --check`、exact
    changed-path 与 secret/privacy scan 均 PASS。
  - **Successor remains gated。**本 done merge 只满足 `TASK-BRC-002` 的 dependency；
    TASK-BRC-002 继续 `blocked`，必须另开 D1 readiness pin 本 done merge、
    distribution record 与 exact source/toolchain/build/SBOM inputs。不得在本 PR
    下载、构建、vendor、生成 registry/SBOM/artifact 或启动 002。
- Readiness review:
  - **Approval/dependency gate:satisfied。**ADR-0003 所属 CHG-2026-035 archive
    #534 exact head `162a4f320763f3b25461ca20e92d49dbaf7d445a` 经 `lvye`
    APPROVED，并以 `5fc517f7ecfccd61ed0d140f9080e4b49e2cad95` 合入 protected
    `main`；CHG-2026-036 proposal #535 exact head
    `a56eb3e9c0d41b35c208d4372b7f2007c8e5976f` 经同一维护者 APPROVED，
    并以 `16b3dbc7f7d2c565f15388bc1ca0f2aef41dd867` 登记；approval-only
    #536 exact head `3a1e44da3e49bd7c83fa5a4f9ffb8f8b3d34f125` 经同一维护者
    APPROVED，并以 `9bbc51313af9575c3d762db0f15692da753a3e01` 合入。三条 merge
    OID 均为当前 `main` 祖先；proposal/approval/ADR 仍不替代本 D1 或
    GPL/dependency/distribution 接受。
  - **Audit base/input pins:closed。**readiness audit base =
    `9bbc51313af9575c3d762db0f15692da753a3e01`。以下 Git objects 均从该
    base 实测；`tasks.md` blob 只表示本 PR 修改前输入。decision/evidence 开工时必须
    基于本 readiness merged OID，确认上述三个 merge 均为祖先，并逐项重核所有
    非自载体 pin；`tasks.md` 改核 readiness merge 中 reviewed 内容。若 main 在 merge
    前后由无重叠 PR 前进，不单凭 whole-main OID 失效；但任一 pinned blob、上游
    object/source archive、license/dependency 一手来源、planned-path absence 或
    allowed-path ownership 漂移，必须回到 `blocked` 并 fresh readiness：

    ```yaml pins
    - artifact: TASK-BRC-001 readiness audit base
      commit: 9bbc51313af9575c3d762db0f15692da753a3e01
    - artifact: CHG-2026-035 archive merge
      commit: 5fc517f7ecfccd61ed0d140f9080e4b49e2cad95
    - artifact: CHG-2026-036 proposal merge
      commit: 16b3dbc7f7d2c565f15388bc1ca0f2aef41dd867
    - artifact: CHG-2026-036 approval merge
      commit: 9bbc51313af9575c3d762db0f15692da753a3e01
    - path: openspec/changes/chg-2026-036-macos-bundled-rockchip-component/proposal.md
      blob: 7c9cf2815927ac1d8dfda2a5eac8788a1d10621b
    - path: openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md
      blob: c343320d00de2a22d6993325000997e7f5f7c1e1
    - path: openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md
      blob: e86c11a6cfda1b066ae04f2d9c7c07e7d68b172a
    - path: openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md
      blob: 86f82516a2b8bd1de91dffb282499d68ebdba3cf
    - path: openspec/changes/chg-2026-036-macos-bundled-rockchip-component/acceptance-cases.yaml
      blob: cd179bf8627ade54a77e205962e98200ac8374c9
    - path: openspec/changes/chg-2026-036-macos-bundled-rockchip-component/spec-impact.md
      blob: 32027c2c667185ccbac4914725481d905890e813
    - path: docs/adr/0003-macos-rockchip-tool-execution.md
      blob: cef2cbe1190e05b591c13396e7ef5daf9fb90ef4
    - path: openspec/changes/archive/2026-07-25-chg-2026-035-macos-rockchip-tool-architecture/tasks.md
      blob: a5f7af86b55e68d5fa60149284f9f411836a875a
    - path: openspec/changes/archive/2026-07-25-chg-2026-035-macos-rockchip-tool-architecture/verification.md
      blob: d41516d6c04bc8bf709b9f706fb61424f22fc49a
    - path: openspec/changes/archive/2026-07-25-chg-2026-035-macos-rockchip-tool-architecture/evidence/runs/TASK-RKTA-001/candidate-matrix.md
      blob: 7af58939d359aca7b1626c18070c676b16c5f04b
    - path: openspec/changes/archive/2026-07-25-chg-2026-035-macos-rockchip-tool-architecture/evidence/runs/TASK-RKTA-001/run.md
      blob: 49d2688b0cba20b0f4d142d63d3ba46a3739313d
    - path: docs/release/macos-auto-update.md
      blob: ecc8d8a02dbe37d66ca1716aeeafa1491f3a7af8
    - path: openspec/platforms/macos/profile.md
      blob: d27264ab1ee1d0665062016a6d7e301f9ce924bd
    - path: openspec/planning/open-questions.md
      blob: cb078ced94769cce62adf5f9322f929daeb46752
    - path: openspec/integrations/rockchip/profile.md
      blob: 706e94f0e3704ed76809cce1c42002faa3d14d9c
    - path: openspec/integrations/rockchip/rockusb-discovery/1.0.0/registry.yaml
      blob: 394e2a8c588c531208cd3154a1dc8638ad77010e
    - path: openspec/changes/chg-2026-026-macos-rockchip-flash-ui/tasks.md
      blob: e83bcfea555fda6c8b6309ed16bf5f6e33fa40a0
    - path: openspec/specs/flashing/spec.md
      blob: c914d587bf4893a3f4a9f776a28c74e7ef002c8e
    - path: openspec/specs/workflow-journal-recovery/spec.md
      blob: f97c64785533f832d6798a63e8c7c96080bb7b69
    - path: openspec/specs/desktop-ux-observability/spec.md
      blob: 8f7613a4443605fcdac2aec0346b925948fcae09
    - path: openspec/contracts/provider-contracts.md
      blob: ceb6709fb405fc46d72ef2126b715e252ac720ab
    - path: openspec/contracts/workflow-step-registry.yaml
      blob: d9121ef78531560ab856dfa07468ce1ab4d42df6
    - path: openspec/planning/agent-failure-patterns.md
      blob: ed539ff8436bccda1d8bb8a3b85a0f6e494fea81
    ```

    `docs/release/rockchip-component-distribution.md`、
    `evidence/runs/TASK-BRC-001/` 与
    `openspec/integrations/rockchip/bundled-component/` 在 audit base 均不存在。
    前两者只允许本任务创建；integration registry 属于后继 `TASK-BRC-002`，本任务
    不得创建、预填或占用。
  - **rkdeveloptool source/license dossier:closed for review。**唯一 upstream
    source pin 固定为
    `https://github.com/rockchip-linux/rkdeveloptool/commit/304f073752fd25c854e1bcf05d8e7f925b1f4e14`
    （commit/tree =
    `304f073752fd25c854e1bcf05d8e7f925b1f4e14` /
    `9908d5bd43d32659500e6f0d0734755ee557122e`，commit time
    `2025-03-07T07:34:30Z`，GitHub signature `verified`）。exact codeload source =
    `https://codeload.github.com/rockchip-linux/rkdeveloptool/tar.gz/304f073752fd25c854e1bcf05d8e7f925b1f4e14`，
    59,310 bytes，SHA-256 =
    `389ba41af6986c16f1eeebdc1febcb0bf4b8acb7abd694d3d652e78504215843`。
    Primary blobs 固定为 `license.txt`
    `25e216a7063f10f19bf5b77b3a351f5bbd62e268`、`CMakeLists.txt`
    `90faa72f90bf6111d26559d278685cdb5c39811a`、`Makefile.am`
    `1b6385db22ce7b5c9181e043473545367afeb61d`、`configure.ac`
    `c21355d35cfb0b9dbe9379c897254433c5c54dfe`、`Property.hpp`
    `ddc7894b85ba91befaba8838605984fff555df0a`、`main.cpp`
    `42bfbabaa76b9995d01784a1fc68225bbba0130f`。`license.txt` 包含 GPL v2
    文本；九个 source file（`main.cpp`、`RKComm.cpp`、`boot_merger.h`、
    `RKLog.cpp`、`RKDevice.cpp`、`RKImage.cpp`、`RKBoot.cpp`、`RKScan.cpp`、
    `crc.cpp`）声明 `GPL-2.0+`；`Property.hpp` 另有保留 header 的
    redistribution notice。accept 不能只复制 repository label 或把上述不同 header
    折叠为未经复核的单一 license expression；必须完成逐文件 inventory、明确
    ArkDeck 分发适用的 license expression/notice/modification/source obligations，
    任何歧义均为 blocked。
  - **libusb dependency dossier:closed for binary decision。**上游 CMake 硬编码
    Homebrew `libusb/1.0.22` 动态库路径，但这不是可接受输入。候选只允许：
    1. `libusb-1.0.22`：official release/tag commit/tree =
       `0034b2afdcdb1614e78edaa2a9e22d5936aeae5d` /
       `c248ce9378a2cc2acccde6ab6add09dbd8223dc4`，published
       `2018-03-25T01:22:38Z`；official
       `https://github.com/libusb/libusb/releases/download/v1.0.22/libusb-1.0.22.tar.bz2`
       = 598,833 bytes，SHA-256
       `75aeb9d59a4fdb800d329a545c2e6799f732362193b465ea198f2aa275518157`；
       tag commit unsigned、release 无 detached signature，`COPYING` blob
       `5ab7695ab8cabe0c5c8a814bb0ab1e8066578fbb`；
    2. `libusb-1.0.30`：official release/tag commit/tree =
       `87a55632db62c9bdc58cd31d3ccfa673f1bb017f` /
       `1dab476e854bb3605113e4ff3e78f9130aac5d95`，published
       `2026-05-17T22:06:02Z`；official source =
       `https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2`
       = 656,112 bytes，SHA-256
       `fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf`；
       detached signature SHA-256
       `7e8916e689a399b98df1087cfc48eab33a6bfd8027291c5af00c3fbba90a2cec`
       由 bundled `KEYS` 中 primary fingerprint
       `C68187379B23DE9EFC46651E2C80FF56C6830A0E` 的 signing subkey
       `9C7EA94939C69C4FBC3DBFA8AA0639079EFB61B9` 验证；`COPYING` blob
       `5ab7695ab8cabe0c5c8a814bb0ab1e8066578fbb`。

    accepted record 必须只选一个 exact version/source/hash，给出选择或拒绝旧
    unsigned release 的安全/兼容理由，固定 source/build/link mode、LGPL
    obligations、notices、corresponding source、modification/build-script handling
    与 transitive closure；不能临场选择第三个版本、Homebrew bottle 或 ambient
    `/usr/local`/`/opt/homebrew`。
  - **libiconv dependency dossier:closed for binary decision。**pinned source 没有
    iconv API/include use，只有 CMake 的 Homebrew link path；ADR-0003 仍要求明确
    `systemProvided | bundled`，不能把“当前没有调用”擅自改写成第三个 disposition。
    候选只允许：
    1. `systemProvided`：audit SDK = macOS 26.5 (`25F70`)；
       `usr/include/iconv.h` SHA-256
       `3fcec709f204ac60c7941488b9e49d8536150d356beff1f8cf8926cdfef7456d`
       （BSD-2-Clause header）；`usr/lib/libiconv.2.tbd` SHA-256
       `b257056db07bac43cd4d2f6fd806605ad3462fa0bb99918dc43c64176a018cea`，
       install-name `/usr/lib/libiconv.2.dylib`，current/compatibility version 7。
       这些 audit-host facts 不证明目标 architecture/minimum OS/runtime availability；
       accepted record 必须另行用 Apple SDK/runtime primary facts闭合；
    2. `bundledGNU1.19`：official source =
       `https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.19.tar.gz`，
       5,921,103 bytes，SHA-256
       `88dd96a8c0464eca144fc791ae60cd31cd8ee78321e67397e25fc095c4a19aa6`；
       detached signature 由 GNU keyring 中 Bruno Haible primary fingerprint
       `E0FFBD975397F77A32AB76ECB6301D9E1BBEAC08` 验证；source 中
       `COPYING.LIB` SHA-256
       `20e50fe7aae3e56378ebf0417d9de904f55a0e61e4df315333e632a4d3555d95`，
       `COPYING` SHA-256
       `8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903`。

    accepted record 必须只选一个 disposition，固定 link/runtime closure 与
    license/notice/source handling；若需要移除 libiconv 或选择其他版本，先修订
    ADR/readiness，不能在 decision run 中扩范围。
  - **Distribution decision schema:binary。**唯一 decision owner/reviewer =
    protected-main CODEOWNER `@lvye`；Agent 只整理 primary facts，不能自批 legal/
    distribution acceptance。`rockchip-component-distribution.md` 必须逐字段给出
    `proposedDisposition: accept | block`，并至少闭合：
    `upstream/sourceArchive`、逐文件 `licenseInventory`、
    `arkDeckSeparationAndModifications`、`notices`、
    `correspondingSourceMode/location/availabilityWindow`、`buildScripts`、
    `libusbChoice`、`libiconvChoice`、全部 `transitiveDependencies`、
    `componentArchitectures`、`minimumMacOS`、`builder/toolchain`、
    `hermeticInputs`、`sbomFormat`、`vulnerabilitySources/owner/SLA`、
    `releaseOwner`、`updateOwner`、`rollbackOwner`、`retentionOwner/window`、
    `revalidationTriggers` 与逐项 primary-source refs。SBOM 只能明确选择
    `SPDX-2.3 JSON` 或 `CycloneDX-1.6 JSON`；对应 source delivery/offer 模式、
    时限与公开 release 位置必须具体、可执行、与 GPL/LGPL 决定一致。空白、
    `TBD`、`unknown`、`later`、无 owner/SLA、条件性 accept 或依赖未选择均等于
    `block`。`accept` 仅在维护者 review/merge exact decision head 后生效；
    `block` 必须指出 failed fields，且整个 CHG-2026-036 停止。
  - **Release/update/rollback handoff gate:binary。**accepted record 必须保持单一
    notarized DMG 与 App/component/source/dependency/SBOM 的 atomic tuple；component
    不得有独立下载、自更新、PATH/Homebrew fallback。它必须准确承接现行
    `check + download + verify + Finder handoff`：现状不自动 mount/replace/install，
    也不声明自动 rollback。任何 App/component tuple 变化都使旧 package/E0/hardware
    evidence 失效；rollback 只能返回一个已记录、完整、签名/公证且满足同等 source/
    notice 义务的 tuple，或保持 execute-disabled，不能回退 selected external。
  - **Successor machine gate:binary。**若 proposed disposition 为 accept，record
    必须给 `TASK-BRC-002` 固定 exact upstream/dependency archive digests、source
    extraction rules、builder/toolchain/minimum OS/architectures、link mode、
    network/cache policy、expected dependency graph、SBOM schema、notice/source
    manifest schema、two-clean-builder procedure、normalization/reproducibility
    verdict rule 与 negative-drift cases。任务 001 不生成 recipe/registry/SBOM 或
    artifact；只形成可被 fresh 002 readiness pin 的 envelope。任何 gate 不能转成
    exact machine-checkable input 时，本任务结论必须是 block。
  - **No-effect/source-review gate:binary。**本 task 只允许 Git/GitHub read、Apple/
    upstream/GNU 官方 HTTPS documentation/source/license/signature GET、host SDK
    metadata inspection 与仓库 checker 作为 analyst tooling；source archive 只可
    落在 OS temp，必须记录 URL/size/hash/retrieval time，并与 ArkDeck product/tool
    network effect 分栏。不得把 source/dependency/archive/binary 写入仓库或用户目录。
    configure/build/link/install/package/sign/notarize/launch、App/probe/fixture、
    Process/rkdeveloptool/HDC、USB/device、bookmark/picker、helper/XPC/daemon、
    privilege、entitlement/system-rule/group/ACL mutation、E1/E2/destructive
    dispatch 均为 0。若需要运行产物或设备验证，立即 blocked 并交给后继 task。
  - **Deliverable/consistency gate:closed。**decision/evidence PR 的 exact changed
    paths 只能是
    `docs/release/rockchip-component-distribution.md` 与
    `evidence/runs/TASK-BRC-001/run.md`，task 状态仍为 `ready`。run 必须逐项映射
    `BRC-SUPPLY-001/BRC-HANDOFF-001/AC-FLASH-013-01/AC-UX-007-01`，记录 exact
    commands、source retrievals、zero-effect counters、decision verdict 与 residual
    risks；record/run 的 source/dependency/disposition 必须逐字一致。不修改
    proposal/design/tasks/verification/acceptance/spec-impact、ADR/DEC/profile、
    CHG-2026-026、Core/spec/contracts/integration registry、product/test/script/
    workflow。decision/evidence merge 后另开 D0 status-only PR；不得在同一 PR
    标 done 或启动 002。
  - **Environment/check gate:satisfied。**audit host = macOS 26.5.2
    (`25F84`) arm64、Xcode 26.6 (`17F113`)、Apple Swift 6.3.3
    (`clang-2100.1.1.101`)、Git 2.55.0、GitHub CLI 2.96.0；source dossier latest
    retrieval UTC = `2026-07-25T08:20:03Z`。base 上 `scripts/check-sdd.sh` =
    0 error / 0 warning / 111 acceptance IDs，
    `scripts/test_check_pr_paths.py` = 24/24 PASS。decision/evidence 必须复跑两者与
    `git diff --check`，并用 exact changed-path、forbidden-path、secret/privacy scan
    证明范围；不运行 Swift/product build。
  - **Concurrency/review gate:satisfied。**`2026-07-25T08:20:03Z` 分页完整查询的
    open PR 只有 #523（仅 CHG-2026-034 七个 paths），与本 change/release/evidence
    paths 零重叠；planned decision/evidence/registry paths 均 absent。decision 开工前
    重做 open-PR files/heads 与 planned-path absence；overlap、查询不完整或新 owner
    抢占立即 blocked。本 readiness PR 本身只修改本 `tasks.md` 的 TASK-BRC-001
    section，零 decision/evidence/source/dependency/product 变化。
- Platform:macos
- Requirements：`REQ-FLASH-004`、`REQ-FLASH-013`、`REQ-UX-007`
- Acceptance：`BRC-SUPPLY-001`、`BRC-HANDOFF-001`、
  `AC-FLASH-013-01`、`AC-UX-007-01`
- Depends on：CHG-2026-036 formal approval；ADR-0003 accepted/archive ancestry
- Readiness input pins：见上方 r1 D1 readiness；decision/evidence 开工时从 readiness
  merge 重新核验
- Applicable failure patterns：`AF-001`、`AF-002`、`AF-007`、`AF-009`、`AF-010`
- Production reachability：not applicable；host-only document/legal/distribution
  review，不 build/launch component，不产生 authority/effect
- Trusted fact sources：protected-main Git objects、exact maintainer review/merge、
  upstream repository/license/build files、dependency primary license/security
  records与 Apple distribution documentation；Agent 推断、二手文章、Homebrew
  installation state不能构成 license/distribution 接受
- Allowed paths:
  - `docs/release/rockchip-component-distribution.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/integrations/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/**`
  - `ArkDeckApp/**`
  - `ArkDeck.xcodeproj/**`
  - `Packages/**`
  - `.github/**`
  - `scripts/**`
  - `vendor/**`
- Risk:medium（无 runtime effect，但错误接受会进入可执行代码发布供应链，必须 D1）
- Hardware required:no

### Deliverables

- 一份 maintainer-accepted distribution record，精确闭合：
  upstream/source acquisition、GPL-2.0 obligations、notices、corresponding source/
  source offer、modifications/build scripts、libusb/libiconv 与全部 transitive
  dependency、SBOM/CVE owner、update/rollback/retention；
- 对 architecture、minimum OS、builder/toolchain、hermetic input 与 reproducibility
  verdict 的可执行后继 gate；
- `evidence/runs/TASK-BRC-001/run.md`，结论只能是 accepted 或 blocked；proposal/
  approval merge 本身不算 legal acceptance。

### Verification

- `BRC-SUPPLY-001`：每个 source/license/dependency/distribution criterion 都有
  primary source、owner、明确 verdict 与后继 machine-checkable pin；
- `BRC-HANDOFF-001`：零 product/build/network artifact/process/USB/device effect，
  CHG-2026-026/Core/HDC 决策零变化；
- SDD、allowed/forbidden path、diff 与 secret/privacy scan 全绿。

### Notes / handoff

- 若维护者不接受 GPL-2.0 distribution 或任一 dependency/source-offer 义务，本任务
  记录 blocked 并停止整个 change；不得用下载预编译 binary 或外部工具 fallback。

## TASK-BRC-002 — 实现 hermetic/reproducible build、registry 与 SBOM

- Status:done（r1 D0 status-only；仅在维护者对本单文件 PR 的 exact head
  review/merge 后生效。结论完全由 main 已合入的 readiness +
  implementation/evidence、exact Git objects、hosted reproducibility runs 与
  deterministic checks 决定，不增加 scope、risk acceptance、authorization 或
  build/product/device effect。）
- Historical Status:ready（r3 fresh D1 readiness；#544 exact head
  `d5ac44f8ee96b12bc23a83a4f8c73cc21ab2f589` 经 `lvye` APPROVED，并以
  `d063b3ca775a5e858020e21a7b4a53db31f37144` 合入后，#542 才恢复
  implementation/evidence。）
- Historical Status:ready（r2 readiness #543 已合入；#542 exact hosted-image
  rerun 通过 image/OS/Xcode/SDK facts 后在 GnuPG installed-binary hash gate
  fail closed，未产生可接受 build/reproducibility evidence。r3 合入前 #542
  继续保持 Draft/暂停且不得继续成 PR 工作。）
- Historical Status:ready（r1 readiness #541 已合入；首次 implementation #542
  在 GitHub runner OS exact-fact gate fail closed，未产生可接受远端 build/
  reproducibility evidence。r2 合入前 #542 保持暂停且不得继续成 PR 工作。）
- Historical Status:blocked（TASK-BRC-001 的 decision #538 与 D0 done #540
  已依次合入；001 done 只满足 dependency，不自动接受本任务的 recipe、builder、
  network、registry/SBOM 或 reproducibility 边界。）
- Completion record:
  - **Implementation/evidence:closed。**#542 exact head
    `4d02b9945ecfe2db1e8af7adc98251a1b0ef9589` 经 `lvye` 于
    `2026-07-25T11:58:55Z` APPROVED，并以
    `182757cdc9ca191f2ce0a2d61dfce78440c74cd9` 于
    `2026-07-25T11:59:05Z` 合入 protected `main`；r3 readiness merge
    `d063b3ca775a5e858020e21a7b4a53db31f37144` 是该 merge 的直接父提交，
    r1/r2 readiness、TASK-BRC-001 decision/done merges 也都是祖先。#542 只交付
    readiness 声明的 workflow、repo-owned build tooling、versioned integration
    metadata 与 sanitized reproducibility evidence，任务状态在实现 PR 中仍为
    `ready`。
  - **Git object/artifact identity:closed。**#542 merge 中 workflow/build/test
    blobs 分别为
    `8ccb3e7d9033b89c2dbe746995f5c496427e9d96` /
    `33fe437901b97802f7231449cc16f9bc0bcdc404` /
    `7a6226282d0ea90ce149c1ffe07f705f4993adf0`；recipe/registry/SBOM/notices/
    source-manifest blobs 分别为
    `fa4289b73880540b0db19d24242d039053ae8916` /
    `505122327e877900d7fdb2b908cf6914f207b70f` /
    `e66e3d7f22a4d2079e59edcc51c2682650362689` /
    `6d1f7bf4624972fdb8559d203fd89163c3003c43` /
    `bbce240466dedfc7de3ebb19d1db5fe8b0f3a865`；run/builder-A/builder-B/
    reproducibility blobs 分别为
    `94108fb6f1f0a4d86b027e03ef9885c7360f9c56` /
    `3276b1ef772be3707276e18cb3f8ec9bc38d168b` /
    `5c1d007f1bcac91c896ad19085ff778fae826324` /
    `4fe66aea41198779c158303825c15332403ef6cf`；本状态修改前
    `tasks.md` blob = `7e5e00e55ac794d8f4354a6905841a510b8f0cb4`。
    hosted unsigned artifact 为 247,488 bytes、arm64、minimum macOS 14.0、
    code signature absent，SHA-256 =
    `3caee2136551b4b849daf7e9a906813354f354f8adb61e5f092de49ec7a2e56a`；
    artifact 本身未入仓。
  - **Reproducibility/AC gate:closed。**materialization run
    [30155933128](https://github.com/ArkDeck/ArkDeck/actions/runs/30155933128)
    的 unit、builder A/B、byte comparison 与 receipt upload PASS，整体仅因
    metadata 尚未提交时的预期 committed-metadata audit FAIL；final verification
    [30156115854](https://github.com/ArkDeck/ArkDeck/actions/runs/30156115854)
    在新 fresh builders 上全部 PASS；final exact-head
    [30156181935](https://github.com/ArkDeck/ArkDeck/actions/runs/30156181935)
    对 #542 exact head 的 unit、builder A/B、byte comparison、receipt upload 与
    committed metadata audit 全部 PASS。两 builders 对 unsigned artifact、
    registry、SBOM、notices 与 source manifest byte-identical，normalization =
    forbidden；run 对 `BRC-REPRO-001`、本任务 slice 的 `AC-JOB-005-01` 与
    `AC-FLASH-013-01` 给出 PASS，未声称 package/runtime/Sandbox/hardware AC。
  - **No-effect/scope gate:closed。**#542 未提交 source archive、unsigned Mach-O、
    dylib、build/cache/root、credential 或用户/设备数据；component/App launch、
    package/sign/notarize/install/update、HDC/USB/device、E1/E2/deviceMutation/
    destructive 与 privilege/entitlement/system mutation counters 全为 0；
    Core/spec/contracts、CHG-2026-026、product/Xcode/Packages 与 hardware matrix
    零变化。本 D0 PR 只修改当前 `tasks.md` 的 TASK-BRC-002 status/completion
    record。
  - **Deterministic checks:closed。**audit base
    `182757cdc9ca191f2ce0a2d61dfce78440c74cd9` 上，readiness/decision/done
    ancestry、exact blobs、receipt/artifact hashes、final exact-head jobs 与唯一
    open PR #523 的零路径重叠均复核；下载的 final exact-head builder A output
    通过 repo-owned `verify-committed`；repo-owned build/mutation tests = 18/18
    PASS，`scripts/check-sdd.sh` = 0 error / 0 warning / 111
    acceptance IDs，`scripts/test_check_pr_paths.py` = 24/24 PASS；
    `git diff --check`、exact changed-path 与 secret/privacy scan 均 PASS。
  - **Successor remains gated。**本 done merge 只满足 `TASK-BRC-003` 的 dependency；
    TASK-BRC-003 继续 `blocked`，必须另开 D1 readiness pin 本 done merge、exact
    unsigned artifact/registry/SBOM、bundle identity/location、entitlements、
    signing order、Developer ID/notary environment 与 negative fixtures。不得在
    本 PR copy/package/sign/notarize/launch component 或启动 003。
- Readiness review:
  - **r3 fresh-readiness trigger:closed for review。**r2 readiness #543 exact head
    `42c65feea6528034d043bdbf14d92060b2144a71` 经 `lvye` 于
    `2026-07-25T10:56:00Z` APPROVED，并以
    `b56505aa2180ad8792302dba2566e20a0dd4db47` 于
    `2026-07-25T10:56:07Z` 合入 protected `main`。#542 纳入该 merge 后的
    exact head `19ec9a08564962381974bf455b696e9327009ffe` 在
    [run 30155496750](https://github.com/ArkDeck/ArkDeck/actions/runs/30155496750)
    以两个独立 hosted builders 重跑；17 项 unit/mutation tests PASS，两个
    builders 都通过 r2 exact image、OS、architecture、Xcode、SDK、Clang、
    Make、Bash、Python 与 SDK iconv facts，随后同时在
    `gpg binary drift` 停止。compare 未运行，artifact/signature import/build/
    link/launch/device effects 均为 0。该结果证明 r2 hosted profile 可得，也证明
    r2 把本地 audit host 上的 installed binary SHA 当成 hosted image pin 不成立；
    Homebrew bottle 可在 pour/link 时受 installed dependency paths 影响，formula/
    version 相同不保证跨 image 的 installed executable bytes 相同。r3 只修订
    fetch-stage signature verifier 的 provenance/observation gate，不放宽 source、
    detached-signature/fingerprint、build graph、artifact 或 product/effect gate。
  - **r2 fresh-readiness trigger:closed。**r1 readiness #541 exact head
    `41bc8490981697805876e258f7b2666c2d704827` 经 `lvye` APPROVED，并以
    `0fe0db4e74a3fd642b6d60d6cbda3d12ff96a105` 于
    `2026-07-25T10:07:28Z` 合入 protected `main`。#542 first implementation
    exact head `c308a999bdb4cdf327dc17436217f307ab49a896` 的 GitHub workflow
    [run 30154865194](https://github.com/ArkDeck/ArkDeck/actions/runs/30154865194)
    于 `2026-07-25T10:40Z` 在两个独立 builders 均报告
    `toolchain fact drift for osBuild`；unit job 通过，compare 因 builders
    fail closed 而未运行。runner 日志独立记录实际环境为
    `macos-26-arm64` image `20260720.0258.1`、macOS 26.4 (`25E246`)、
    provisioner `20260707.563` /
    `02667638d2b423fbc733a8e32a88b44996a3ba6e`，与 r1 仅按 audit host
    固定的 macOS 26.5.2 (`25F84`) 不同。两个 builder 都在 artifact/link/launch
    前停止且未 upload output；该 run 是真实 fail-closed observation，不计作
    `BRC-REPRO-001` PASS。r2 只修订 builder provenance、materialization 与
    final evidence gate；source、license、recipe semantics、output graph、
    product/effect 与 allowed paths 不变。
  - **Approval/dependency gate:satisfied。**TASK-BRC-001 decision #538 exact head
    `44970db58cfe39c241e3b3961c52e976b79fff68` 经 `lvye` APPROVED，并以
    `4a461ba40f532500e635509455acae95376757ca` 合入；D0 done #540 的最终
    exact head（含与最新 main 的无冲突合并）
    `d53ee0522f6474c744bc42644381fddc2523e6b5` 经 `lvye` 于
    `2026-07-25T09:07:24Z` APPROVED，并以
    `8dfde471bb876b0cd6630ba33859df270d49140e` 于
    `2026-07-25T09:10:41Z` 合入 protected `main`。两条 merge 均为本
    readiness audit base 的 ancestor；#540 只改当前 `tasks.md`，全部 exact-head
    checks 成功。
    r1 readiness #541 exact head/merge 如 fresh-readiness trigger 所列；该
    merge 仅修改当前 `tasks.md`，全部 exact-head checks 成功。
    r2 readiness #543 exact head/merge 如 r3 fresh-readiness trigger 所列；该
    merge 同样仅修改当前 `tasks.md`，全部 exact-head checks 成功。
  - **Audit base/input pins:closed。**r3 readiness audit base =
    `b56505aa2180ad8792302dba2566e20a0dd4db47`。implementation/evidence 恢复时
    必须基于本 readiness merged OID，确认 #538/#540 merge 仍为 ancestor，并逐项
    重核所有非自载体 pin；`tasks.md` 改核 readiness merge 中 reviewed 内容。无重叠
    PR 推进 main 不单独使 readiness 失效，但任一 pinned blob/source/tool/action、
    planned-path absence 或 ownership 漂移都必须回到 `blocked` 并 fresh
    readiness：

    ```yaml pins
    - artifact: TASK-BRC-002 r3 readiness audit base
      commit: b56505aa2180ad8792302dba2566e20a0dd4db47
    - artifact: TASK-BRC-002 r2 readiness merge
      commit: b56505aa2180ad8792302dba2566e20a0dd4db47
    - artifact: TASK-BRC-002 r1 readiness merge
      commit: 0fe0db4e74a3fd642b6d60d6cbda3d12ff96a105
    - artifact: TASK-BRC-001 accepted decision merge
      commit: 4a461ba40f532500e635509455acae95376757ca
    - artifact: TASK-BRC-001 done merge
      commit: 8dfde471bb876b0cd6630ba33859df270d49140e
    - path: docs/release/rockchip-component-distribution.md
      blob: 60dd039582b216d0b2fb21336fe4ee0abc9b0f7c
    - path: openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/runs/TASK-BRC-001/run.md
      blob: bab53f9da272d0dbeabdf43cbe90bfc20d16422b
    - path: openspec/changes/chg-2026-036-macos-bundled-rockchip-component/proposal.md
      blob: 7c9cf2815927ac1d8dfda2a5eac8788a1d10621b
    - path: openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md
      blob: c343320d00de2a22d6993325000997e7f5f7c1e1
    - path: openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md
      blob: 30693d27aeeb73b1babe6129d9a30c7a62d7000c
    - path: openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md
      blob: 86f82516a2b8bd1de91dffb282499d68ebdba3cf
    - path: openspec/changes/chg-2026-036-macos-bundled-rockchip-component/acceptance-cases.yaml
      blob: cd179bf8627ade54a77e205962e98200ac8374c9
    - path: openspec/changes/chg-2026-036-macos-bundled-rockchip-component/spec-impact.md
      blob: 32027c2c667185ccbac4914725481d905890e813
    - path: openspec/specs/flashing/spec.md
      blob: c914d587bf4893a3f4a9f776a28c74e7ef002c8e
    - path: openspec/specs/workflow-journal-recovery/spec.md
      blob: f97c64785533f832d6798a63e8c7c96080bb7b69
    - path: openspec/planning/agent-failure-patterns.md
      blob: ed539ff8436bccda1d8bb8a3b85a0f6e494fea81
    - path: .github/workflows/swift-ci.yml
      blob: 01f40a032061bdbc9e30e12ab628bf1ee896c8fb
    ```

    `vendor/rockchip/`、`scripts/rockchip_component/`、
    `.github/workflows/rockchip-component.yml`、
    `openspec/integrations/rockchip/bundled-component/` 与
    `evidence/runs/TASK-BRC-002/` 在 audit base 均不存在；本 readiness PR 不创建或
    占用它们。
  - **Source/dependency gate:closed。**implementation 只接受
    `rkdeveloptool@304f073752fd25c854e1bcf05d8e7f925b1f4e14` 的 codeload
    archive（59,310 bytes；SHA-256
    `389ba41af6986c16f1eeebdc1febcb0bf4b8acb7abd694d3d652e78504215843`）
    与 libusb 1.0.30 official archive（656,112 bytes；SHA-256
    `fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf`）、
    detached signature（833 bytes；SHA-256
    `7e8916e689a399b98df1087cfc48eab33a6bfd8027291c5af00c3fbba90a2cec`）
    和 KEYS（7,048 bytes；SHA-256
    `52b20b8f44c0912fdbd0c7f53c14629b9b72834118dd52ecff3fec671ba50ff3`）。
    signature 必须验证为 primary
    `C68187379B23DE9EFC46651E2C80FF56C6830A0E` / signing subkey
    `9C7EA94939C69C4FBC3DBFA8AA0639079EFB61B9`；hash/signature 任一失败即
    FAIL。两个 builder 各自只向 accepted record 的四个 URL 发起 fetch，验证后进入
    deny-network build；不得 clone、resolve branch/tag、使用 mirror/Homebrew
    bottle/cache 或第三个 dependency。
  - **Archive/extraction gate:binary。**repo-owned verifier 必须在解包前校验
    URL/final URL、size、SHA-256 与 libusb signature；解包只接受单一 top-level
    directory 和 regular file/directory，拒绝 absolute/`..`、duplicate normalized
    path、symlink/hardlink、device/FIFO/socket、特权 mode/owner 与第二 root。
    negative fixtures 必须逐类变异并证明零解包/零编译；archive bytes 只落独立
    temporary input roots，不写 repo、用户目录或 build cache。
  - **Recipe/toolchain gate:closed。**recipe identity 固定为
    `rockchip-component-build@1.0.0`：target
    `arm64-apple-macos14.0`、minimum macOS `14.0.0`、rkdeveloptool `1.32`、
    upstream modifications `none`；libusb 只以
    `--disable-shared --enable-static` 构建并静态链接；libiconv 只允许 SDK
    `/usr/lib/libiconv.2.dylib`。rkdeveloptool 只编译 accepted record 列出的八个
    `.cpp`，使用 repo-owned generated `config.h` 与 absolute argument-array
    process calls；禁止 upstream CMake、shell command string、PATH/pkg-config、
    ambient env/header/library、download-in-build、source patch 与 bundled dylib。
    compiler/link source list、全部 argv、generated file bytes 与 dependency
    allowlist 必须写入 registry/receipt；若实现需要改变这些约束，返回 001 fresh D1，
    不在 002 内选择替代。
  - **Builder availability gate:satisfied with exact hosted profile。**最终
    `BRC-REPRO-001` builder A/B 固定为两个独立 GitHub-hosted
    `macos-26`/arm64 jobs；它们必须各自 assert image
    `macos-26-arm64` version `20260720.0258.1`、macOS 26.4 (`25E246`)、
    Xcode 26.6 (`17F113`)、SDK 26.5 (`25F70`)、Apple clang 21.0.0
    (`clang-2100.1.1.101`)、GNU Make 3.81、Apple `/bin/bash` 3.2.57(1) 与
    `/usr/bin/python3` 3.9.6。GitHub image release/manifest 与 first-run logs
    共同证明当前 hosted profile 可得；workflow 必须记录并校验实际 image/OS
    facts，`macos-26` alias 漂移不构成隐式升级。selected Xcode 的 SDK
    `iconv.h` SHA-256 =
    `3fcec709f204ac60c7941488b9e49d8536150d356beff1f8cf8926cdfef7456d`，
    `libiconv.2.tbd` SHA-256 =
    `b257056db07bac43cd4d2f6fd806605ad3462fa0bb99918dc43c64176a018cea`。
    implementation 必须 assert 全部 exact facts、只从 selected
    `DEVELOPER_DIR`/OS absolute paths resolve tools，并在 drift 时停止。source
    signature verifier 是 fetch-stage analyst tooling，与 build environment/linked
    graph 分离。hosted verifier provenance 固定为 exact
    `macos-26-arm64@20260720.0258.1`、Homebrew `gnupg` 2.5.21
    `arm64_tahoe` bottle SHA-256
    `77a293d5ac76a99d7ca1fca4d57860bd76bb25b3c334b2504fc9b7fc145f1502`、
    formula commit `4d32c765e16bde9fffd6c0194a0317ac1ea16c07`、absolute links
    `/opt/homebrew/bin/{gpg,gpgv}` 与 resolved paths
    `/opt/homebrew/Cellar/gnupg/2.5.21/bin/{gpg,gpgv}`。implementation 必须
    assert image/path/realpath/version，计算并在各自 receipt/registry 记录实际
    `gpg`/`gpgv` SHA-256；A/B observed hashes 必须相同，不同即 FAIL。installed
    binary SHA 是由 exact image 产生的可复核 observation，不再错误复用本地 host
    SHA 作为 hosted precondition；不得下载/重装/upgrade/relocate Homebrew
    verifier，也不得让任何 Homebrew header/library/cache 进入 deny-network build。
    exact image、formula/version、path/realpath 或 A/B observed hash 漂移须 fresh
    readiness。verifier 只在隔离 keyring 上导入 exact KEYS，且 GOODSIG/VALIDSIG
    必须同时精确匹配 accepted primary/signing fingerprints；任一失败仍为 binary
    FAIL。本地 audit host macOS 26.5.2 (`25F84`) 只可用于
    repo-owned unit/mutation tests 与 non-final exploratory build；其 output/
    receipt 不得作为最终 registry 或 `BRC-REPRO-001` builder evidence。
  - **Two-clean-builder/reproducibility gate:binary。**builder A/B 必须是两个独立
    fresh roots（各自 empty `HOME`/`TMPDIR`/cache/output），环境只含
    `LC_ALL=C`、`LANG=C`、`TZ=UTC`、`ZERO_AR_DATE=1`、
    `SOURCE_DATE_EPOCH=1779028641`、`umask 022` 与显式 tool inputs；fetch 完成后
    build 在 `/usr/bin/sandbox-exec` deny-network profile 内运行。两者必须产生
    byte-identical unsigned Mach-O、notice、source manifest、SPDX JSON 与
    registry；normalization/strip-after-compare、复制一方 output 或 shared
    build/cache root 均禁止。两者就是最终 GitHub builders，不再把不同 OS 的本地
    output 计入最终 comparison。materialization 分两阶段且不得跳步：
    (1) 首个 r3 implementation
    head 在两个 hosted jobs 各自完整构建并先完成 A/B byte comparison；
    (2) 仅将 comparison 已接受的 builder A metadata/receipts 从 transient
    artifact 复制到声明的 repo paths，unsigned Mach-O 仍不入库；(3) 新 exact
    head 必须重跑两个 fresh hosted jobs，A/B comparison 与 committed
    registry/SBOM/notice/source-manifest/recipe verification 全部 PASS，只有该
    final run 可关闭 `BRC-REPRO-001`。任一阶段不得用本地 output 填充远端 receipt。
    workflow action pins 固定为
    `actions/checkout@11d5960a326750d5838078e36cf38b85af677262`、
    `actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02`、
    `actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093`，
    禁用 dependency/artifact cache。
  - **Artifact/registry/SBOM gate:binary。**versioned target 固定为
    `openspec/integrations/rockchip/bundled-component/1.0.0/`，包含
    `registry.yaml`、`recipe.json`、`sbom.spdx.json`、
    `THIRD-PARTY-NOTICES.txt` 与 `source-distribution-manifest.json`。registry
    必须 machine-pin sources/signature/toolchain/argv/generated files/output、
    `otool -L`/load commands/symbol inspection、minimum OS/arch 和 accepted direct
    dependency allowlist；非 system dylib 数为 0，libusb symbols 来自 static
    archive。SPDX 必须是 deterministic 2.3 JSON，含 file-level licenses、
    `LicenseRef-Rockchip-Property-permissive` extracted text、source/signature/
    recipe/output refs、`GENERATED_FROM/BUILD_TOOL_OF/STATIC_LINK/DEPENDS_ON/
    DESCRIBES` 与 system `provided` relationships。notice/source manifest 必须由
    pins 生成并在两 builders byte-identical；缺字段、graph disagreement、absolute
    path/credential/cache/device data 都是 FAIL。
  - **Implementation surface gate:closed。**implementation/evidence PR 的 changed
    paths 只允许新增 `.github/workflows/rockchip-component.yml`、
    `scripts/rockchip_component/{README.md,build.py,test_build.py}`、
    上述 `bundled-component/1.0.0/` 五个文件，以及
    `evidence/runs/TASK-BRC-002/{run.md,builder-a.json,builder-b.json,reproducibility.json}`。
    不使用 `vendor/rockchip/`，不提交 source archive、unsigned Mach-O、dylib、
    build/cache/root、GitHub artifact 或 credential。accepted distribution record、
    proposal/design/tasks/verification/acceptance/spec-impact、Core/spec/contracts、
    CHG-2026-026、ArkDeckApp/Xcode/Packages 全部只读；发现需要修改即 blocked/fresh
    readiness。implementation/evidence merge 后另开 D0 status-only PR。
  - **Verification/failure gate:closed。**tests 必须覆盖 source/size/hash/signature/
    extraction、toolchain/SDK/architecture/minimum OS、env/PATH/Homebrew/network/
    cache、source list/generated config/argv、extra dylib/load command/symbol、
    registry/SBOM/license/notice/manifest/output drift；每类至少一个 mutation 反例，
    避免 `AF-010` 自证。run 分别映射 `BRC-REPRO-001`、
    `AC-FLASH-013-01` 与 `AC-JOB-005-01`，记录两 builder receipts、workflow run、
    exact commands、negative verdict、zero-effect counters 与 residual risks。
    `scripts/check-sdd.sh`、`scripts/test_check_pr_paths.py`、repo-owned build tests、
    `git diff --check`、exact changed-path/forbidden-path 与 secret/privacy scan
    必须全绿；binary 不执行，故不声称 runtime/package/Sandbox/hardware AC。
  - **Effect/privacy/concurrency gate:satisfied。**本任务仅有 allowlisted source
    fetch、host verifier/compiler/linker/inspection 与临时文件 effect；不进入 App
    bundle、不 sign/notarize/install/launch component，不访问 HDC/USB/device/
    bookmark/image/key/output，不产生 product authority、E1/E2/destructive、
    privilege/entitlement/system-rule/group/ACL effect。`2026-07-25T11:04:10Z`
    r3 勘察时 open PR #523
    exact head `2ff6c42ee02d0f5010d55fac7d2f00a5d8992354` 仅修改
    CHG-2026-034 七个 paths，与本 readiness/implementation surface 零重叠；
    #542 exact head `19ec9a08564962381974bf455b696e9327009ffe` 是本任务
    implementation attempt，预期占用 implementation/evidence paths，已纳入 r2
    merge 并因 r3 fresh-readiness trigger 继续暂停。r3 合入后 #542 必须先将 r3
    merge 纳入 ancestry 并按本 gate 重做，不能把任一失败 run 记为 PASS。恢复前
    必须再次完整查询 open-PR
    files/heads、planned paths 与 secrets scan；查询不完整、非 #542 overlap 或
    新 owner 抢占即 blocked。
- Platform:macos
- Requirements：`REQ-FLASH-004`、`REQ-FLASH-013`、`REQ-JOB-005`
- Acceptance：`BRC-REPRO-001`、`AC-FLASH-013-01`、`AC-JOB-005-01`
- Depends on：`TASK-BRC-001` done；独立 D1 readiness
- Readiness input pins：见上方 r3 D1 readiness；implementation/evidence 开工时从
  readiness merge 重新核验
- Applicable failure patterns：`AF-001`、`AF-002`、`AF-003`、`AF-007`、
  `AF-009`、`AF-010`、`AF-017`
- Production reachability：not applicable；host-side unsigned component build only，
  不进入 App bundle、不 launch、不产生 process/device authority
- Trusted fact sources：001 accepted record、pinned source/dependency archives、
  reviewed build recipe、two isolated clean-builder receipts 与 cryptographic
  digests；host PATH/Homebrew/cache 自报不能成为输入
- Allowed paths:
  - `vendor/rockchip/**`
  - `scripts/rockchip_component/**`
  - `.github/workflows/rockchip-component.yml`
  - `openspec/integrations/rockchip/bundled-component/**`
  - `docs/release/rockchip-component-distribution.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/**`
  - `ArkDeckApp/**`
  - `ArkDeck.xcodeproj/**`
  - `Packages/**`
- Risk:medium（构建可执行供应链，但未进入 product/runtime）
- Hardware required:no

### Deliverables

- source-pinned、dependency-locked、无 ambient Homebrew/PATH input 的 build recipe；
- versioned bundled-component registry、license/notice/corresponding-source manifest、
  reviewable SBOM 与 vulnerability ownership metadata；
- 两个独立 clean build 的 unsigned artifact reproducibility/normalized-diff receipt，
  覆盖声明的 architecture 与 minimum macOS；
- negative tests：source/dependency/toolchain/hash/architecture drift、network/cache/
  ambient library 注入均 fail closed。

### Verification

- `BRC-REPRO-001`：同 pins 的两个 clean builders 产生相同 unsigned artifact
  identity（或 readiness 明确批准的可复查 normalization），registry/SBOM/manifest
  与 artifact dependency graph 一致；
- `AC-JOB-005-01`：build/runtime descriptor 没有 PATH/shell/caller environment；
- 不 launch artifact，不访问 USB/设备；SDD、build tests、diff、secret/privacy scan
  全绿。

### Notes / handoff

- task 完成不表示 binary 可签名、可打包或可分发；`TASK-BRC-003` 必须重新 pin exact
  artifact/registry/blob。

## TASK-BRC-002R — artifact dispatch 与 30 天保留（handoff remediation）

- Status:done（2026-07-27 D0 completion；仅在维护者 review/merge 本独立
  `ready→done` PR 后生效。实现 = #616 merge
  `9ff769d`（`workflow_dispatch:` 与两处 `retention-days: 30`，构建
  逻辑/输入/action pins/permissions/concurrency/matrix 零字节变更）；
  evidence = #617 merge `01e6f9a6605f4a3a9463dcab2bf5731bd012ef48`
  （push 路径的保留期与 identity 证明）+ 本 PR 追记的 dispatch proof。
  **`BRC-HANDOFF-002` = PASS**：维护者 `02:53:23Z` 亲手 dispatch 的 run
  `30233237693`（`event=workflow_dispatch`、head `01e6f9a6`、success、
  四 job 全绿）三 artifact 均 expires `2026-08-26`（+30 天），且
  `PASS: verify-committed` 以逐字节比对生成 `registry.yaml`（携 component
  `sha256: 3caee213…56a`）证明 identity 复现。契约措辞更正（「三处
  retention-days」实为 2 处声明覆盖 3 个 artifact）已如实入 evidence。
  flip base = 本 PR base；recheck：#613/#616/#617 三 merge 均为 ancestors、
  `check-sdd` 0/0/111、本 flip 仅动 tasks.md 与 evidence run。
  **本 done 不使 TASK-BRC-003 ready**：其 D2 gate 余两项（可独立列举的
  Developer ID Application certificate、可 preflight 证明的 notary
  credential）仍待维护者在隔离 release environment 完成，之后 fresh D1。）
- Historical Status:ready（r1 implementation readiness = #613 merge
  `90085a9fc1341e13a5b59ba1afb676b10907d976`；其一次性授权已由 #616/#617
  与本 flip 全额消耗；r1 Readiness 块原文保留为历史。）
- Historical Status:blocked（前置 = 本 r2 carrier 同时登记任务与授权；
  proposal r2 增补记录维护者 2026-07-27 的 handoff 选择。）
- Readiness（r1；audit base = protected `main` `ecd5320b35308ddd44f67fb6a825a9c5f9e3fc1b`）：
  - **Approval boundary:pending human merge。**本 carrier 同时修改
    proposal（revision 1→2 + dated 增补）、acceptance（change_revision
    1→2 + `BRC-HANDOFF-002`）、verification（@r2 + matrix 行 + 两条
    closure 计数）与本 tasks.md，三方同步一体生效；标题为 governance
    形态（不携 task token），因为改动跨越本任务的 allowed paths。
  - **Dependency gate:closed。**TASK-BRC-002 done merge
    `e9848ba274123bea46b98e39cbf989bd93dfc225` 为 audit base 祖先；
    本任务只改其交付的 workflow 的触发与保留策略，不改其构建契约。
  - **Source pin:closed。**`.github/workflows/rockchip-component.yml`
    blob `8ccb3e7d9033b89c2dbe746995f5c496427e9d96`；实现 base 不等即停并重钉。
  - **Reproducibility premise:measured（2026-07-27）。**BRC-002 最终
    run `30156181935` 的 head `4d02b9945ecfe2db1e8af7adc98251a1b0ef9589`
    与本 audit base 之间，`scripts/rockchip_component/**`、
    `openspec/integrations/rockchip/bundled-component/**` 与本 workflow
    的 `git diff` 为**空**（逐 blob 复核：workflow `8ccb3e7d…`、
    `build.py` `33fe4379…`、`test_build.py` `7a622628…`、`recipe.json`
    `fa4289b7…` 四项 SAME）。故在 main 上 dispatch 预期复现已接受的
    component identity；**该预期是 evidence 的待证门，不是假设**——
    dispatched run 的 SHA-256 与 `3caee2136551b4b849daf7e9a906813354f354
    f8adb61e5f092de49ec7a2e56a` 不等即 FAIL、停、重 readiness。
  - **Implementation contract:binary。**
    ① `on:` 增加 `workflow_dispatch:`（无 inputs），`push:` 段逐字不变；
    ② 三处 `retention-days: 1` → `30`（builder matrix upload、
    reproducibility upload；`compare` job 的 download 不变）；
    ③ 其余 workflow 内容零字节变更：jobs/steps/action pins/concurrency/
    permissions/timeout/matrix/`DEVELOPER_DIR`/命令行全部逐字保持，
    实现 diff 必须恰为上述两类行。
    ④ 本 carrier 合入即触发一次 push 构建（本 PR 改动命中该 workflow 的
    触发路径，且分支在 `agent/**` 内）——这是既有行为，不构成新 effect：
    unsigned build，零签名/公证/上传/发布/设备。
  - **Evidence contract:binary。**evidence PR 记录：(a) 一次
    `workflow_dispatch` 触发的 run id 与结论；(b) 其三个 artifact 的
    `expires_at`（须约为创建 +30 天）与 size；(c) builder A 产出的
    component SHA-256 == `3caee213…56a`（**identity 复现的正面证明**）；
    (d) `compare` job 的 byte-identical 结论；(e) workflow diff 恰为两类
    行。credential/token/绝对用户路径不入 evidence。
  - **Effect/privacy/concurrency gate:satisfied。**零签名、零公证、零
    上传、零发布、零 install/launch、零设备/HDC/USB、零凭据动作；起草时
    remote `agent/*brc*` 分支 = 0。
  - **Grade 注记**：`Decision-Grade` 行由维护者亲笔；本契约二值可判定，
    符合 D0 三条件（结论由 main 已合入状态 + 确定性检查决定，diff 零新
    scope/风险/授权，不改权威文件语义）。
- Platform:macos（CI 配置面；零产品/设备声明）
- Requirements/AC:change-local `BRC-HANDOFF-002`
- Depends on:`TASK-BRC-002` done
- In scope:`workflow_dispatch` 触发；三处 `retention-days` 1→30；
  evidence（dispatched run 的 identity 复现与 expiry 证明）。
- Out of scope:构建逻辑/输入/registry/recipe/SBOM/notices、其他
  workflow、凭据/environment/Developer ID/notary、BRC-003 任何 gate、
  产品 source/tests。
- Allowed paths:
  - `.github/workflows/rockchip-component.yml`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`
- Forbidden paths:
  - `.github/workflows/agent-pr.yml`
  - `.github/workflows/sdd-guard.yml`
  - `.github/workflows/swift-ci.yml`
  - `scripts/**`
  - `openspec/integrations/**`
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/changes/archive/**`
  - `ArkDeckApp/**`
  - `ArkDeck.xcodeproj/**`
  - `Packages/**`
- Risk:low（只放宽保留期与增加手动触发；构建逻辑与产出 identity 由
  dispatched run 的 SHA-256 复现门守住；回退 = revert）。
- Hardware required:no。

### Deliverables

- workflow 的 `workflow_dispatch` 触发与三处 30 天保留；
- 一次 dispatched run 的 sanitized evidence：run id/结论、三 artifact 的
  `expires_at`/size、component SHA-256 复现证明、`compare` 结论、
  workflow diff 的两类行清点。

### Verification

- `BRC-HANDOFF-002`：dispatched run 复现已接受的 component identity；
  artifact `expires_at` 约为创建 +30 天；workflow diff 恰为 dispatch 触发
  与三处 retention 两类行，构建输入/逻辑零变化。

### Notes / handoff

- 本任务 done **不使 TASK-BRC-003 ready**：其 D2 gate 的另两项
  （可独立列举的 Developer ID Application certificate、可 preflight 证明
  的 notary credential）仍待维护者在隔离 release environment 完成；
  fresh D1 才能把三项一并钉死。
- 本任务把「签名窗口必须在 artifact 过期前一次做完」这一时间耦合解除，
  使 BRC-003 窗口可独立排期。

## TASK-BRC-003 — 闭合 nested component 打包、签名与公证

- Status:ready（r2 fresh D1 readiness；仅在维护者对本 readiness/evidence PR 的
  exact head review/merge 后生效。`TASK-BRC-002R` 已闭合按需 materialization
  handoff，维护者已在隔离 release environment 亲手完成 Developer ID/notary D2
  configuration；本 PR 只接受其 sanitized、非秘密 preflight evidence 并重新 pin
  current inputs/工具/失败门，不执行 package/sign/notarize/staple/install/upload，
  不携 credential/private key/profile path/App/DMG/binary，也不开始
  implementation/evidence。）
- Historical Status:blocked（r1 D1 blocked-readiness；本记录只固定 package/sign/notary
  contract 并如实记录 release environment 与 unsigned artifact handoff 缺口。合入
  不构成 `ready`，不得开始 implementation/evidence。维护者完成下述 D2
  configuration 后，必须另开 fresh D1 readiness 并经 review/merge，才可开工。）
- Fresh readiness review（r2；audit base =
  `333eec928cbbd7f273abffeebb3970f15ed33554`）：
  - **Carrier/approval boundary:closed for review。**protected `main` 的 GitHub API
    OID 与本地 `origin/main`/branch base 均为上述完整 OID；本 PR 只允许修改当前
    `tasks.md` 与
    `evidence/runs/TASK-BRC-003/readiness-r2.md`。`ready` 只在维护者 review/merge
    后生效；D1 后零投机实现保持成立。
  - **Approval/dependency ancestry:closed。**TASK-BRC-002 implementation
    `182757cdc9ca191f2ce0a2d61dfce78440c74cd9`、done
    `e9848ba274123bea46b98e39cbf989bd93dfc225`，以及 TASK-BRC-002R
    readiness `90085a9fc1341e13a5b59ba1afb676b10907d976`、implementation
    `9ff769d79df261f72c2b4dbcef5e48d68d8e520e`、evidence
    `01e6f9a6605f4a3a9463dcab2bf5731bd012ef48`、done
    `5a40e8968586232468a8691039d674c9e83d7526` 全部是 audit base 祖先。
  - **Repository/input pins:closed。**r1 YAML block 中 registry/recipe/SBOM/
    notices/source-manifest、BRC-002 run、Xcode project/scheme、App entitlement 与
    两份 release doc 的 11 个 blob 在 audit base 上全部逐项不变；current
    `tasks.md` base blob =
    `de23d56688e713d90a2b12706e8d44651cffa164`，current component workflow
    blob = `6242d0b4f3a1b8b15020803073b017c6a6911a61`。任一实现 base/pin 不等即停止并
    fresh D1。
  - **Unsigned artifact/materialization gate:closed for this window。**维护者
    dispatch run `30233237693`（event `workflow_dispatch`、head
    `01e6f9a6605f4a3a9463dcab2bf5731bd012ef48`、success）的 builder-A artifact
    `8640763234`，API archive digest =
    `sha256:3dc014b6e81a68942d9415a1bdb73faabbbb2472297d1ae14d7648a547628e67`，
    `expired=false`，expires `2026-08-26T02:53:55Z`。r2 audit 从 GitHub
    authenticated download 到 fresh `/private/tmp` 后独立检查并清理：component
    247,488 bytes、SHA-256
    `3caee2136551b4b849daf7e9a906813354f354f8adb61e5f092de49ec7a2e56a`、
    regular arm64 Mach-O、minimum macOS 14.0、unsigned、零非 system dylib；
    registry/SBOM/notices/source-manifest 与仓内副本逐字节一致。implementation
    只能 materialize 此 exact artifact 到 fresh staging、先复验全部字段再签名；
    artifact 过期/不可下载/API digest 或任一 extracted field 不等即零 archive/
    sign/notary 并 fresh D1。artifact、staging 与绝对路径不入仓/evidence。
  - **D2 release environment gate:closed by maintainer action。**opaque environment
    ref = `maintainer-local-release-env-2026-07-29`；macOS 26.6 (`25G72`) arm64、
    Xcode 26.6 (`17F113`)、`notarytool 1.1.2 (41)`。独立只读检查列出恰一条有效
    `Developer ID Application` identity：SHA-1
    `38E3B7650DF0CE1DEC0CC8C403614AA0C38B0B4C`、Team ID `8AQTYW5FKR`、
    validity `2026-07-29T01:38:03Z`–`2027-02-01T22:12:15Z`、issuer Apple
    Developer ID Certification Authority，valid-chain verdict PASS；opaque
    Keychain notary profile 的 sanitized `notarytool history` preflight =
    authentication PASS、submission count 0。零 credential value、Apple account、
    private key、password、token、keychain/profile path/name 或 raw history 入仓。
    每次 sign/notary 前必须重跑 identity/expiry/chain/auth preflight；任一不等即
    fail closed 并 fresh D1。
  - **Apple primary contract/tool gate:closed。**`2026-07-29` 重读 r1 列出的四份
    Apple primary docs；current contract 仍要求 standard nested-code location、
    inside-out Developer ID signing、secure timestamp、Hardened Runtime、
    outermost DMG `notarytool` submission/log/ticket/staple，且禁止用签名
    `--deep` 替代逐项签名。App Sandbox/Hardened Runtime entitlement 属现行
    unrestricted entitlement，本 exact entitlement 集不引入 distribution
    provisioning profile。system `xcodebuild`/`codesign`/`security`/`hdiutil`/
    `spctl`/`shasum`/`file`/`otool` 与 Xcode `notarytool`/`stapler`/`vtool`/`lipo`
    均可得；实现不得引入 PATH/Homebrew/动态下载 fallback。
  - **Scope/privacy/concurrency gate:closed。**readiness capture 时 GitHub open PR
    集合为空；本审计只做 source/GitHub metadata/Apple docs/credential
    authentication 与临时 unsigned artifact inspection。component/App launch、
    archive/package/sign/notary submission/staple/install/upload/update、
    HDC/USB/device/E1/E2/deviceMutation/destructive/privilege/system mutation
    counters 全为 0；临时 materialization 已删除。完整 sanitized record 与命令
    结论见 `evidence/runs/TASK-BRC-003/readiness-r2.md`。
- Historical readiness review（r1 blocked）:
  - **Approval/dependency gate:satisfied。**TASK-BRC-002 implementation/evidence
    #542 exact head `4d02b9945ecfe2db1e8af7adc98251a1b0ef9589` 经 `lvye` 于
    `2026-07-25T11:58:55Z` APPROVED，并以
    `182757cdc9ca191f2ce0a2d61dfce78440c74cd9` 合入 protected `main`；
    D0 #545 exact head `2ecf6d896e581a6ee1e9eed10b9048487e952638` 经 `lvye` 于
    `2026-07-25T12:10:27Z` APPROVED，并以
    `e9848ba274123bea46b98e39cbf989bd93dfc225` 于
    `2026-07-25T12:10:35Z` 合入。两条 merge 及 TASK-BRC-001
    decision/done ancestry 都是本 audit base 的祖先；dependency done 只允许本次
    D1 勘察，不替代 package、credential 或 notary 判断。
  - **Audit base/input pins:closed for review。**audit base =
    `e9848ba274123bea46b98e39cbf989bd93dfc225`。fresh D1 必须从本
    blocked-readiness merge 重新核验全部非自载体 pin；任一 artifact、registry、
    App/entitlement、release policy 或 Apple tool contract 漂移都保持
    `blocked`：

    ```yaml pins
    - artifact: TASK-BRC-002 implementation/evidence merge
      commit: 182757cdc9ca191f2ce0a2d61dfce78440c74cd9
    - artifact: TASK-BRC-002 done merge / TASK-BRC-003 audit base
      commit: e9848ba274123bea46b98e39cbf989bd93dfc225
    - path: openspec/integrations/rockchip/bundled-component/1.0.0/registry.yaml
      blob: 505122327e877900d7fdb2b908cf6914f207b70f
    - path: openspec/integrations/rockchip/bundled-component/1.0.0/recipe.json
      blob: fa4289b73880540b0db19d24242d039053ae8916
    - path: openspec/integrations/rockchip/bundled-component/1.0.0/sbom.spdx.json
      blob: e66e3d7f22a4d2079e59edcc51c2682650362689
    - path: openspec/integrations/rockchip/bundled-component/1.0.0/THIRD-PARTY-NOTICES.txt
      blob: 6d1f7bf4624972fdb8559d203fd89163c3003c43
    - path: openspec/integrations/rockchip/bundled-component/1.0.0/source-distribution-manifest.json
      blob: bbce240466dedfc7de3ebb19d1db5fe8b0f3a865
    - path: openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/runs/TASK-BRC-002/run.md
      blob: 94108fb6f1f0a4d86b027e03ef9885c7360f9c56
    - path: ArkDeck.xcodeproj/project.pbxproj
      blob: e7943096688728a22f4b940e536a32f3b8eaaf98
    - path: ArkDeck.xcodeproj/xcshareddata/xcschemes/ArkDeck.xcscheme
      blob: 29d0fb995dd3a28ad535569a4cdc4c3964311def
    - path: ArkDeckApp/ArkDeckApp.entitlements
      blob: 6435d00f8493ce4fbca24a806ca7f320db9fbfa6
    - path: docs/release/rockchip-component-distribution.md
      blob: 60dd039582b216d0b2fb21336fe4ee0abc9b0f7c
    - path: docs/release/macos-auto-update.md
      blob: ecc8d8a02dbe37d66ca1716aeeafa1491f3a7af8
    ```

  - **Apple contract source gate:closed for review。**`2026-07-25` 只接受 Apple
    primary documentation：[Embedding a helper tool in a sandboxed
    app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)、
    [Creating distribution-signed code for the
    Mac](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)、
    [Customizing the notarization
    workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
    与 [TN2206 macOS Code Signing In
    Depth](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)。
    它们分别约束 externally-built sandbox child 的 pre-sign/Code Sign On Copy/
    Executables location、inside-out Developer ID/Hardened Runtime、outermost
    distribution notarization/log/staple，以及 nested code location/designated
    requirement inspection。fresh D1 必须重读 current Apple docs；不可用二手文章、
    旧命令片段或 `--deep` 便利签名放宽 contract。
  - **Unsigned component identity gate:closed, handoff blocked。**唯一可接受
    component 是 #542 两个 clean builders 已证明 byte-identical 的 regular
    Mach-O：name `rkdeveloptool`、247,488 bytes、SHA-256
    `3caee2136551b4b849daf7e9a906813354f354f8adb61e5f092de49ec7a2e56a`、
    `arm64`、minimum macOS `14.0`、signature absent、非 system dylib 数 0；
    registry/recipe/SBOM/notices/source-manifest 必须逐 blob/内容匹配上述 pins。
    package tool 只接受显式 input file URL，经 regular-file/no-symlink、
    size/hash/Mach-O/architecture/minimum-OS/load-command/dependency inspection
    后复制到 fresh staging root；不允许 rebuild-on-package、PATH、caller env、
    Homebrew、download、cache、alternate binary 或 normalization。
    final exact-head run `30156181935` 的 builder A artifact ID `8619054679`
    （archive digest
    `sha256:4298494e40bed1c2d09b091d1f534032623b443b84149bd3d95b3dc77466ed53`）
    当前仅是 GitHub Actions transient handoff，`expires_at =
    2026-07-26T11:25:04Z`；binary 按 002 contract 未入仓。维护者必须在 D2
    选择受控且可复查的 materialization/retention handoff，fresh D1 再固定其
    immutable provenance、retention、访问边界与 sanitized receipt。临时 artifact
    过期、无法重新 materialize exact bytes 或只剩自报 hash 时均 FAIL。
  - **Bundle topology/metadata gate:closed for review。**App target/bundle ID =
    `ArkDeck` / `com.arkdeck.desktop`；component target location =
    `ArkDeck.app/Contents/MacOS/rkdeveloptool`，code-sign identifier =
    `com.arkdeck.desktop.rkdeveloptool`。二者与 App version 一起构成单一
    atomic package，不存在独立 updater、search path、mutable component directory、
    symlink、alternate location 或 external fallback。component 只允许 `arm64` /
    minimum macOS `14.0`，Release App 同样必须只含 `arm64` 且 minimum macOS
    `14.0`。上述五份 reviewed metadata 的逐字节副本固定置于
    `ArkDeck.app/Contents/Resources/RockchipComponent/1.0.0/`；缺失、额外、
    重命名或 digest drift 均阻止 archive/release。
  - **Entitlement/signing gate:closed for review。**新增
    `ArkDeckApp/RockchipComponent.entitlements` 只能包含 boolean true 的
    `com.apple.security.app-sandbox` 与 `com.apple.security.inherit`，不得有
    `get-task-allow`、USB/file/network 或任何 Hardened Runtime exception。
    Release App 必须继续使用 blob
    `6435d00f8493ce4fbca24a806ca7f320db9fbfa6` 的现行精确六项 entitlement，
    `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`，不得增删。fresh staging
    component 在 copy 前可按 Apple externally-built helper contract 使用 exact
    identifier、exact child entitlement 与 `runtime` option 做 ad-hoc pre-sign；
    该签名只为让 Xcode ingest/re-sign，不能计入 acceptance。Xcode 必须使用名为
    `Embed Rockchip Component` 的 Copy Files/Executables phase 把 component
    固定到 `Contents/MacOS` 并启用 Code Sign On Copy；Release archive 对 child
    与 App 依次使用同一维护者批准的 `Developer ID Application` identity、
    Hardened Runtime 与 secure timestamp。签名必须 inside-out，禁止用
    `codesign --deep` 签名、preserve arbitrary metadata 或 ad-hoc/Apple
    Development identity 代替；`--deep --strict` 只可用于 final read-only
    verification。
  - **Release order/outer package gate:closed for review。**唯一顺序是：
    materialize + inspect exact unsigned input → fresh staging ad-hoc pre-sign →
    Xcode Release archive/Code Sign On Copy → independently inspect child then App
    signature/requirement/entitlements/runtime/timestamp/Team ID → create deterministic
    single DMG → sign DMG with the same Team identity → submit the outermost DMG by
    `notarytool` → require Accepted status and sanitized notary log → staple and
    validate DMG → Gatekeeper-assess DMG and the contained App → emit immutable
    package tuple/receipt。任一步 unknown/non-zero/mismatch 均删除候选 staging
    output 并停止，不覆盖既有 release；不上传 GitHub Release、不发布 feed、
    不 install/launch App 或 child。notary submission ID/log 可记录，credential、
    private key、token、keychain/profile path 与绝对用户路径不得记录。
  - **Current Xcode drift gate:binary FAIL until implementation。**audit base 的
    Release App bundle ID/minimum OS 已是 `com.arkdeck.desktop` / `14.0`，但
    `ENABLE_HARDENED_RUNTIME = NO`、manual ad-hoc identity `-`，且默认
    architectures 为 `arm64 x86_64`；project 没有 component reference/copy phase。
    host-side `CODE_SIGNING_ALLOWED=NO` exploratory Release build 成功但主 executable
    是 `x86_64 arm64` universal Mach-O，只含 App/localization files，且仅有
    linker-generated ad-hoc signature（identifier `ArkDeck`、Team ID absent、
    sealed resources absent）。这些是 implementation 必须修复及 negative tests
    必须锁住的 baseline FAIL，不是 `BRC-PACKAGE-001` evidence。
  - **Implementation surface gate:closed for review。**fresh D1 若其余门全部满足，
    implementation/evidence PR 的 changed paths 才可精确限定为
    `ArkDeck.xcodeproj/project.pbxproj`、
    `ArkDeckApp/RockchipComponent.entitlements`、
    `scripts/release/{README.md,rockchip_component_package.py,test_rockchip_component_package.py}`、
    `docs/release/rockchip-component-packaging.md`、
    `openspec/integrations/rockchip/bundled-component/1.0.0/package.json` 与
    `evidence/runs/TASK-BRC-003/{run.md,package-receipt.json,notary-log.json}`。
    binary/App/DMG/archive/source/keychain/credential 不入仓；现有 registry、recipe、
    SBOM/notices/source manifest 与 App entitlement 只读。若 Xcode input 不能由
    repo-owned absolute argument-array packaging tool 通过 fresh staging root
    注入、需要新增 workflow/schema/contract/product/runtime path 或更改上述 exact
    list，保持 blocked 并 fresh D1，不在 implementation 内扩 scope。实现 PR 状态
    仍为 `ready`；其 merge 后另开 D0 status-only PR。
  - **Package verification/failure gate:closed for review。**repo-owned tests
    必须逐类 mutation 并证明 fail before archive/notary：missing/wrong/non-regular/
    symlink component，size/hash/architecture/minimum-OS/load-command/dependency
    drift，wrong nested location/identifier，missing/extra App or child entitlement，
    ad-hoc/development/mixed-Team/expired/untrusted/missing-timestamp signature，
    Hardened Runtime disabled/exception，wrong App arch/minimum OS/version，missing/
    extra/drifted metadata，extra nested executable/dylib，unsigned/malformed DMG，
    notary rejected/invalid/unknown/missing log，staple/Gatekeeper failure，以及
    mixed App-component-source/SBOM/notices tuple。positive evidence 必须记录
    `file`/`lipo`/`vtool`/`otool`、`codesign -d`/`-r-`/
    `--display --entitlements :-`/`--verify --deep --strict`、`hdiutil verify`、
    `notarytool log`、`stapler validate`、`spctl` 与 SHA-256/size 的 sanitized
    outputs；self-reported manifest/signing fields 不能替代 independent inspection。
  - **D2 release-environment gate:BLOCKED。**`2026-07-25T12:23:09Z` 勘察 host =
    macOS 26.5.2 (`25F84`) arm64、Xcode 26.6 (`17F113`)、
    `notarytool 1.1.2 (41)`；`security find-identity -v -p codesigning` =
    `0 valid identities found`。GitHub repository 没有 environment，Actions
    secret metadata 也没有 Developer ID/notary 项（仅有两项已废止 V1
    governance secret，不能复用）；因此当前没有可证明的 Developer ID signer、
    Team ID、notary credential holder/environment 或长期 unsigned artifact
    handoff。credential/permission/environment configuration 属 D2，Agent 不得
    创建、导入、修改、轮换或自批。维护者必须在隔离 release environment 中完成：
    (1) 可由 `security` 独立列举的有效 `Developer ID Application` certificate，
    固定 certificate SHA-1、Team ID、有效期与 chain verdict；
    (2) 可由一次 sanitized、只读 notary account/profile preflight 证明有效的
    notarization credential，零 credential value/path 入 evidence；
    (3) exact artifact materialization/retention handoff 与 operator/cleanup
    boundary。完成后 fresh D1 只能引用维护者提供的非秘密 evidence/opaque
    environment reference，并重新执行 package contract/tool availability/
    concurrency/secret checks；任一项仍缺失就继续 `blocked`。
  - **Effect/privacy/concurrency gate:satisfied for blocked-readiness。**本次只做
    protected-main/GitHub metadata、Apple contract、repo/Xcode source 与 host-side
    unsigned App inspection；component/App launch、package/sign/notarize/staple/
    install/upload/update、HDC/USB/device/file-picker/bookmark、E1/E2/
    deviceMutation/destructive、credential/system/entitlement mutation counters
    全为 0。`2026-07-25T12:23:09Z` 完整查询的唯一 open PR #523 exact head
    `2ff6c42ee02d0f5010d55fac7d2f00a5d8992354` 只修改 CHG-2026-034 七个
    paths，与本 readiness/后继 surface 零重叠。本 PR 只修改当前 `tasks.md`
    TASK-BRC-003 section；合入后 lane 在 D2/fresh D1 前暂停，零投机
    implementation。
- Platform:macos
- Requirements：`REQ-FLASH-004`、`REQ-FLASH-013`、`REQ-JOB-005`、
  `REQ-UX-007`
- Acceptance：`BRC-PACKAGE-001`、`AC-FLASH-013-01`、
  `AC-JOB-005-01`、`AC-UX-007-01`
- Depends on：`TASK-BRC-002` done；`TASK-BRC-002R` done；独立 D1 readiness
- Readiness input pins：见上方 r2 fresh readiness；任一 repository/artifact/
  certificate/notary/tool pin 漂移、artifact 过期或本 readiness 未经维护者合入，
  都保持/恢复 `blocked`
- Applicable failure patterns：`AF-001`、`AF-002`、`AF-003`、`AF-007`、
  `AF-009`、`AF-010`、`AF-017`
- Production reachability：ArkDeck Xcode/archive root → fixed nested component copy →
  inside-out sign → App sign/notarize；本任务仍不从 App launch child，不产生 device
  authority/effect
- Trusted fact sources：BRC-002 accepted registry/artifact, Xcode build graph,
  codesign designated requirement/entitlement output, Gatekeeper/notary/stapler
  receipts；credential holder与artifact builder不能用自报字段替代独立 inspection
- Allowed paths:
  - `ArkDeck.xcodeproj/**`
  - `ArkDeckApp/**`
  - `scripts/release/**`
  - `scripts/rockchip_component/**`
  - `openspec/integrations/rockchip/bundled-component/**`
  - `docs/release/**`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/**`
  - `Packages/**`
- Risk:medium（改变 App release/package shape，但零 runtime/device effect）
- Hardware required:no
- Decision-Grade:D2。

### Deliverables

- fixed nested location/identifier、Code Sign On Copy/inside-out signing、minimum OS、
  architectures 与 exact child entitlements；
- Release App/DMG 的 Developer ID、Hardened Runtime、notarization、stapling 与 nested
  signature verification automation；
- negative package fixtures/tests：missing/wrong signature、location、identifier、
  arch、min OS、entitlement、registry/hash、notary/staple 全部 fail closed；
- sanitized package evidence；零 credential/private key 入仓。

### Verification

- `BRC-PACKAGE-001`：signed App/DMG inspection 对每个固定 field exact match，child
  只有 `app-sandbox=true` 与 `inherit=true`，App entitlement 仍为现行六项；
- binary/registry/SBOM/source-offer tuple 一致；任何 drift 阻止 release；
- 不 launch child、不访问 USB/设备；SDD/package tests/diff/secret scan 全绿。

### Notes / handoff

- ad-hoc/Debug evidence 不能替代 Developer ID/notary evidence；Developer ID secret
  只由批准的 release operator/environment 使用。

## TASK-BRC-004 — 迁移 product-owned composition 与 typed file leases

- Status:blocked
- Platform:macos
- Requirements：`REQ-FLASH-001`、`REQ-FLASH-004`、`REQ-FLASH-005`、
  `REQ-FLASH-008`、`REQ-FLASH-012`、`REQ-FLASH-015`、
  `REQ-JOB-002`、`REQ-JOB-003`、`REQ-JOB-005`、`REQ-JOB-006`
- Acceptance：`BRC-COMPOSITION-001`、`AC-FLASH-001-01`、
  `AC-FLASH-005-01`、`AC-FLASH-008-01`、`AC-FLASH-012-01`、
  `AC-FLASH-015-01`、`AC-JOB-002-01`、`AC-JOB-003-01`、
  `AC-JOB-005-01`、`AC-JOB-006-01`
- Depends on：`TASK-BRC-003` done；独立 D1 readiness
- Readiness input pins：未实例化；必须固定 signed package/registry identity、current
  host/facade/process/storage blobs、file-lease model、fault matrix、production
  reachability query 与 exact test commands
- Applicable failure patterns：`AF-001`、`AF-002`、`AF-003`、`AF-004`、
  `AF-006`、`AF-007`、`AF-009`、`AF-010`、`AF-012`、`AF-017`
- Production reachability：ArkDeckApp composition root →
  `RockchipFlashApplicationFacade`/`RockchipFlashExecutionHost` → typed
  plan/binding → existing authorization gate → product-owned bundled descriptor →
  process port/executor → future RockUSB effect → durable outcome；本任务保持 App UI
  execute disabled且无法取得 E2 authority
- Trusted fact sources：reviewed bundle registry + independently inspected bundle
  identity；device facts由 typed discovery/binding produced；intent/outcome由 durable
  store produced。调用方不能同时构造 executable/receipt/authority 或伪造 child result
- Allowed paths:
  - `Packages/ArkDeckKit/Package.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**`
  - `ArkDeckApp/**`
  - `ArkDeck.xcodeproj/**`
  - `openspec/integrations/rockchip/bundled-component/**`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/**`
- Risk:high（production composition/authority/effect 邻接代码；仅 contract/fake，零真实 effect）
- Hardware required:no
- Decision-Grade:D1。

### Deliverables

- product-owned bundled descriptor/identity seam 与 App composition root；
- 删除 production route 对 user-selected executable URL/hash/bookmark、raw argv/
  environment/component receipt/authority bytes 的输入；
- typed image/key/output leases、cancel/timeout/partial/crash/restart/reconcile 与
  intent/outcome wiring；
- contract/fake/source-reachability tests，证明 external/PATH/shell/fallback/
  caller-forged identity 不可达，App UI execute 仍 disabled，真实 process/USB/device/
  E1/E2 dispatch 为 0。

### Verification

- `BRC-COMPOSITION-001` 与所列 canonical AC 通过 contract/fake/fault/source audit；
- crash-after-intent/unknown-outcome 必须 `waitingForRecovery`，零 automatic replay；
- build/test/SDD/allowed-path/diff/secret scan 全绿，硬件支持仍 `not proven`。

### Notes / handoff

- fake/contract 不能证明 signed Sandbox child、文件或 USB access；这些只由
  `TASK-BRC-005` 证明。

## TASK-BRC-005 — 取得 signed Sandbox E0、file-access 与 RockUSB 只读证据

- Status:blocked
- Platform:macos
- Requirements：`REQ-FLASH-001`、`REQ-FLASH-004`、`REQ-FLASH-008`、
  `REQ-FLASH-012`、`REQ-FLASH-013`、`REQ-FLASH-015`、
  `REQ-JOB-005`、`REQ-UX-007`
- Acceptance：`BRC-SANDBOX-E0-001`、`AC-FLASH-001-01`、
  `AC-FLASH-008-01`、`AC-FLASH-012-01`、`AC-FLASH-013-01`、
  `AC-FLASH-015-01`、`AC-JOB-005-01`、`AC-UX-007-01`
- Depends on：`TASK-BRC-004` done；独立 D1 readiness 与 exact E0 device window
- Readiness input pins：未实例化；必须固定 signed App/component tuple、test
  image/key/output fixtures、DAYU200 identity/USB topology、E0 commands、operator、
  privacy transform、effect counters、timeouts、disconnect/cancel cases 与 zero-E1/E2
  boundary
- Applicable failure patterns：`AF-001`、`AF-002`、`AF-003`、`AF-004`、
  `AF-005`、`AF-006`、`AF-007`、`AF-008`、`AF-009`、`AF-010`、`AF-012`
- Production reachability：signed ArkDeckApp E0 harness → product-owned descriptor →
  exact signed child → separately bounded version/`ld`, file-lease diagnostic and
  RockUSB read-only observation；该 E0 harness 没有 E2 authority 入口，mutation
  dispatch counter 必须保持 zero
- Trusted fact sources：signed/notarized component inspection、OS Sandbox/Gatekeeper
  result、typed app-owned receipts、independent USB/device identity observation；
  child/caller self-report cannot alone prove identity/access/effect
- Allowed paths:
  - `ArkDeckApp/**`
  - `ArkDeckAppUITests/**`
  - `ArkDeck.xcodeproj/**`
  - `Packages/ArkDeckKit/**`
  - `scripts/rockchip_component/**`
  - `scripts/e0_readback/**`
  - `openspec/integrations/rockchip/bundled-component/**`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/**`
  - `openspec/verification/hardware-matrix.md`
- Risk:high（真实 signed process/USB E0；严格零 device mutation/E1/E2/destructive）
- Hardware required:yes
- Decision-Grade:D2。

### Deliverables

- 三类分离 receipt：embedded component version/`ld`、child file-lease diagnostic、
  RockUSB read-only E0；各自记录 process/file/USB/mutation counters；
- no-device、permission denial、wrong identity/hash/version、malformed/multi-device、
  symlink/TOCTOU、file denial、cancel/timeout/disconnect/child crash negative evidence；
- raw device ID/path/log/credential/image/key 内容经 reviewable transform 移除；
- 明确声明 E0 PASS 不等于 Flash/hardware conformance。

### Verification

- `BRC-SANDBOX-E0-001`：exact signed component 在现行 App/child entitlement 下完成
  独立的 bounded E0/file stages，mutation/E1/E2/destructive/privilege/system change
  counters 全为 0；
- 任何 identity/access/USB/outcome unknown 都 fail closed，零 fallback；
- signed tests、SDD、allowed-path、diff、secret/privacy scan 全绿。

### Notes / handoff

- 本 task 不执行 `ppt/wlx/rd`、Loader transition 或真实 update；无 standing
  authorization需求，也不得接受 destructive authorization。

## TASK-BRC-006 — 验证 Developer ID/notarized DMG clean-host、update 与 rollback

- Status:blocked
- Platform:macos
- Requirements：`REQ-FLASH-004`、`REQ-FLASH-013`、`REQ-JOB-006`、
  `REQ-UX-007`
- Acceptance：`BRC-DISTRIBUTION-001`、`BRC-HANDOFF-001`,
  `AC-FLASH-013-01`、`AC-JOB-006-01`、`AC-UX-007-01`
- Depends on：`TASK-BRC-005` done；独立 D1 readiness；human-controlled release
  credentials/environment
- Readiness input pins：未实例化；必须固定 Developer ID/notary release artifact、
  source/SBOM/notices payload、clean host/VM snapshots、install/update/downgrade/
  rollback scenarios、credential owner、network endpoints 与 sanitized evidence
  transform
- Applicable failure patterns：`AF-001`、`AF-002`、`AF-003`、`AF-007`、
  `AF-009`、`AF-010`、`AF-014`、`AF-017`
- Production reachability：human-controlled release pipeline → signed/notarized DMG →
  clean-host install/launch/E0 → update/rollback；零 device mutation与零 E2 authority
- Trusted fact sources：release operator/environment、Developer ID/notary/Gatekeeper
  receipts、clean VM observation、artifact/source/SBOM digests；PR author不能用本地
  ad-hoc build或自报 notarization 结果替代
- Allowed paths:
  - `.github/workflows/**`
  - `ArkDeck.xcodeproj/**`
  - `ArkDeckApp/**`
  - `docs/release/**`
  - `scripts/release/**`
  - `scripts/rockchip_component/**`
  - `openspec/integrations/rockchip/bundled-component/**`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/**`
  - `openspec/verification/hardware-matrix.md`
- Risk:high（外部 release/notary/update effect；零设备 mutation）
- Hardware required:no
- Decision-Grade:D2。

### Deliverables

- clean-host/VM install and launch、nested signature/Gatekeeper/notary/staple、
  notices/SBOM/corresponding-source availability 的复验记录；
- supported update 与 rollback/downgrade 场景，证明 component/App tuple 原子更新、
  drift fail closed、旧 Job unknown 不被 replay；
- credential/network/privacy redaction 与 release retention 记录；
- final handoff 明确 CHG-2026-026 仍需独立 revision/readiness/真实 destructive
  acceptance。

### Verification

- `BRC-DISTRIBUTION-001`：全新 host 只用发布 DMG 即可验证完整 signature/notary/
  supply-chain tuple 与 bounded E0；update/rollback 不产生 mixed-version reachability；
- `BRC-HANDOFF-001`：Core/HDC/CHG-2026-026/hardware matrix 未静默变化，不形成真实
  Flash 支持声明；
- release/platform tests、SDD、allowed-path、diff、secret/privacy scan 全绿。

### Notes / handoff

- clean-host PASS 后仍需独立 D0 done 与 verification closure；不得在本任务直接修改
  CHG-2026-026 或启用 App Flash UI。

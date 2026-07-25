# TASK-BRC-002 run — hermetic unsigned component build

- Change：`CHG-2026-036-macos-bundled-rockchip-component@r1`
- Task：`TASK-BRC-002`
- Task status during run：`ready`（本 implementation/evidence PR 不改状态）
- Evidence class：`platform` + `contract`
- Executor：`agent`
- Execution window：`2026-07-25T10:33:15Z` —
  `2026-07-25T11:16:24Z`（final exact-head rerun pending）
- Audit base / readiness merge：
  `d063b3ca775a5e858020e21a7b4a53db31f37144`
- TASK-BRC-002 readiness exact head：
  `d5ac44f8ee96b12bc23a83a4f8c73cc21ab2f589`
- Earlier readiness merges：
  r2 `b56505aa2180ad8792302dba2566e20a0dd4db47`；
  r1 `0fe0db4e74a3fd642b6d60d6cbda3d12ff96a105`
- TASK-BRC-001 accepted decision merge：
  `4a461ba40f532500e635509455acae95376757ca`
- TASK-BRC-001 done merge：
  `8dfde471bb876b0cd6630ba33859df270d49140e`

## Final builder environment

- GitHub-hosted `macos-26-arm64` image `20260720.0258.1`
- macOS 26.4 (`25E246`) arm64
- Xcode 26.6 (`17F113`)
- macOS SDK 26.5 (`25F70`)
- Apple clang 21.0.0 (`clang-2100.1.1.101`)
- GNU Make 3.81
- Apple `/bin/bash` 3.2.57(1)
- `/usr/bin/python3` 3.9.6
- GnuPG/gpgv 2.5.21，Homebrew formula commit
  `4d32c765e16bde9fffd6c0194a0317ac1ea16c07`
- hosted observed `gpg` SHA-256
  `9d8501878158144e8db80be1454f6c69d62b8a97c21441da3b720081f917f8ac`
- hosted observed `gpgv` SHA-256
  `d9eb7bc783a1a0f1f39bb1f12ff0c94d7c2aac3b25aac2a7909a647d60be7bd4`
- `SOURCE_DATE_EPOCH=1779028641`、`LC_ALL=C`、`LANG=C`、`TZ=UTC`、
  `ZERO_AR_DATE=1`、umask `022`

Builder A/B 是 workflow
[run 30155933128](https://github.com/ArkDeck/ArkDeck/actions/runs/30155933128)
中的两个独立 GitHub-hosted jobs，各自使用最初不存在的 runner temporary roots。
所有 receipt 中的 root、SDK 与 Developer directory 均替换为稳定占位符，未保存
真实绝对用户路径。两者各自建立独立 input、GPG keyring、HOME、TMPDIR、build、
cache 与 output；未共享 source extraction、object、archive 或 output。本地
macOS 26.5.2 (`25F84`) v11 build 只属于 pre-r3 exploratory evidence，其 output/
receipt 已由上述 hosted builders 完整取代，不计入最终 `BRC-REPRO-001`。

## Pinned inputs and acquisition result

每个 builder 只获取 readiness 固定的四个 HTTPS objects：

| Input | Size | SHA-256 | Result |
| --- | ---: | --- | --- |
| rkdeveloptool codeload archive at `304f073752fd25c854e1bcf05d8e7f925b1f4e14` | 59,310 | `389ba41af6986c16f1eeebdc1febcb0bf4b8acb7abd694d3d652e78504215843` | PASS |
| libusb 1.0.30 archive | 656,112 | `fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf` | PASS |
| libusb detached signature | 833 | `7e8916e689a399b98df1087cfc48eab33a6bfd8027291c5af00c3fbba90a2cec` | PASS |
| libusb KEYS | 7,048 | `52b20b8f44c0912fdbd0c7f53c14629b9b72834118dd52ecff3fec671ba50ff3` | PASS |

两个 isolated keyrings 均得到 `GOODSIG` + `VALIDSIG`，primary fingerprint =
`C68187379B23DE9EFC46651E2C80FF56C6830A0E`，signing subkey =
`9C7EA94939C69C4FBC3DBFA8AA0639079EFB61B9`。解包 inventory 为
rkdeveloptool 32 个 regular files、libusb 151 个 regular files；所有 archive path、
root、type、normalized duplicate、link/special file 与 privilege mode 门先于写入。
fetch 完成后，configure/build/link/inspection 都在 deny-network
`sandbox-exec` profile 内运行，且 build profile 拒绝读取 `/opt/homebrew` 与
`/usr/local`。

## Commands

以下命令全部以 executable + argument array 执行；没有 `shell=True`、`-c` command
string、`os.system`、caller PATH/environment 或 pkg-config：

```text
/usr/bin/python3 scripts/rockchip_component/test_build.py

/usr/bin/python3 scripts/rockchip_component/build.py build
  --builder-id builder-a
  --work-root <fresh-builder-a-root>
  --output-dir <fresh-builder-a-output>

/usr/bin/python3 scripts/rockchip_component/build.py build
  --builder-id builder-b
  --work-root <fresh-builder-b-root>
  --output-dir <fresh-builder-b-output>

/usr/bin/python3 scripts/rockchip_component/build.py compare
  --builder-a <fresh-builder-a-output>
  --builder-b <fresh-builder-b-output>
  --output <reproducibility-receipt>

/usr/bin/python3 scripts/rockchip_component/build.py materialize
  --reference <fresh-builder-a-output>

/usr/bin/python3 scripts/rockchip_component/build.py verify-committed
  --reference <fresh-builder-a-output>

gh run download 30155933128
  --name rockchip-builder-a --dir <builder-a-download-root>
gh run download 30155933128
  --name rockchip-builder-b --dir <builder-b-download-root>
gh run download 30155933128
  --name rockchip-reproducibility --dir <comparison-download-root>

scripts/check-sdd.sh
<sdd-venv>/bin/python scripts/test_check_pr_paths.py
```

Repo-owned tests：18/18 PASS。PR-path contract tests：24/24 PASS。SDD：
0 error / 0 warning / 111 acceptance IDs。workflow YAML parse、committed/generated
metadata byte comparison、downloaded comparison receipt 的独立重算/cmp 与 scoped
secret/privacy scan 均 PASS。

## Build and reproducibility result

`recipeId = rockchip-component-build@1.0.0`。libusb 使用 signed 1.0.30 source
的 pre-generated `configure --disable-shared --enable-static`，仅产生 static
archive；rkdeveloptool 只编译 accepted record 的八个 `.cpp` 与 repo-owned
`config.h`，target 为 `arm64-apple-macos14.0`。final link 显式禁止 UUID 与
linker ad-hoc signature；artifact 未执行。

| Output | Size | SHA-256 | Builder A/B |
| --- | ---: | --- | --- |
| temporary unsigned `rkdeveloptool` | 247,488 | `3caee2136551b4b849daf7e9a906813354f354f8adb61e5f092de49ec7a2e56a` | byte-identical |
| `THIRD-PARTY-NOTICES.txt` | 51,206 | `33383934a0db7a5b833c280e0d2904405772f01cc16fea7bf26c18d84f038e2a` | byte-identical |
| `registry.yaml` | 7,150 | `0649cb6f0974107e15cb39e75844532dc9dbaff33a7099d0a64cc7c248e07f54` | byte-identical |
| `sbom.spdx.json` | 37,076 | `05ae1fa74cbabe55dac1ff0bca59607b555b60fb2dbfc556e3af95671e3100ed` | byte-identical |
| `source-distribution-manifest.json` | 3,256 | `558282ba42f6dfdfd21599f5987206bb9f6370180b1653676f826559e61dc563` | byte-identical |

Normalization：`forbidden`。shared build/cache/output root：`false`。artifact inspection：

- architecture `arm64`，minimum macOS `14.0`；
- code signature `absent`；
- expected runtime output 仅由 static format `rkdeveloptool ver %s` + literal
  `1.32` 证明，未 launch binary；
- exported symbols 203，set SHA-256
  `0659a01d19792457e67e78a52129acb097b3f8f2e060ea54da69d46a06c9368c`；
- undefined symbols 193，set SHA-256
  `695166f61e92d97191dcf1ec324ecea1a198b57affa6c69fcd58d15ed5d42a1e`；
- direct load graph 与 accepted 七项 system allowlist 精确相等；
- bundled non-system dylib count = 0；libusb 只来自 static archive；
- registry、SPDX graph、notices/source manifest 与 artifact inspection 一致。

Evidence identities：

- `builder-a.json` SHA-256
  `a909f8f01eae5bcb4fccb4416054cd981b20dbc7384f2c1b100cfe651097f21f`
- `builder-b.json` SHA-256
  `280f54df014978a65680ab4e9890595ced9165ed89571841493ab73662e9895e`
- `reproducibility.json` SHA-256
  `1c9a3af1df792092065be99d3a37edaf6f7b286dc0c3314b55f6db06628080b8`

## Negative/fault matrix

18 repo-owned tests include mutation evidence for：

- archive absolute/`..`/noncanonical/backslash paths、second root、case-fold
  duplicate、symlink、hardlink、FIFO、privilege bits；
- input size/hash drift；
- hosted image OS/label/version drift 与 hosted `gpg/gpgv` hash disagreement；
- caller PATH/Homebrew/config-site/pkg-config injection；
- wrong/minimum-OS load-command shape；
- dependency allowlist、bundled dylib 与 normalization drift；
- SPDX missing relationship/custom license、sensitive/local path；
- identical-output mutation、same-builder identity 与 receipt path instability；
- source audit 对 shell expansion APIs 的封闭检查。

所有失败都在可信 output/metadata 形成前 fail closed。r1
[run 30154865194](https://github.com/ArkDeck/ArkDeck/actions/runs/30154865194)
在 hosted OS drift 停止；r2
[run 30155496750](https://github.com/ArkDeck/ArkDeck/actions/runs/30155496750)
在本地-host GnuPG binary hash 被错误用作 hosted precondition 时停止；两次均
zero upload/build/link/launch。实现中用于定位的更早本地临时
attempt 曾分别命中 configure conftest UUID、archive executable mode、make target、
static version evidence、linker ad-hoc signature、Property notice delimiter、
Python 3.9 API 与 receipt/load-command path instability；每次均 non-zero 停止，
没有 launch binary、没有把失败 output/materialization 记为最终 evidence。本地
v11 fresh roots 仅用于探索；最终 evidence 来自 run 30155933128 hosted builders。

## AC verdict

- `BRC-REPRO-001`：**PENDING final exact-head committed-metadata audit**。相同 exact
  inputs/toolchain 在两个 fresh roots 产生 byte-identical unsigned artifact 与
  registry/SBOM/notices/source manifest；无 normalization、ambient
  Homebrew/PATH/network/cache dependency。run 30155933128 的 builders、A/B compare
  与 comparison upload 均 PASS；该 run 最后只因 repo 仍为 pre-materialization
  metadata 而在 committed audit 预期失败。下一 exact head 必须全绿后才改为 PASS。
- `AC-JOB-005-01`：**PASS（TASK-BRC-002 build/descriptor slice）**。host orchestration
  使用 absolute executable + argument arrays；caller 路径/环境被丢弃，无 shell
  expansion。该结论不声称 runtime image/key argv。
- `AC-FLASH-013-01`：**PASS（TASK-BRC-002 diagnostic/distribution slice）**。
  registry/receipts 固定 stage、identity、failure reason 与 recovery =
  fail build / return fresh readiness；不把 build 或 process exit 0 当成 Flash 成功。

GitHub two-builder materialization run = 30155933128，exact head =
`5e473df5f9ef85f6a1ccc2b41e5b83a8c7cb5f2f`。builder A/B 与 byte-identical
comparison PASS，committed metadata audit 预期 FAIL；该 run 只授权本次
materialization，不单独闭合 implementation evidence。

## Effect and privacy counters

每个 builder 仅执行 4 次 allowlisted HTTPS fetch；fetch 之后 network denied。
最终 counters：

| Effect | Count |
| --- | ---: |
| component/App launch | 0 |
| package/sign/notarize/install/update | 0 |
| HDC/USB/device | 0 |
| E1/E2/deviceMutation/destructive | 0 |
| bookmark/image/key/output access | 0 |
| privilege/entitlement/system rule/group/ACL mutation | 0 |

Repo 只保存 source/recipe/registry/SBOM/notices manifests 与 sanitized receipts；source
archive、GPG keyring、unsigned Mach-O、objects/build/cache、raw final redirect query、
credential、用户 path、device identifier 与 binary 均未入仓。

## Deviations and residual risks

- Approved source/dependency/toolchain/minimum-OS/architecture/link/SBOM envelope：
  zero deviation。
- 本 run 不证明 signed package、Sandbox child launch、file lease、RockUSB、clean-host
  distribution 或真实 Flash；这些分别属于 TASK-BRC-003/005/006 与后续
  CHG-2026-026。
- hosted materialization output 已写入声明 paths；仍需下一 exact-head workflow
  对 committed metadata 全绿复验，再把本记录的 pending verdict 改为 PASS。
- TASK-BRC-002 保持 `ready`；implementation/evidence 合入后必须另开 D0 status-only
  PR，TASK-BRC-003 在该 done merge 与独立 D1 readiness 前继续 `blocked`。

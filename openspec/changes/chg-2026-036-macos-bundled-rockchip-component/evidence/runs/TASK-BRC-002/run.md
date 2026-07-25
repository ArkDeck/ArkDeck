# TASK-BRC-002 run — hermetic unsigned component build

- Change：`CHG-2026-036-macos-bundled-rockchip-component@r1`
- Task：`TASK-BRC-002`
- Task status during run：`ready`（本 implementation/evidence PR 不改状态）
- Evidence class：`platform` + `contract`
- Executor：`agent`
- Execution window：`2026-07-25T10:33:15Z` —
  `2026-07-25T10:34:44Z`
- Audit base / readiness merge：
  `0fe0db4e74a3fd642b6d60d6cbda3d12ff96a105`
- TASK-BRC-002 readiness exact head：
  `41bc8490981697805876e258f7b2666c2d704827`
- TASK-BRC-001 accepted decision merge：
  `4a461ba40f532500e635509455acae95376757ca`
- TASK-BRC-001 done merge：
  `8dfde471bb876b0cd6630ba33859df270d49140e`

## Environment

- macOS 26.5.2 (`25F84`) arm64
- Xcode 26.6 (`17F113`)
- macOS SDK 26.5 (`25F70`)
- Apple clang 21.0.0 (`clang-2100.1.1.101`)
- GNU Make 3.81
- Apple `/bin/bash` 3.2.57(1)
- `/usr/bin/python3` 3.9.6
- GnuPG/gpgv 2.5.21；gpgv SHA-256
  `da2acbb7c6f54461b80d4ccc61c82dc4258a580298bf1a974ebda1ff8a504780`
- `SOURCE_DATE_EPOCH=1779028641`、`LC_ALL=C`、`LANG=C`、`TZ=UTC`、
  `ZERO_AR_DATE=1`、umask `022`

Builder A/B 使用不同且最初不存在的 OS temporary roots；所有 receipt 中的 root、
SDK 与 Developer directory 均替换为稳定占位符，未保存真实绝对用户路径。两者各自
建立独立 input、GPG keyring、HOME、TMPDIR、build、cache 与 output；未共享 source
extraction、object、archive 或 output。

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

scripts/check-sdd.sh
<sdd-venv>/bin/python scripts/test_check_pr_paths.py
```

Repo-owned tests：16/16 PASS。PR-path contract tests：24/24 PASS。SDD：
0 error / 0 warning / 111 acceptance IDs。workflow YAML parse、committed/generated
metadata byte comparison 与 scoped secret/privacy scan 均 PASS。

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
| `registry.yaml` | 6,159 | `f0a7de9bf2c0ddbbde8020c2f0622b794e3c5bb042eb586eca870cd32fb308fb` | byte-identical |
| `sbom.spdx.json` | 37,076 | `05ae1fa74cbabe55dac1ff0bca59607b555b60fb2dbfc556e3af95671e3100ed` | byte-identical |
| `source-distribution-manifest.json` | 3,256 | `9887ca04ed14b67e4e258db9668293e3c9646238c0815368f4f83c6b582a795a` | byte-identical |

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
  `7025847cdc182372b45773194aa4f8b2dcc176af92ecfbfde5480379f33e23e1`
- `builder-b.json` SHA-256
  `08cba2c8accd99b97c7eb7a7dcd6c40fcb962e6ea4011fc737d0671817b39227`
- `reproducibility.json` SHA-256
  `972f53729827075648f6e9f520fe8b99f6335123e5f90ea651f5788c1d722aa9`

## Negative/fault matrix

16 repo-owned tests include mutation evidence for：

- archive absolute/`..`/noncanonical/backslash paths、second root、case-fold
  duplicate、symlink、hardlink、FIFO、privilege bits；
- input size/hash drift；
- caller PATH/Homebrew/config-site/pkg-config injection；
- wrong/minimum-OS load-command shape；
- dependency allowlist、bundled dylib 与 normalization drift；
- SPDX missing relationship/custom license、sensitive/local path；
- identical-output mutation、same-builder identity 与 receipt path instability；
- source audit 对 shell expansion APIs 的封闭检查。

所有失败都在可信 output/metadata 形成前 fail closed。实现中用于定位的前序临时
attempt 曾分别命中 configure conftest UUID、archive executable mode、make target、
static version evidence、linker ad-hoc signature、Property notice delimiter、
Python 3.9 API 与 receipt/load-command path instability；每次均 non-zero 停止，
没有 launch binary、没有把失败 output/materialization 记为 evidence，最终 v11
fresh roots 才产生本记录。

## AC verdict

- `BRC-REPRO-001`：**PASS（local exact-host two-clean-builder slice）**。相同 exact
  inputs/toolchain 在两个 fresh roots 产生 byte-identical unsigned artifact 与
  registry/SBOM/notices/source manifest；无 normalization、ambient
  Homebrew/PATH/network/cache dependency。
- `AC-JOB-005-01`：**PASS（TASK-BRC-002 build/descriptor slice）**。host orchestration
  使用 absolute executable + argument arrays；caller 路径/环境被丢弃，无 shell
  expansion。该结论不声称 runtime image/key argv。
- `AC-FLASH-013-01`：**PASS（TASK-BRC-002 diagnostic/distribution slice）**。
  registry/receipts 固定 stage、identity、failure reason 与 recovery =
  fail build / return fresh readiness；不把 build 或 process exit 0 当成 Flash 成功。

GitHub `macos-26` 两独立 runners 的 workflow run 将在 first exact implementation
push 后追加引用；在该 run 通过前，本地 PASS 不单独闭合 implementation evidence。

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
- GitHub two-runner result 与 exact workflow URL 在首次实现 push 前尚不可存在；需在
  本 PR 内追加并由更新后的 exact-head checks 再验证。
- TASK-BRC-002 保持 `ready`；implementation/evidence 合入后必须另开 D0 status-only
  PR，TASK-BRC-003 在该 done merge 与独立 D1 readiness 前继续 `blocked`。

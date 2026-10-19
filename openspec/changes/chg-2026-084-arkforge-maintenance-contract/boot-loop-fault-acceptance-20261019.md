# 真实反复重启故障专项验收（2026-10-19）

本专项补充已完成的 [独立入口验收](independent-acceptance-20261019.md)。该记录证明了
Normal/HDC 下的原 ramdisk 恢复与独立完整哈希读取；它没有注入真实反复重启故障。
本专项已通过所选 HDC 窗口路径：三个不同启动的 Runtime 快照证明至少两次真实自动重启，
随后独立恢复原 ramdisk、完整哈希复验并完成超过故障周期的稳定观察。

## 观测能力

`observe.device@1` 增加 `includeBootContext`，默认 `false`。只有显式选择 `true` 时，
精确绑定的 HDC Provider 才执行固定、只读、有时间和字节预算的 `bootContext` 读取。
该步骤被选择后必须成功；读失败、输出不完整、boot ID 在读取期间变化、故障报告与
当前 boot ID 不一致、报告重复或不符合 RAM 文件约束，均不能发布成功快照。

`boot-context.json` 是本地敏感 Artifact，关联当前 Job、Catalog、设备身份和实际读取
时间窗，包含 kernel boot ID、uptime、idle time，以及可选的 RAM 故障标记。故障标记
只从固定控制器持有的 root 所有、权限 `0400`、大小受限的 RAM 文件描述符读取；调用方
不能提交路径、命令或预期观测值。快照和故障标记不承担 capability authority。

未选择时保留既有设备调用。新 Catalog 对 `observe.device@1` 作兼容增量，Flash 与
恢复 operation、destructive policy 和原始历史记录保持不变。历史 c6/e4 测试仍使用
完整的冻结 Catalog；新快照集成用例仅进入声明此能力的 Catalog 视图。

## 本次故障与完成条件

用户选择了真实自动反复重启、每轮保留短暂 HDC 观测窗口的路径。最终在原 ramdisk
的派生镜像中保留原 `bin/init_early`，由独立 RAM 控制器在 kernel uptime 达到 300 秒
时触发重启。控制器在原 init 启动前持有 proc 目录描述符；旧根目录清理后，仍通过该
描述符完成系统现有的 init 运行域切换。300 秒周期为实测约 140 秒的恢复计划与准入
留出交接时间；恢复后的稳定观察相应要求至少 330 秒。每轮启动都会重新运行控制器；
恢复原 ramdisk 后移除该行为。原镜像不改写，派生过程保留源哈希、控制器哈希、参数
及完整归档成员校验。

当前已发布 Flash 入口的写入范围是完整九分区，包括 `userdata`；故障归档仅替换
`ramdisk.img`，其余归档成员与原件逐项相同。设备写入只经 protected-main Runtime 的
typed operation，capability 仍由 Runtime 根据完整物化计划和 fresh trusted facts 生成、
reserve、consume。主机输入构建不构成设备验收。

完成本专项需要实际取得：

1. 当前发布 Catalog 上的完整九分区源 Flash confirmed receipts，且不存在 unknown。
2. 同一设备、同一故障 nonce 下至少三个不同 boot ID 的 Runtime 快照，证明至少两次
   自动重启；每个快照均有实际读取的 Artifact 和独立 Job 记录。
3. `flash.restore-boot-loop@1` 对该源执行独立恢复，实际只恢复完整原始 4 MiB ramdisk，
   并以 full hash 验证成功；新 capability 精确匹配且仅消费一次。
4. 独立 `flash.verify@1` 返回 ramdisk 完整哈希成功；恢复后的两次 Runtime 启动快照
   不再带故障标记、保持同一 boot ID，观测间隔至少 330 秒，超过本轮 300 秒周期。
5. 相关公开 result/evidence 和 Session 发布成功，原历史、旧 capability 与旧 allocation
   不改写。任何 unknown 或缺失的恢复证明均按现行安全策略停止受影响的写入。

本专项覆盖所选的 HDC 窗口路径，不代表启动早期 HDC 完全不可达或 Loader/MaskRom 路径
已经验收。以下记录仅覆盖本次 300 秒周期、HDC 可观测窗口下的真实故障与恢复。

## 首轮试验与恢复

首轮使用 protected `main` `3142957cd6e11ac46c5f0b4fb97a45625df441d7` 的签名 Runtime，
Catalog 为 `fe0806a5756ae59d55410a976039d2cd1853105f6d7d1f5aa00473026a81ed18`。
源 Job `job-7bfca2efe613801268f68b41ce562038` 完成九分区写入，结果 confirmed、无 unknown，
但 Session 发布为 `sourceIntegrityFailed`：观测时间 `08:00:11Z` 晚于 capability 消费时间
`07:55:43Z`。后续只读快照在 uptime 195.530 秒时未发现故障控制器，不能证明所需重启。
这两项失败均保留原始 Runtime 记录；不将源 Job 或本轮试验记为专项通过。

随后由 Runtime 根据该实际源的完整机械证明准入独立恢复 Job
`job-fe34cac737c09fa274d14616d1b27c4e`，仅恢复原始 ramdisk 范围
`121634816 + 4194304` 字节，完整哈希为
`bdd1f4eacbe545f5a553b529980bc487723d37554148058dd551c241abf86de4`。
独立验证 Job `job-2f7b7b6d28cb4f52a15d7cfcd0d3079f` 返回 exit 0、verified 1、
skipped 0、failed 0，两者 Session 均已发布。恢复后的两个只读快照无故障标记，保持同一
boot ID，实际观测间隔 254.208 秒、uptime 增长 254.240 秒。Runtime 审计确认本轮仅有
两个新 capability，各消费一次；旧 capability、allocation 和历史 Job 字节保持不变。

本次普通修复补齐 HDC Normal 模式 FullFlash 的准入前机读观测，并保留该观测供 Session
校验；刷后的型号、版本仍由实际 postflight receipt 发布为 `post-flash-facts.json`。
观测缺失、身份或路由漂移、空元数据在消费前停止。Session 的时间顺序校验、Catalog、
destructive policy、历史 fixture 和设备写入范围均不放宽。下述最终轮已验证该修复与完整故障恢复。

## 后续试验与最终真机结果

第二轮源 Flash 的 Session 已正常发布，但控制器在首次快照后消失；uptime 250.650 秒
的快照与首次快照属于同一启动。第三轮取得五份带故障标记的快照，仍只有一个 boot ID。
只读诊断发现原 init 的 `switch_root` 清理了旧根目录中的 proc 路径，控制器未完成运行域
切换。两轮均未计为反复重启通过，并通过 Runtime 独立恢复、复验原 ramdisk：

| 轮次 | 源 Job | 恢复 Job | 独立验证 Job | 恢复后同次启动观察 |
| --- | --- | --- | --- | --- |
| 第二轮 | `job-d66ae8f14fab248b3191e02f6701c616` | `job-2151de0a82efca2086e0a0e7f8286cee` | `job-8a9364cd0f3f2040b3d9a68708816db7` | 241.298 秒 |
| 第三轮 | `job-fc2653f08fc825c4ccaedcb7f228aebc` | `job-282fda360bece6dd8b40cf6501343b99` | `job-5ca1b8ecf2a635e280e511140bfae97e` | 359.721 秒 |

最终轮使用 protected main `20a9f04193a6898219c636533b4672b067d2759d` 的签名 Runtime
（PR #2679），Catalog 为 `fe0806a5756ae59d55410a976039d2cd1853105f6d7d1f5aa00473026a81ed18`。故障控制器提前
持有 proc 描述符，已实际进入 init 运行域；相同故障 nonce、300 秒周期下取得三个不同
boot ID 的 Runtime 快照，证明至少两次自动重启。采样期间没有外部重启命令。

最终故障归档 SHA-256 为
`78d7a9e160fde852e996f0f7abca6c75548e71a35bfb96fbe2b30fb9615d1a24`，
大小 723107654 字节。为满足现有 Artifact 配额，仅对归档采用 gzip level 9 重压缩；
解压后的完整 tar 流逐字节相同，17 个成员逐项校验，只有 ramdisk 的派生内容发生变化。
控制器及原 init、CPIO 元数据和硬链接的校验保留在本机输入来源记录中。

| 阶段 | Job | 关键 Artifact SHA-256 |
| --- | --- | --- |
| 正常基线 | `job-0cb8276b569a2bb68d9833c56e54afc9` | `0d3e82816f09625949f63870533cb576d3538f74d3151464249ebb98917aebd5` |
| 九分区源 Flash | `job-04724a2583186820cac752161ac4a1e0` | `954ce799c3d18e5e5ce57a44af7294fda128c45a84f59955ded00312c8bd26dc` |
| 故障启动 1 | `job-0f8356a72c4af953530c9ccbac4ce019` | `1817e54a30550048a5c45fe36091dbb1b3968e1b9f92ba6259bb479229fe9b45` |
| 故障启动 2 | `job-c7ae4fd5e96f5224ec7735a198b0a43b` | `c4fad7967a190c8677986d978c2e2fca4d0c5a240b5473dded5e241476554bff` |
| 故障启动 3 | `job-9fbcf7c8348f6a95909f9a6a9491fad0` | `98edda8e4c142e4778cf5c276f8c89046abeff0b6b6bb26eb0ee3a9e4b5a0ddf` |
| 独立恢复 | `job-ab56cad69f180c66a73573bf0b113e6a` | `ba28a984d1bd094df597b063fa3761aa273a89fcca40bee5019763a00244e330` |
| 独立完整哈希复验 | `job-15c70bcd701180cca15ee54308a0a49e` | `8a35b2b2cefcd57b87a0258941706cb02ad61e53cc5b3b412f757edaa45327b4` |
| 恢复后启动观察 1 | `job-fee1e2517d098440350d6385728fda88` | `ff8cf457090d773b2d6429cfdfe4bbdc2d33aa85dcebe6810febc493a18fc3b8` |
| 恢复后启动观察 2 | `job-6109ef44defbd28330741a7149602806` | `f315a03e10f2b82f3001ce0b3c953ba0cec361f4330afe5e767fe184a6dabecc` |

表中 Job 均 succeeded、无 unknown，Session 均 published；Artifact 字节数和 SHA-256
经独立读取核对。恢复实际只写入 `121634816 + 4194304` 字节的原始 ramdisk，并以 full hash
核对上述 `bdd1…de4` 完整摘要；独立 `flash.verify@1` 再次返回 exit 0、verified 1、skipped 0、
failed 0。恢复后两份快照保持同一 boot ID、无故障标记，实际间隔 359.124 秒，
uptime 增长 359.870 秒。

本轮只有源 Flash 与独立恢复各产生一个新 capability，各消费一次、剩余零，精确匹配
输入、物化计划、目标绑定和 Artifact。既有 39 个 capability、2 个 allocation 和 197 个
历史文件保持原字节；全部只读 Job 没有消费 capability。原始 boot ID、nonce、设备身份、
本机账户路径及 capability 记录保留本地，本文仅记录可公开的 Job 与摘要。

最终轮调用均为已发布 CLI 的 typed operation：`flash.full-restore@1`、
`observe.device@1`、`flash.restore-boot-loop@1`、`flash.verify@1`，随后读取同一执行的
status/result/evidence 和 Artifact。CLI 等待超时后只查询原执行，没有重放设备意图。

## Local targeted checks

最终验收记录仅更新本文；`sh scripts/check-sdd.sh`、`git diff --check` 和九个 Job
摘要、设备身份脱敏核对均 exit 0。日志保存在本机 `boot-loop-docs-checks-20261019-final/`
的 `sdd.log`、`diff.log`、`report-redaction.log`。本轮未重复 Rust、SwiftPM、App 构建或
本地统一门；产品代码的定向检查与 CI 结果保留如下。

所有日志仅保存在本机 `boot-context-checks-20261019/`，不导出原始设备数据：

- `python rust/scripts/run-cargo.py test -p <crate> --lib`：修改 crate 与直接依赖共 11 个
  crate 全部 exit 0；Hoststore 428 passed、5 ignored。日志 `lib-*-catalog-pins.log`。
- `python rust/scripts/run-cargo.py clippy -p <crate> --all-targets -- -D warnings`：同一组
  crate exit 0，日志 `clippy-final.log`。
- Provider `--lib boot_context::` 三项与 Runtime `--test windows_observe_device_commandless`
  五项均 exit 0，日志 `provider-boot-final.log`、`runtime-boot-final.log`。覆盖默认调用不变、
  实际 Artifact 字节与哈希、敏感读取、畸形和跨 boot 快照拒绝。
- CLI `--test machine_contracts --test maintainer_contracts` exit 0，日志
  `cli-machine-final.log`；官方契约 export 的 244 个产物仅两个 Catalog digest 投影改变。
  App 的离线 Flash 投影也由官方 `flash_catalog_review` example 重生成。
- Catalog generator 49 项与相关 Python 聚焦检查 73 项 exit 0，日志
  `catalog-generator-schema-fixed.log`、`python-focused-initial.log`。完整 Python 检查的
  78 项中 76 passed、1 skipped、1 因 Windows 的 POSIX mode 表现为 `0777` 而非 `0700`
  失败，保留在 `contract-checks-schema-fixed.log`，未修改该断言或将其记为通过。
- `python rust/scripts/run-cargo.py fmt --all --check` 遇到 Windows argv 长度错误 206；
  同覆盖范围的分批 `rustfmt --check` exit 0，日志 `fmt-all-final.log`、
  `fmt-batched-final.log`。
- `sh scripts/check-sdd.sh` exit 0，0 errors、0 warnings、121 acceptance IDs，日志
  `sdd-final.log`；`git diff --check` exit 0。
- CI 发现两处生成物 drift 后，官方 `generate-contract.py --write`、`--check` 均 exit 0，
  仅更新输入指纹，110 个 control methods、1085 个 recorded shapes 和 contract identity
  保持不变。Windows JSON 从官方 Swift Flash 投影同步，单跑
  `TheCatalogReviewIsTheOneTheMacOsAppCompilesIn` 一项 exit 0。日志
  `contract-*-ci-fix.log`、`windows-projection-test-ci-fix.log`。
- 新 Catalog 的完整输入兼容证明单跑 exit 0，日志 `compatibility-ci-fix.log`：先核对完整
  新 Catalog 的精确摘要，再仅以旧 `observe.device@1` 替换新描述符，要求完整表恢复为
  已发布的前一 Catalog 摘要，随后继续逐项比较全部 32 个旧描述符。旧 fixture 不修改。

观测能力这一轮本机未执行 SwiftPM、macOS App build-for-testing 或本地统一门；Windows
仅单跑了上述离线投影检查。

FullFlash 准入前观测修复的日志保存在本机 `flash-preflight-checks-20261019/`：

- 推进时钟的 FullFlash 回归先复现 `sourceIntegrityFailed`，修复后 exit 0；完整策略
  定向测试 9 passed，最终 FullFlash 边界 2 passed，recommission/controlled retry 边界
  12 passed，均 exit 0。日志 `full-restore-clock-red.log`、`flash-policy-final.log`、
  `full-restore-boundary-final.log`、`recommission-boundary-final.log`。
- Hoststore 与直接依赖 Agentd、Soak 的库测试 exit 0；Hoststore 为 428 passed、5 ignored，
  另两者各 3 passed。相同三个 crate 的 `clippy --all-targets -- -D warnings` exit 0。
  日志 `lib-*-final.log`、`clippy-boundary-final.log`。
- 官方 `fmt --all --check` 仍受 Windows argv 206 限制；全部 358 个相同 workspace
  target 根的分批 `rustfmt --check` exit 0。日志 `fmt-all-native.log`、
  `fmt-batched-native.log`。Catalog 路由检查 36 passed、exit 0，原 fixture inventory
  逐字节一致；新加两项回归注册到现有 policy 视图。日志 `catalog-views-native.log`。
- SDD 检查 exit 0，0 errors、0 warnings、121 acceptance IDs；`git diff --check` exit 0。
  受限 Temp 无法创建检查目录、受限 shell 无法启动的原始失败日志保留，改用正常本机环境
  执行同一检查后通过，未放宽断言。日志 `sdd-native.log`。
- 补齐控制套接字 HDC 替身对既有 `const.product.name` 只读查询的响应后，Windows 的
  Flash owner 三项 passed、一项保留的 subprocess fixture ignored，Agent run 套接字
  一项 passed，均 exit 0。成功、unknown、不重放和缺失真实硬件证明拒绝的断言均保留。
  日志 `flash-owner-fixture-property-name.log`、`flash-socket-fixture-property-name.log`。
  macOS 替身分支只能由对应 CI 实际执行。

## CI

观测能力 [PR #2678](https://github.com/ArkDeck/ArkDeck/pull/2678) 的首轮
`39197939838` 在契约输入指纹与 Windows App 投影一致性检查失败；已按实际错误同步生成物，
未修改断言。修复 head 的 CI 结论待实际完成后记录。CI 成功与 host fixture 均不替代
本专项的真实设备结果。

同 PR 的 `39198677397` 已通过主机检查、Windows ClientKit、App 构建、Linux workspace
和 Linux contract parity；Swift 的显式 remote-read 集合与历史输入兼容测试的版本清单
尚未覆盖新 Catalog。后续提交加入明确的 `bootContext` 集合项和上述完整摘要证明，
保持未知 action、未知 Catalog 和旧输入字段拒绝条件，继续由 CI 验证。

`39200798439` 的 Swift、App、Windows ClientKit、主机检查、三平台 workspace 和
Linux/macOS contract parity 均成功。Windows contract parity 被 100 分钟 job 上限取消：
自动保留的 provenance 证明 published、candidate、historical 三视图完整通过，observed
视图在最后一组单测中被截断，日志没有断言失败。该用例在前三视图均成功；published
和 historical workspace 各约 28–29 分钟，candidate consumer 约 10 分钟，observed
又执行约 26 分钟后被截断。本次输入差异
需要完整四视图，因此 Windows 该 job 预算调整为 120 分钟；精确预算校验及 121 分钟
拒绝用例同步更新，全部产品/契约用例、断言和设备 Runtime 预算保持原样。最后的
Session 用例本机单跑 exit 0（25.61 秒），日志 `session-publication-isolated-budget-120.log`。
新 head 的完整结论仍需 CI 实际给出。

最终 head `b6982762097028d004389cfed42ae5c694063522` 的
[Swift CI 39211002240](https://github.com/ArkDeck/ArkDeck/actions/runs/39211002240) 全部成功，
包括 Windows contract parity（55 分 50 秒）、macOS contract parity（53 分 18 秒）、三平台
workspace、Swift、App 和 Windows ClientKit；SDD Guard `39211002214` 成功。
PR #2678 已合入上述 protected main。真实故障专项仍以独立设备完成条件为准。

FullFlash 修复 [PR #2679](https://github.com/ArkDeck/ArkDeck/pull/2679) 的首轮
`39224958377` 中 Linux workspace 与 contract parity、主机检查通过；macOS workspace
在共用 HDC 替身的 13 个控制入口用例中失败。该替身只回答 `const.product.model`，未实现
准入前观测已有的 `const.product.name` 查询；各用例在消费前停止。现补齐该响应并同步
source pin，保持全部原断言和产品准入条件，后续 head 由 CI 重新验证。

最终 head `0763ec9213d65a2f37b6a8c4587e58d7772877d5` 的
[Swift CI 39227289517](https://github.com/ArkDeck/ArkDeck/actions/runs/39227289517) 全部成功，
包括三平台 workspace、三平台 contract parity 和主机检查；Windows contract parity 为
52 分 51 秒，macOS workspace 为 15 分 55 秒。SDD Guard `39227289470` 与 `39227392417`
均成功。PR #2679 已合入上述 protected main，最终真机轮使用的即是该发布版本。

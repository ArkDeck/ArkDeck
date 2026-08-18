# Verification — CHG-2026-063

> Change:CHG-2026-063-arkforge-native-rockusb@r1
> Status: proposed；本文件不声称任何 merge 结论。各 AC 的台架实证在对应
> Task 的实现 PR 中重跑并附 evidence。

## Acceptance

- **NRU-AC-1**（底座）：`arkforge-usb` 在台架枚举出唯一 0x2207 设备并读回
  serial/topology，与 `ioreg` 交叉一致；unsafe/FFI 零外溢（其余 crate
  `grep -r unsafe` 无新增）。
- **NRU-AC-2**（读一致）：原生 `rl` 与 vendor `rl` 对首扇区、GPT 主表
  （LBA 1）、GPT 备表（末端）、≥3 个随机窗口逐字节相同（哈希清单进
  evidence/）。
- **NRU-AC-3**（语义等价）：原生 `ppt`/枚举与 vendor 输出语义等价
  （分区名/offset/size 全同）。
- **NRU-AC-4**（写互证）：原生写→vendor 读回、vendor 写→原生读回，两向
  九分区摘要全部一致。
- **NRU-AC-5**（无 spawn 全绿）：`--rockusb-port native` +
  `--hardware-campaign AFA-AC-7` 下 `flash.dayu200` 达 `succeeded`，
  运行期 `pgrep -f rkdeveloptool` 全程为空（取证脚本进 evidence/）。
- **NRU-AC-6**（治理）：新 toolchain 身份未经 campaign 时该组合
  `hardwareGated`（负向断言，防治理旁路）。
- **NRU-AC-7**（换源）：vendor `ld` 调用点归零（`observeLoader(executable:`
  引用清零）；双源观察语义保持（单 IOKit 源不足以放行，契约测试断言）。
- **NRU-AC-8**：ArkDeck 全量测试（≥1815）零失败。
- **NRU-AC-9**（退役）：打包产物无 rkdeveloptool；lane 三要素组合可用；
  旧四要素 plist 升级不炸（迁移测试）。
- **NRU-AC-10**（终局回归）：默认配置下全绿 `succeeded` 一次，且
  postflight 事实（`const.product.model`/`const.ohos.fullname`）与设备
  实答一致。

## 台架执行手册（实现 Agent 必读）

部署仪式（每次换二进制）：

```
launchctl bootout gui/$UID ~/Library/LaunchAgents/com.arkdeck.agentd.plist
pkill -9 -f "arkforged --runtime-dir"
pkill -f "toolchains/hdc"        # 注意：argv 里 -m 在末尾，"hdc -m" 匹配不到
rm -f "$HOME/Library/Application Support/ArkDeck/Agentd/arkforge/"*.sock
# 构建→staged 签名→agentd update（全套 lane flag）→摘要比对安装件
```

- 安装验证用**字符串字面量或摘要**，不要 grep 注释（注释不进二进制）。
- arkforged 部署：packaging 脚本产物只取 `arkforged` 本体（TASK-NRU-004
  之前 vendor 工具仍是 `/Applications/ArkDeck.app` 内那份，勿覆盖其 pin）。
- 提交请求：request JSON 不带 `authorization` 块（默认策略铸下一代能力）；
  `job submit --request-file` → `job run --job <id>`。上一代 use 未了结时
  先 `job reconcile --job <上一个 job>`（unknown 的 lane job 走对设备验证，
  设备答出声明构建即 `recovered`）。
- 首启 1–8 分钟属正常（userdata 初始化）；postflight 600s 预算在
  `verifyBoundBuild` 内部，勿动。
- 板子身份三元组（Loader serial / hdc key / locationID）都会漂移；重连
  双路线规则（topology 或已知 key 别名）已实现，勿回退。
- ArkDeck 侧 PR：推 `agent/**` 分支由 CI 以 bot 身份开 PR，**绝不**
  `gh pr create`；先跑
  `.venv-sdd/bin/python scripts/check_pr_paths.py --repo-root . --preflight
  --base-revision origin/main --head-revision HEAD --expected-head-ref
  <branch> --allow-bootstrap --infer-task` 并**直接看退出码**。

## 证据留存

每个 Task 的台架产物（哈希清单、pgrep 取证、campaign transcript、
succeeded job 的 timeline 摘录）放 `evidence/` 子目录，文件名带日期。

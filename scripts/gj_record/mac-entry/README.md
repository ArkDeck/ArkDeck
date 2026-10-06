# Root Mac entry for the exact 2026-10-06 pair

`entry.py` 是本机 Mac **单命令** typed capture 适配器，复用主仓 `gj_record.capture` 的字节与 journal 格式。它不自动推进完整 Journey、不创建 Runtime state、不签名、不发 PASS。当前仅运行了 fake-runner 纯检查；Root 审阅后在实际 Mac 本机执行。Windows 继续使用已审阅 existing helpers；fixture bytes 和 published operations 相同。

## 已确认环境，不猜可用主机

2026-10-06 的 bounded BatchMode SSH 只读探测已实际执行：现有非 GitHub SSH 主机为 **Linux**，不是 Darwin，`arkdeck` 不在 PATH，published Mac helper 的文件入口不存在。没有设备或 Runtime 调用、服务启动、账户/机器名/key 输出。不能把它当作 Mac。

仓库存在可构建 Mac RC 的 `xcode-27` lane。最近成功 [release-rc run 37075826611](https://github.com/ArkDeck/ArkDeck/actions/runs/37075826611) 源为 `3efba88c18adbc28be7fb9ef0e495195aaec39c0`（2026-10-02）。job metadata 标记 GitHub Actions group / `xcode-27`；这不是现成 USB 设备或 SSH 访问证明，且源早于本次 protected `19097bde…`。repo runners GET 返回零，组织 runners GET 权限不足；未升级权限、修改 SSH 信任或尝试新凭据。

可直接推进的入口是：Root 等本轮 Trace CRLF 产品修复及 Mac RC build 4 的正常 review 合入后，从实际 protected main 的 signed/notarized Mac RC lane 一次获得发布包；使用已经具备本机访问权的 Mac，或建立获授权且主机身份核验过的 Mac 连接。需要的唯一物理动作是将 DAYU200 从已闭合、无在途/unknown/HAR 的 Windows 窗口转至 Mac 的固定 USB 口，并按 GJ-1 提示完成断连/重插。GitHub CI runner 未证明能接触这块板子，不直接在它上面提交设备 operation。

## 本机准备命令

将本目录 `entry.py`、`test_entry.py`、`README.md` 与主仓公开 source 搬到 Mac；来源基线使用主仓 `scripts/gj_record/baselines/gj-pair-armv7-20261006/manifest.json` 及其 `source/`，不再复制旧 proposal。将同一份实际 signed HAP/candidate/ghost 由 Root 复制到其 precreated private Raw/inputs。不传 profile/keys，不重新构建或签名。公开 source 不能代替冻结的 signed bytes。

```sh
python3 -B entry.py --help
python3 -B entry.py
python3 -B entry.py verify-materials \
  --hap /private/tmp/arkdeck-gj-headless-20261006/inputs/entry-signed.hap \
  --candidate /private/tmp/arkdeck-gj-headless-20261006/inputs/candidate-signed.so \
  --ghost /private/tmp/arkdeck-gj-headless-20261006/inputs/ghost-signed.so
```

使用实际 canonical paths；`/private/tmp` 输出根和 `inputs` 由 Root 提前创建，output root owned/mode0700 且位于 repo 外。JSON config 必须恰好有这九个字段，不接受 state/credential/capability 字段：

```json
{
  "schemaVersion": "arkdeck.mac-paired-entry/1",
  "repository": "/absolute/clean/ArkDeck",
  "sourceRevision": "ACTUAL_FULL_PROTECTED_MAIN_SHA",
  "cli": "/absolute/published/arkdeck",
  "cliSha256": "ACTUAL_COMPLETE_CLI_SHA256",
  "daemon": "/absolute/published/arkdeck-facade",
  "daemonSha256": "ACTUAL_COMPLETE_DAEMON_SHA256",
  "out": "/private/tmp/arkdeck-gj-headless-20261006",
  "catalogDigest": "c6e92eb252fe7653ed303a9ce34d12635bbc5f71ffb2a54fb8eb1fa3a9b99036"
}
```

repo HEAD 必须等于 freshly fetched `origin/main`，tracked source clean；RC source 可为 protected-main ancestor，但必须由主仓 validated Catalog reader 证明 RC/current main 的 digest 与 canonical operation set 相同。adapter 核验 Mac 两个实际 image 的 whole SHA 和 native codesign/Team `8AQTYW5FKR`，清除 ambient ARKDECK/OHOS_HDC overrides，仅绑定这对 image。`launchAgent.daemonSHA256` 是已配置文件的摘要，单独不构成 running-image proof；preflight 还需下面的真实 native-instance 证明。不能仅因 source SHA 不同强制重发 RC，也不能把不同 Catalog 当作 compatible。

此次旧 RC 确实不兼容：同一 validated `scripts/gj_record/catalog.py` 从 Git 读取，`3efba88c…` digest 为 `508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684`，`19097bde…` 为上面的 `c6e92e…`；digest/canonical set equality 都是 false，虽然旧 source 是 main ancestor。因此需要当前 Catalog 的 Mac RC。`release-rc.yml` 的 workflow_dispatch 无 inputs、仅从 protected main 的 `github.sha` 生产；version0.1.0/build3已有 nonexpired `arkdeck-rc-0.1.0-3`，相同 build 的 dispatch 会 green skip。本轮 build 4 的版本增量通过官方 `release_version.py bump-build` 同步 App 和两个 helper 的版本副本；Root 需先合入 Trace CRLF 修复，再合入版本增量，使 push trigger 从包含修复的 protected main 生产一次新 RC。若需明确 dispatch，其精确命令是 `gh workflow run release-rc.yml --ref main --repo ArkDeck/ArkDeck`，不带 `-f`、不指定任意 source。adapter 本身不执行 bump、dispatch 或 publish。

## Root 单次 preflight 入口

用户提供可访问且已核验身份的 **Mac SSH endpoint/port/已有授权账户认证方式**；账号/密钥只通过其既有安全配置供 Root 使用，不写入本材料。用户只接 DAYU200 到固定 USB（或交付一块由 published profile 实际核验的 compatible board），按提示插拔；所有安装、配置、CLI 验收和产品读回由 Root 接手。用户无需逐条运行下面的命令。

Root 准备真实发布 CLI/daemon 和该 config 后，远程会话中一次执行：

```sh
python3 -B entry.py preflight --config /private/tmp/mac-pair-config.json --execute
```

它串行采集 fixed facts、complete Job+Agent ledgers、physical candidates/target/availability，并复用主仓 fixed-facts/Catalog/Raw-integrity 判据，匹配实际 image hashes、同 target/revision/ready binding。只读确认需要 native、HDC、物理连接与普通 target adoption 的实际条件，输出本机 preflight 分类和四个 operation 的真实 availability。未接管时 Root 消费刚取得的 actual candidate/observation/generation 经 typed target adopt，再刷新 preflight；不会要求用户代跑。某个非 GJ1 operation unavailable 会报告 false，保留其实际 reason 供 Root 修复，不为它声称 GJ2/GJ3 ready。这个命令不运行 device operation，也不发 PASS；通过后 Root 继续下面的完整串行路线。

完整 preflight 的两端均取得新的 `runtime service status`，要求 installed/loaded/socketPresent/ready 全为 true、diagnostics 为空、daemonPath/whole SHA 等于配置且 daemonHealth 为当前 Catalog 的 ok。原有 `scripts/ci/installed_rust_ui.py` 的只读 native verifier 提供 launchd PID、active Mach endpoint、`proc_pidpath` 和 PID 动态 codesign/CDHash 校验；`proc_pidinfo(PROC_PIDTBSDINFO)` 提供同账户的精确 PID/start 秒与微秒。对该公开 status 指定的私有 Unix socket 只建立连接读取 `LOCAL_PEERPID`，不发送任何 IPC frame；peer 必须就是该 PID。socket inode、process birth、映像路径在每次 native read 前后不变，两个端点的完整 native tuple 也必须相同。仅允许固定 `launchctl print`、`lipo -archs`、codesign 只读参数；不读取 Runtime 私有 JSON、凭据或 Journal，不调用无 `--job` 的 verify，不创建 observe Job。kernel/动态签名字段不可读或缺失时停止；本机 Windows 的纯测试不构成实际 Mac native proof。

## 可直接执行的首段

以下每次只有一条 published CLI argv，stdout/stderr 原始 bytes 保留在 private Raw；控制台不打印 envelope。没有 `--execute` 不触碰 config/host。先运行 fixed facts，逐条检查真实结果，不能把某条失败当成 ready：

```sh
python3 -B entry.py capture --config /private/tmp/mac-pair-config.json --step facts.version --execute -- --version --output json
python3 -B entry.py capture --config /private/tmp/mac-pair-config.json --step facts.service --execute -- runtime service status --output json
python3 -B entry.py capture --config /private/tmp/mac-pair-config.json --step facts.health --execute -- runtime health --output json
python3 -B entry.py capture --config /private/tmp/mac-pair-config.json --step facts.hdc --execute -- runtime hdc status --output json
python3 -B entry.py capture --config /private/tmp/mac-pair-config.json --step facts.tools --execute -- runtime tool list --output json
python3 -B entry.py capture --config /private/tmp/mac-pair-config.json --step facts.doctor --execute -- doctor --deep --require-healthy --output json
python3 -B entry.py capture --config /private/tmp/mac-pair-config.json --step facts.operations --execute -- operation list --output json
python3 -B entry.py capture --config /private/tmp/mac-pair-config.json --step fresh.jobs.p1 --execute -- job list --page-size 1000 --output json
python3 -B entry.py capture --config /private/tmp/mac-pair-config.json --step gj1.candidates --execute -- device candidates --output json
```

完整 job census 的后续 cursor 从实际 response 逐页读取，必须 snapshot 一致、页齐全、无在途/unknown/HAR 才交接/下一 mutation。`target adopt` 只在实际 candidate 未接管时消费其 fresh candidate/observation/generation；target ID、revision、lease、Job/Artifact IDs 都从当前 captured projections 取得，不从此文猜测。

## 剩余可执行 route 与硬门

继续主仓 `docs/design/cli-golden-journey-headless-runbook.md` §§2–4 及 unchanged `scripts/gj_record` 判定。Root 将每条命令作为 `entry.py capture ... --execute -- <published argv>` 输入；它限制命令/option vocabulary，拒绝 socket/capability/reviewed-plan/request-file/任意 operation/signing/flash/raw shell。Runtime 仍完整拥有 trust/materialized-plan/capability authority。当前 adapter 不替 Root 校验每个 fresh projection 或完成下面产品路线，不能靠它的 exit0宣告这些门已过：

1. GJ-1：observe.device@1、设备级 capture.diagnostics@1、typed restart/durable reads、真实断连 HAR/重插/resume。所有 run 带实际 execution ID、`--maximum-wait 5m|10m --timeout 11m --output json`。HAR only 同 owner 的 fresh status/show/resumeReference；unknown 无新 dispatch。
2. GJ-2：同 Catalog 的实际 GJ-1 PASS + fresh target/binding/availability、完整 ledger；exact HAP import/inspect/whole-read，debug.hap@1 cleanup/stopped → same-HAP retained/running preflight → app-scoped capture.diagnostics@1（10s/HiLog/UI/ohos Trace/8192KiB/128MiB）→ complete products → typed restart → 同 closed IDs/whole bytes durable readback。每次 device launch 的 `--expected-binding-revision` 与实际 receipt/fresh target 一致。输入 JSON 的 bundle/ability/deployed digest 必须来自冻结 HAP metadata，lease 只从真实 inspection 来。
3. GJ-3：完整新 GJ-2、actual ARMv7 installed process/load、native operation availability、fresh helper census/doctor；exact candidate import/inspect/whole-read → native forward deployment/full reports/atomic publish/restart/hashProcessAndMaps；exact ghost import/inspect → **post-publication** known loader failure → Runtime autoRollback/full restored hash/process/residue。ghost 的 link-only dependency 不安装，不 raw 删除板上文件来制造故障。native run 输入保持原 `restartAbility/hashProcessAndMaps/autoRollback` 和真实 lease/targetBundle/logical name。adapter 在 native run 前要求 protected source 的 recorder rollback pin 已采用 `01d4e785…`；不临时 override 旧判据。

published wait 为 `job wait --job <actual-id> --timeout 11m --output json`，没有 `--maximum-wait`。每个 launched Job 都读 status/show/all timeline pages/result/evidence/all inventory pages，并对每个 published Artifact 用实际 owner/ID/offset `artifact read` 读到 EOF；摘要、长度、绑定与产品 provenance 必须相符。没有缺失必选产品、partial inventory、unknown、residue 或 foreign bytes 的放宽路径。

intent 在实际调用前 CREATE_NEW；known exit 或 unknown/noReplay outcome 另行 CREATE_NEW。语义 ID 已尝试就拒绝重复；缺 outcome、outer timeout 或任何 nested unknown 阻止新 mutation。partial streams 和原 capture 一直保留。capture 异常或进程崩溃会留下独占锁；该目录后续 capture（包括只读）都在 runner 前拒绝，不能删除锁、按 PID/时间自动回收或换目录绕过 unknown。Root 先只读检查已保留的 bytes；另开诊断窗口也只能使用独立审阅的只读 route，不能据此重新运行原意图或开启新 mutation。此 adapter 一次执行一条，Root 只在已检查结果后串行继续；不提供 auto-retry、recovery、capability 或 evidence admin。

最后使用同一主仓判定器，在其 `scripts` 目录：

```sh
python3 -B -m gj_record assemble \
  --out /private/tmp/arkdeck-gj-headless-20261006 \
  --date 2026-10-06 --runtime-source-revision ACTUAL_FULL_PROTECTED_MAIN_SHA \
  --record /absolute/new-redacted-macos-record.json \
  --journey GJ-1 --journey GJ-2 --journey GJ-3
```

Root 检查实际四态/完整判据，不以 assembler process exit 或 preparation success 推导 PASS。Mac 完成后 Windows 使用**同一三份 bytes**和选择，各自真实验证 publication/rollback；两机记录一起 review。

## Local targeted checks

`python -X utf8 -B -m unittest -v test_entry`：当前主仓入口 18 个 fake-runner/source-only tests，exit0（1.771s）；Mac 外置目录运行测试时指定 `ARKDECK_MAC_ENTRY_TEST_REPO=/absolute/clean/ArkDeck`。覆盖原 10 项检查及 ready/health/image 不匹配零 native read、live PID/endpoint、动态签名失败、kernel owner/birth/完整读取、socket peer/复用 PID/文件/endpoint 漂移拒绝、native host 命令白名单、完整只读 preflight 两端 instance 一致且无新 Job。原 `publication-checks-20261006.json` 与日志的 10 项结果属于旧冻结准备版本，不代表本次修改；旧 `wt` 文件和 SHA 保留。没有实际 Mac、installed image、SDK、Runtime、设备或 Cargo/dotnet；真正 native API、codesign PID 和实际 service socket 必须在获授权 Mac 窗口执行验证。

## CI

本机独立 source helper 尚未 push/CI；packet 由 Root 集成 normal adoption PR。最近 Mac RC CI 成功仅是环境线索，不能当本轮 GJ pass。

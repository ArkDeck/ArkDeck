# TR-001 trace probe/minimal-capture runbook(CHG-2026-021 / TASK-TR-001)

人类维护者亲手执行;Agent 只起草本 runbook/harness、事后核验与起草 evidence,零设备
命令(REQ 同 M0B/CHG-008 人工执行模型)。全部设备命令只经 `capture.py` 的封闭
allowlist 执行(信任链复制自 `scripts/m0b_capture`:argv 数组无 shell、逐流
byte-exact + SHA-256、敏感自检、full/redacted 双 manifest + 输出侧 redaction 门、
输出目录强制仓库外)。**harness 拒绝的命令没有手工兜底**——被拒即停,如实记
blocked-attempt。

两道 capture 门(本 harness 相对 m0b 的新增,均为机械强制):

1. **默认 probe-only**:`--commands capture` 的 device-write 序列必须显式
   `--allow-device-write`;
2. **help-anchored gate**:capture 必须 `--gate-dir` 指向**同窗口** probe run 的
   out-dir;harness 重读已采集的 hitrace help/tag 字节,要求 capture argv 用到的
   `-t`/`-b`/`-o` 与 `sched` tag 逐一有据。任一缺失即拒——预声明的 capture argv
   只能由设备自己的 help 面授权,不允许现场改 argv。

## 身份门(窗口开始前)

- hdc = DevEco toolchains 路径;`shasum -a 256 <hdc>` 必须 =
  `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`,`<hdc> -v` =
  `Ver: 3.2.0d`(M0B/I15 pinned tuple;harness 亦记录 hdcSha256 进 manifest)。
- 设备 = DAYU200(OpenHarmony 7.0.0.34,M0B evidence 在案),正常系统态 USB 连接。
- 窗口独占:与 M0B-002、chg-008 Phase B 等其他设备任务不同窗口(可同日先后)。
- out 根目录:仓库外新建(如 `~/tr001-capture/<date>/`),harness 强制校验。

## Phase P — 探测(read-only;先跑,产物是 capture 门的授权依据)

```
python3 capture.py --hdc "<HDC>" --out-dir ~/tr001-capture/<date>/probe \
  --target "$(<HDC> list targets | head -1)" --commands probe
```

采集:`hdc-list-targets(+-v)`、`hitrace --help`/`-h`/`-l`、`bytrace --help`/`-h`/`-l`。
预期与判定:

- help 可能是 usage 文本,也可能是 error-line-with-exit-0(M0B hidumper 教训)——
  两种都是有效观察,原样落盘;bytrace 不存在(`not found` 类输出)同样是有效观察;
- 逐流自检必须 PASS(user path/key material 零命中);
- 操作者过目 probe 输出(本地终端可看;不回贴原文,回贴 redacted manifest 即可)。

## Phase C — 最小采集(device-write;仅当 gate 通过)

```
python3 capture.py --hdc "<HDC>" --out-dir ~/tr001-capture/<date>/capture \
  --target "<同一 connectkey>" --commands capture \
  --allow-device-write --gate-dir ~/tr001-capture/<date>/probe
```

固定序列(全部 fixed literal,owned 面 = `/data/local/tmp/arkdeck-trace/`):
mkdir → stat(pre)→ `hitrace -t 5 -b 2048 sched -o …/minimal.ftrace` → stat(post)
→ `file recv` 到 out-dir → rm(精确文件)→ stat(absent 复查)→ rmdir(空目录才
成功)。

- gate 失败(help 无 `-t`/`-b`/`-o` 或 tag 表无 `sched`):**STOP**,记
  blocked-attempt——这是"该 build 的 hitrace 面与候选 argv 不符"的一手事实,交
  Agent 起草 registry 修订,不现场换 flag/换 tag;
- capture 为 deviceMutation 级(写 owned tmp 文件;不 set 任何参数、不碰
  已有分区/数据);任何非序列内输出形态 → 停手保留现场;
- recv 后的 `minimal.ftrace` 留在 out-dir(仓库外 0600);其内容(进程名等设备侧
  信息)不回贴、不入仓——registry/golden 的入仓由 TR-001 evidence PR 经维护者
  逐字审读 merge 构成认可。

## 收档(贴回给 Agent)

- 两个 run 目录的 `redacted-manifest.json`(可安全贴回;full manifest/原始流/
  ftrace 留仓库外);
- 终端摘要行(capture complete: N commands…);
- 异常/中止的现场描述。

Agent 据此起草:trace probe/golden registry(exact argv、help family、成败
marker、raw ftrace 头形态、hash closure)、OPENHARMONY-TOOLS/lock bump、
`evidence/runs/TASK-TR-001/run.md`。**本 runbook/harness 合入不改 tasks.md 状态**
(先例 #56:runbook 是交付物,非 completion;TR-001 保持 ready 等窗口)。

## 自测(host-only,交付前已跑)

```
python3 -m unittest scripts/trace_capture/test_capture.py -v
```

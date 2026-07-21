# TR-001 trace probe/minimal-capture runbook(CHG-2026-021 / TASK-TR-001)

人类维护者亲手执行;Agent 只起草本 runbook/harness、事后核验与起草 evidence,零设备
命令(REQ 同 M0B/CHG-008 人工执行模型)。全部设备命令只经 `capture.py` 的封闭
allowlist 执行(信任链复制自 `scripts/m0b_capture`:argv 数组无 shell、逐流
byte-exact + SHA-256、敏感自检、full/redacted 双 manifest + 输出侧 redaction 门、
输出目录强制仓库外)。**harness 拒绝的命令没有手工兜底**——被拒即停,如实记
blocked-attempt。

三道 capture 门(本 harness 相对 m0b 的新增,均为机械强制):

1. **pinned tool**:每次 invocation 都先计算 HDC SHA-256,漂移即在任何 HDC dispatch
   前拒绝;同窗口 probe 的 `hdc -v` 字节还必须包含 pinned `Ver: 3.2.0d`;
2. **默认 probe-only**:`--commands capture` 的 device-write 序列必须显式
   `--allow-device-write`;
3. **manifest-anchored gate**:capture 必须 `--gate-dir` 指向**同窗口** probe run 的
   out-dir;harness 重验完整 manifest、HDC path/hash、同一 target、封闭 probe 序列、
   逐流 size/hash 与敏感自检,再要求 hitrace help/tag 字节对 capture argv 用到的
   `-t`/`-b`/`-o` 与 `sched` tag 逐一有据。任一缺失即拒——预声明 argv 只能由
   设备自己的 help 面授权,不允许现场改 argv或拿旧目录/另一设备的 probe 代替。

## 身份门(窗口开始前)

- hdc = DevEco toolchains 路径;`shasum -a 256 <hdc>` 必须 =
  `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`。版本
  `Ver: 3.2.0d` 由 Phase D/P 的 allowlisted `hdc-version` 捕获并在 capture gate
  重验;不要在 harness 外另跑 `hdc -v`。
- 设备 = DAYU200(OpenHarmony 7.0.0.34,M0B evidence 在案),正常系统态 USB 连接。
- 窗口独占:与 M0B-002、chg-008 Phase B 等其他设备任务不同窗口(可同日先后)。
- out 根目录:仓库外新建(如 `~/tr001-capture/<date>/`),harness 强制校验。

## Phase D — 发现(read-only;不得用 harness 外命令替代)

```
python3 capture.py --hdc "<HDC>" --out-dir ~/tr001-capture/<date>/discover \
  --commands discover
```

操作者只在本地查看 `discover/01-hdc-list-targets.stdout` 与 verbose 对照,物理确认
唯一 DAYU200 后手工复制该 connectkey。不要使用 command substitution、pipeline 或
额外 `hdc` 命令取 target;零/多设备、Unauthorized、身份不确定均 STOP。

## Phase P — 目标绑定探测(read-only;产物是 capture 门的授权依据)

```
python3 capture.py --hdc "<HDC>" --out-dir ~/tr001-capture/<date>/probe \
  --target "<operator-confirmed-connectkey>" --commands probe
```

采集:`hdc-version`、`hdc-list-targets(+-v)`、目标绑定的
`hitrace --help`/`-h`/`-l` 与 `bytrace --help`/`-h`/`-l`。
预期与判定:

- help 可能是 usage 文本,也可能是 error-line-with-exit-0(M0B hidumper 教训)——
  两种都是有效观察,原样落盘;bytrace 不存在(`not found` 类输出)同样是有效观察;
- 逐流自检必须 PASS(user path/key material 零命中);
- 操作者过目 probe 输出(本地终端可看;不回贴原文,回贴 redacted manifest 即可)。

## Phase C — 最小采集(device-write;仅当 gate 通过)

```
python3 capture.py --hdc "<HDC>" --out-dir ~/tr001-capture/<date>/capture \
  --target "<同一 operator-confirmed-connectkey>" --commands capture \
  --allow-device-write --gate-dir ~/tr001-capture/<date>/probe
```

固定序列使用 harness 生成的 canonical UUID owned 面
`/data/local/tmp/arkdeck/<uuid>/minimal.ftrace`:mkdir → stat(pre)→
`hitrace -t 5 -b 2048 sched -o <owned-file>` → stat(post)→ `file recv` 到 out-dir
→ 仅在 received file 非空、未截断且敏感自检通过后 rm(精确文件)→ stat(absent
复查)→ rmdir(空目录才成功)。UUID/path 由 harness 生成,操作者不可提供。

- gate 失败(help 无 `-t`/`-b`/`-o` 或 tag 表无 `sched`):**STOP**,记
  blocked-attempt——这是"该 build 的 hitrace 面与候选 argv 不符"的一手事实,交
  Agent 起草 registry 修订,不现场换 flag/换 tag;
- capture 为 deviceMutation 级(写 owned tmp 文件;不 set 任何参数、不碰
  已有分区/数据);任何非序列内输出形态 → 停手保留现场;
- receive 缺失/空/截断/敏感自检失败时,harness 不 dispatch rm/rmdir,manifest
  记录 `partialRemoteRetained`;不要手工清理,按 blocked/partial attempt 收档;
- recv 后的 `minimal.ftrace` 留在 out-dir(仓库外 0600);其内容(进程名等设备侧
  信息)不回贴、不入仓——registry/golden 的入仓由 TR-001 evidence PR 经维护者
  逐字审读 merge 构成认可。

## 收档(贴回给 Agent)

- 三个 run 目录的 `redacted-manifest.json`(可安全贴回;full manifest/原始流/
  ftrace 留仓库外);
- 终端摘要行(`capture recorded: ... outcome=...`);
- 异常/中止的现场描述。

Agent 据此起草:trace probe/golden registry(exact argv、help family、成败
marker、raw ftrace 头形态、hash closure)、OPENHARMONY-TOOLS/lock bump、
`evidence/runs/TASK-TR-001/run.md`。**本 runbook/harness 合入不改 tasks.md 状态**
(先例 #56:runbook 是交付物,非 completion;TR-001 保持 ready 等窗口)。

## 自测(host-only,交付前已跑)

```
python3 -m unittest scripts/trace_capture/test_capture.py -v
```

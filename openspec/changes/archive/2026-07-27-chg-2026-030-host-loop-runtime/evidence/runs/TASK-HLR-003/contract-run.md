# TASK-HLR-003 Contract Run — corrective hardening after adversarial review

- Date:2026-07-25（Asia/Shanghai）。
- Executor:`agent`。
- Base:protected `main` `e32cdaba9f465fc2e264f8b61ad135efab3487a8`（`readiness(TASK-BRC-001): pin supply-chain decision inputs (#537)`）。
- Branch:`agent/task-hlr-003-corrective`。
- Classification:`contract`,host-only/offline;零真实设备、HDC、credential、
  identity/secret/scheduler、Issue/ref/lease、网络/API 或外部副作用。全部命令为
  仓内 Python standard library 单元测试与本地静态检查。
- Task state boundary:本 implementation/evidence run **不翻** `ready→done`。
  HLR-003 完成另有独立 completion PR,且见下方 Blocker 一节 —— 在 `tasks.md`
  补齐 `Decision-Grade` 之前,循环认领不到任何任务,HLR-003 不具备 done 条件。
- Authorization:第三个 D0 source PR 由维护者在本会话内显式授权(readiness r2
  原文只授权"一个 D0 source PR 交付 worker 的可执行入口与生产后端接线",#524 与
  #531 已消耗该额度;本 PR 超出 r2 明面范围,凭该显式授权推进)。

## 起因

针对 #524/#531 合入内容的第三轮对抗 review 提出四个 HIGH。前两轮的修法是逐点
打补丁,而同一位置反复产生同类缺陷:

- r1:required check 只按名字判定存在,`skipped` 计为成功 → 从未真正执行的
  required check 读作绿,production 里 check dispatch 从不触发。
- v3:上述修复把 `success` 做成同名下的吸收态 → 同名的已执行失败被吞掉,而
  `pull_request: edited` 那一次 run(r1 修复存在的全部理由)反而永远无法让轮次失败。

review 的结论是不要再逐点补,而是把"required check 判定"与"cursor 一致性"各自
当作需要穷举状态表的契约来写,并且先补测试再改代码。本 run 照此执行。

## Deliverables

### 两份穷举状态表契约(先写测试,确认为红,再改代码)

- `scripts/host_loop/test_check_verdict_contract.py`(23 tests,改码前 20 红):
  枚举 GitHub 全部 documented conclusion × status × 同名多 run × required/
  non-required 划分。两条不变量:**FAILURE DOMINATES**(required 名下任一已执行
  失败即定论,与到达顺序无关,含全排列验证)、**NO ASYMMETRY**(把 check 列为
  required 只能让门更严,绝不出现同一组 conclusion 在 required 上绿而在
  non-required 上红)。
- `scripts/host_loop/test_cursor_contract.py`(19 tests,改码前 13 红):区分
  **corruption 致命 / staleness 永不致命**。cursor Issue 自身 docstring 称其为
  "rebuildable cache" 且"explicitly NOT a single source of truth",而不能由 Truth
  重建的 cache 就是 source of truth。

### 实现

- `scripts/host_loop/worker.py`:`required_verdicts`/`classify_checks` 重写为
  failure-dominant 且与顺序无关;轮次**终局** cursor 写补上 fence 门 —— 它原先的
  保护继承自上方 dispatch 分支,而 required checks 已绿时该分支整段跳过,于是
  fence 已被夺走的 worker 仍会把自己陈旧的 lease OID 盖到真正持有者之上。
- `scripts/host_loop/cursor.py`:新增 `reconcile(state, truth)`,逐字段从 Truth
  重导航缓存并**报告**其修正(静默纠正会掩盖真实异常);`rebuild_and_validate`
  委托之,不再因陈旧抛错。`store()` 删除 `human_prefix` 参数,改为从既有正文自动
  保全标记外文本。
- `scripts/host_loop/transport.py`:`check-runs` 分页读尽 —— 该端点默认单页上限
  30,只读第一页会隐藏第 30 名之后的任何红 check,方向恰是最坏的假绿。
  `total_count` 为 deny-on-unreadable 且必须全程自洽;短页即末页为主控终止条件。
  路由**替换**而非新增,allowlist 仍为 10 条(与 `pulls` 只登记其分页形态一致)。
- `scripts/host_loop/lease.py`:`validate()` 显式排除 bool。
- `scripts/host_loop/__main__.py`:tasks.md 解析三处修复,见下节。

### 六条把缺陷本身锁成契约的旧测试

`test_worker_cursor.py` 有六条测试断言"cursor 陈旧即致命"。由于调和是每轮的第一
条语句而 cursor 写在其后,该契约使**一次掉写永久卡死**该任务:cursor 写从此为 0,
缓存再也追不上。这六条已反转为断言调和与恢复。

## 与真实文件比对发现的三处解析缺陷

拿 #531 合入的解析器实跑真实 `openspec/changes/chg-2026-030-host-loop-runtime/tasks.md`,
8 个任务全部得到 `status='done（2026-07-23'`、`grade='unknown'`:

| # | 字段 | 真实文件 | 原解析结果 | 方向 |
| --- | --- | --- | --- | --- |
| ① | `Status` | `- Status:ready（r2 corrective…`(值后紧跟全角括号,无空格) | `'ready（r2'` | fail-closed |
| ② | `Decision-Grade` | **0 处**(字段在 tasks.md 中根本不存在) | `'unknown'` | fail-closed |
| ③ | `Hardware required` | `no。`(8/8) | `False`,且 `.lower().startswith("yes")` 把 `是`/`必需` 读作"不需要硬件" | **fail-open** |

①③ 已修:字段取值在空白**或**真实文件所用标点处终止;hardware 词表两向封闭并
纳入 CJK 拼法,缺失或不可判定即省略该任务。②见下方 Blocker。

原 docstring 声称"字段解析不出就省略而非默认" —— 对 grade 成立,对 hardware 为假;
已改为与代码一致。

既有测试为何一条都没抓到:`test_backends_cli` 里每个 fixture 都省略这两个字段,
而唯一读真实文件的测试只断言 task_id 出现过,从不断言解析出的**值可用**。
`test_discovery_contract.py`(18 tests)直接对真实文件断言。

## 一并清理

- 删除 `cursor.record_lease_write`。在其单一调用点上它是空操作:
  `_persist_cursor` 的 `record_round` 用同样的值重写它刚设的每个字段并自行
  `validate()`。却有两条测试覆盖它,使这个死步骤看起来在承重 —— 与 review 已两次
  指出的"写了守卫却没接线"同型。"畸形 OID 不得进入 cursor"这条性质保留,改指到
  真正在路径上的 `record_round`。
- git push 的真实并发竞争(`fetch first` / `cannot lock ref`)归入 fence loss 而非
  `PolicyRefused`;后者让操作者去修一个从来不是问题的 ref policy。

## 第二轮:推送前的 7 视角对抗复核(v4)

推送前又跑了一轮对抗复核(7 个独立视角,每条 finding 再由一个以驳倒为默认立场的
refuter 复验)。**18 条经复验成立**,其中一条 HIGH 落在与 r1、v3 完全相同的函数上
—— 第三次。

- **HIGH**:`required_verdicts` 没有从 `success` 回到 `pending` 的路径,于是同一
  required 名下**尚未结束**的兄弟 run 毫无贡献:`[guard success (push), guard
  in_progress (edited)]` 读作 **green**、`unsatisfied` 为空,并因此**压掉了
  re-dispatch**。这恰是一次 dispatch 之后的常态(edited 的 `allowed-paths` 很快
  返回,而 edited 的 `guard` 要跑完整个 `check-sdd.sh`),而那个仍在跑的 run 正是
  唯一可能与 push 那次不同的一个(`pull_request` checkout 解析的是 merge ref)。
  它同时**违反本次改动自己声明的 NO ASYMMETRY**:非 required 侧另有独立 `pending`
  累加器,所以把 check 列为 required 反而让门更松。
  修法不是再补一个分支,而是让分类变成全函数:单一 `_run_state` 同时驱动两侧,走
  failed > pending > success 三档格,一个名字只有在"至少一次执行成功**且**没有任何
  一次仍在阻塞"时才算满足。
- 我的契约表**把该缺陷冻结成了正确行为**(`test_a_not_executed_sibling_does_not_
  satisfy_alongside_a_success` 断言那一格为 success)。已拆分为良性
  (`skipped`/`neutral`)与畸形(completed 但无 conclusion),并把 NO ASYMMETRY 改为
  对**兄弟对的完整交叉积**断言 —— 单 run 版本对此结构性失明。
- 轮次的**第一次**外部写此前无门:`_prepare_branch` 推送共享 task 分支,而门在其
  下一行。已加门,并配行为测试(在获取与推送之间偷 fence;先前那版钩住第一次 API
  调用,而那已在推送之后,所以它是因错误的理由失败)、AST 源序测试与 happy-path
  孪生测试。
- `reconcile()` 的 corrections —— 把陈旧判定放松之后**唯一**的补偿控制 —— 在其
  唯一生产调用点被丢弃,于是任何 cache/Truth 分歧都是静默的。现已接入
  `RoundResult.detail`。
- ref push 的分类优先级是反的:`cannot lock ref` 压过 `[remote rejected]`,ruleset
  拒绝会被洗成 fence loss。现为 lease 专有措辞 → policy → 通用竞争措辞。原测试是
  源码 grep,窗口把分支上方的注释也框了进去,所以从**条件**里删掉该子句它照样绿;
  已改为驱动真实 `_push`。
- discovery 另有三处 fail-open:`- Depends on:` 缺失塌成 `()`,使依赖门形同虚设;
  `_GAP` 原为 `\s*`(`\s` 匹配换行),空字段会捞到下一行正文的第一个 token,足以
  从一句说明文字里**凭空造出可派发的 D0**;节切分不识别代码围栏,fenced 示例里的
  `## TASK-…` 会造出候选,更糟的是往 `done_task_ids` 注入伪造 id —— 而那正是依赖门
  查询的集合。`build_truth` 的 lease `ls-remote` 同样 fail open(同一函数的 PR 半边
  早已 re-raise)。
- `CursorState.validate` 缺少已加给 `LeaseRecord.validate` 的 bool 闸门,另有三个
  字符串字段未校验。check-run 完整性只按计数判断,页在两次请求之间移位会得到"重复
  一条 + 丢掉一条"却满足所有闸门的视图;现按 run id 唯一性校验。路由 guard 只钉了
  `len(ALLOWED_ROUTES)`,所以本次的路由替换对它是隐形的;现已钉定精确内容,并改掉
  transport.py 中"由 route-inventory 测试钉定"的错误说法(那个测试从未断言过它)。

### 我在上一轮写下的四条不实陈述,按实测更正

| 我的原话 | 实测 |
| --- | --- |
| "worker 的 `status == \"ready\"` 门永远不可能为真" | 不存在这个门。两处活的门都是前缀判断(`startswith("ready")` / `startswith("done")`),每个被截断的值都仍能通过对应那个 —— 值截断**什么都没阻断**,是潜在隐患而非故障 |
| "全部 8 个任务 status='done（2026-07-23'" | 旧解析器产生 **6** 个不同取值,该值只对应 **1** 个任务 |
| "三个缺陷里两个各自独立致命" | 只有一个致命:`Decision-Grade` 缺失。而它不该由解析器修 |
| "test_backends_cli 里每个 fixture 都省略这两个字段" | 有一个在本次改动之前就声明了 `Hardware required` 并断言其解析值 |

## Offline commands and results

| Command | Result |
| --- | --- |
| `python3 -m unittest discover -s scripts/host_loop -p 'test_*.py'` | 369 tests OK,1 expected failure(见 Blocker) |
| `python3 scripts/test_check_pr_paths.py` | 24 tests OK |
| `ARKDECK_PYTHON=… ./scripts/check-sdd.sh` | exit 0;`0 error(s), 0 warning(s), 111 acceptance IDs` |
| `check_pr_paths.py --event <本 PR 形状>` | `PASS; task=TASK-HLR-003; changed_paths=13`;反证对照(标题无 task token)如实 exit 1 |
| 变异扫描(34 个真实变异 + 2 个对照) | 34/34 KILLED;正对照 KILLED、负对照 SURVIVED,harness 有效 |
| 对抗复核 | 7 视角 + 每条 finding 独立 refuter;18 条成立并已修,7 条被驳回 |

变异 harness 的三条硬规矩各由一次无效跑换来,均已内建为拒跑条件:原地变异不复制
目录(复制破坏 `REPO_ROOT` → 全报 KILLED);基线红拒跑;锚点缺失拒跑(空扫描)。
带正负对照,任一不符则整轮作废。

## 自查发现并如实记录的偏差

1. 我的第一版 HIGH ③ 测试断言"一次 issue 写都不许有",失败原因是偷租约**之前**
   存在两次握着 fence 的合法写。断言已收紧为"偷取时刻之后无写"+`pr_head` 那次
   特定写缺席,并配 happy-path 孪生测试,免得负向断言空过。
2. 一个变异(`total_count` 类型闸门)首轮存活:`assertRaisesRegex(…, "total_count")`
   被下游另一个也含 `total_count` 的报文匹配上,测试因错误的理由通过。已钉住类型
   闸门自身的可区分措辞。同类先例:`len(writes) > 1`。
3. 另有两处缺陷是在写这些测试的过程中查出的,不在 review 的四个 HIGH 之内:
   `isinstance(x, int)` 不排除 bool(`True` 是 int 且 `True >= 1`),故
   `"fence": true` 被当作 fence 1 接受 —— 与真 fence 1 比较相等、递增得 2,类型
   混淆升级为 fence 冲突;`store()` 的 `human_prefix` 参数零调用点,导致每次写入
   都抹掉维护者写在 cursor Issue 里的正文。
4. `reconcile` 在 lease 已被他人持有时,会把**对手的** ref OID 刷进 cursor 的
   `lease_oid`。已核验其不构成授权影响:AST 扫描确认轮次内 `cursor_state` 的属性
   读取为 0 处(cursor 在轮次中只写不读),`record_round` 覆盖 8 个字段中的 7 个,
   唯一从缓存存活的 `review_run` 零消费点,而 fence 一律由 `assert_still_held`
   比对 ref 记录裁定。作为共享人读面的记录精度问题如实登记。
5. 环境事实更正:`gh` 当前以 `lvye` 身份登录(scopes `repo`/`workflow`/`admin:org`),
   与此前记录的"agent 的 gh 失能"不符。本 run 未用它执行任何写操作 —— PR 仍由
   `agent-pr.yml` 以 `github-actions[bot]` 身份开启,以保住 producer/reviewer 分离
   (GitHub 禁止 PR 作者批准自己的 PR)。

## Blocker —— 本 PR 不解决,且不该由本 PR 解决

`tasks.md` 全部 8 个任务都没有 `- Decision-Grade:` 行,故所有 grade 解析为
`unknown`、不在 `DISPATCHABLE_GRADES` 中 → **循环目前认领不到任何任务**。

这不是解析器该修的:声明一个任务的决策等级是人的判断,在 reader 里默认成 `D0`
等于它自授权它被明确写明不该拥有的权限。因此该断言写成真话并标
`@unittest.expectedFailure`,补齐字段后会报 "unexpected success",逼人摘掉标记,
而不是让一条陈旧的 skip 把修复藏起来。

需要维护者逐任务补写该字段。在此之前 HLR-003 不具备 `done` 条件。

## 边界声明

- CI 绿 ≠ 批准。唯一批准事实 = 维护者 review 并 merge 受保护 `main`。
- 本 run 不含 live first-event evidence(属 HLR-005),不构成 HLR-004 reviewer
  循环的任何交付,不翻任何任务状态,未触及 identity/secret/scheduler。

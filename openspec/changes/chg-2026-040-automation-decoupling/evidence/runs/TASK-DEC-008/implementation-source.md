# TASK-DEC-008 implementation run — source scope only

- Task:TASK-DEC-008(minter 脚本修复与部署副本重装)
- Executor:agent(会话实现;never-claim,循环零认领)
- Date:2026-07-27
- Readiness:r1(source-only;**不授权 done 翻转、不授权任何系统写入**)
- Implementation base:`ad6a4ab`(= TASK-DEC-002 done 翻转 #648 合入后的 main)
- Hardware:no。**`/Library/**` 零触碰、零 `sudo`、零 launchd 动作、
  GitHub 零写入。**

## Input gate 复核

r1 三个 pin 在实现 base 上**逐一 HOLD**:
`mint_installation_token.sh` blob `4150401c5f875ac282d38d6f70eb4c0c35f97689`
/ sha256 `5b8cbc06e7246c83c273f37dd78b07c2eca1e91b541cc88532c9f3c6f5cd9671`
(**该 sha256 同时是部署副本的现装 digest 与回滚目标**);
`test_minter_and_explain.py` blob `cc1e8a8aa3d7df0262f41cf44735275c2248b6c9`。

## 交付

- **D-M4(trap 覆盖 + 变量预初始化)**:trap **在第一个临时文件创建之前**
  安装,`response`/`status_file`/`curl_err`/`staged`/`staged_meta` 五者
  预初始化为空并全部进入 `cleanup`(用 `${var:+"$var"}` 以兼容 `set -u`
  与空值)。修复前:trap 装在两个响应文件**之后**且只清理这两个,于是
  ①第二个 `mktemp` 失败会漏掉第一个;②**写入 token 之后、`mv` 之前的任何
  失败,会把明文 token 留在输出目录里的 `.mint.*` 文件中**。
- **D-M5(sidecar 收紧)**:新鲜度 sidecar 由 `644` + `chown "$OWNER"`
  改为 **root 属主 `600`,不再 chown**。理由是实测:该文件带
  `expires_at_epoch`,正是 **root 读取以决定是否重铸**的判据;归 `$OWNER`
  644 时,循环所用的非特权账户可以改写 root 自己的重铸决定。
  **全仓 grep 确认 sidecar 无仓内消费者**(只有本脚本读写),故收紧不断链;
  token 本体仍 `chown "$OWNER"`——循环必须能读它。
- **`--pem` 属主/权限断言**:新增 `stat` 检查,要求 root 属主且 mode
  `600|400`。密钥以路径交给 root 进程签名,任何其他账户可读或可替换它
  即等价于可以以该 App 身份签名。
- **curl 错误可见性**:`2>/dev/null` 改为写入受 trap 覆盖的 `$curl_err`,
  非 201 时把**首行诊断**(如 `Operation timed out`)并入错误消息。
  **响应体仍不打印**(4xx body 可能回引请求)。
- **尾随空值 flag 报错**:新增 `need_value`,`--pem` 之类出现在 argv 末尾
  时报 `--pem requires a value`,取代 `shift 2` 在 `set -e` 下的裸退出。

**契约保持(r1 门 4/5)**:JWT 仍只作为 **`printf`(实测为 `/bin/sh`
builtin)** 的参数经 stdin 供给 `curl --config -`,**永不进入任何外部命令
的 argv**;脚本保持单文件 `/bin/sh`、零仓内 import(既有
`test_no_python_and_no_repository_import` 对剥注释后的可执行文本断言,
保持绿);`set -eu`、`umask 077`、`PATH` 钉死均未动。

## 测试:两条弱断言按 r1 门 3 替换

- `test_every_external_command_is_a_root_owned_absolute_tool` 原文**只断言
  `PATH=` 行存在**。改为:**解析脚本实际调用的每个命令名**,在钉死的
  PATH 内解析,并断言解析到的文件 root 属主、且 group/other 不可写。
  **扫描前先清空引号内文本**——否则错误消息里的散文(`is`/`not`/`the`)
  会被当成命令(首版实测确实如此,已修)。
- `test_a_failed_mint_exits_two_and_says_the_token_is_untouched` 原文含
  `assertIn("2", self.code)`,**对任何含数字 2 的脚本恒真**。改为:每条
  带「existing token untouched」承诺的 `die` 必须以 `2` 结尾,且
  **JWT 阶段之后的每个 `die` 都必须显式退出 2**(锚点取可执行文本里的
  `b64url() {`,不取小节注释横线——`self.code` 已剥注释,锚在注释上等于
  断言一个永不存在的字符串,首版实测报错,已修)。

## 新增:注入式 fixture 真跑失败路径(r1 门 1)

`MinterCleansUpEveryStagingPath` 以**派生副本**驱动真实执行:harness 对
脚本做**恰三处替换**(root 门、PATH、PEM 属主门),**每处都断言在源文件中
恰命中一次**——脚本若改变这些行的形状,harness 会**显式失败**而不是继续
测一个已不存在的形态。其余(trap、暂存顺序、cleanup 体)是原样字节。
桩工具中 `curl` **真正解析 stdin 上的 config 并遵守其 `output =` 行**
(首版桩靠环境变量旁路告知写哪儿,不忠实,已改)。

- **正对照**:成功路径 exit 0、token 文件 600、sidecar 600、
  `$OUT_DIR` 内**零 `.mint.*` 残留**。
- **注入**:`chmod`/`chown`/`mv` 三个阶段各注入失败 → 非零退出、
  **零残留**,且输出目录中**没有任何文件含 token 字节**。

**该 harness 在 CI 不运行,原因与补偿如实记录**。首次推送 CI guard 红
(run `30261378428`):`stat: cannot read file system information for '%Su'`
—— guard job 跑在 **ubuntu-latest**,GNU `stat` 把 `-f` 读成"查文件系统",
而本脚本用的是 **BSD `stat -f`**。根因不是我引入的:脚本本就是 macOS-only
(任务卡 `Platform: macos`,部署副本在维护者 Mac 上),**但我的 harness 是
第一个真正执行到那些 `stat` 行的测试**,于是把这条平台依赖暴露到了 CI。

- **处置**:harness 类加 `@unittest.skipUnless(sys.platform == "darwin")`,
  理由写进 skip 文案。**不为跑通 CI 而给 root 执行面加 GNU/BSD 兼容分支**
  ——那会在只可能跑在 macOS 的脚本里增加分支面;也**不把 `stat` 也做成桩**
  ——它正是 PEM/目录两道安全门所用的工具,桩掉等于测桩。
- **补偿(不让 CI 变瞎)**:新增
  `test_every_staging_path_is_named_in_the_cleanup_trap` ——
  **在所有平台运行**的结构断言:五个暂存变量逐一出现在 cleanup 体内、
  trap 装在第一个 `mktemp` 之前、五者预初始化行存在。变异门实测:两条
  trap 变异现在由**结构断言与行为 harness 双双击杀**,故 Linux CI 对
  trap 回归**不失明**。
- **实测复核**:以 `sys.platform` 模拟 linux 重载模块跑全套件 =
  **44 run / 0 failures / 0 errors / 2 skipped**(恰为该 harness 两条),
  即 CI 侧转绿是验证过的,不是推断。macOS 本机则 **44 全绿含 harness
  真跑**。

## 验收

**变异门 8/8 击杀 + 负对照存活**:

| 变异 | 结果 |
| --- | --- |
| trap 退回只清两个响应文件 | KILLED |
| 从 trap 中摘掉 `staged` | KILLED |
| sidecar 退回 644 + chown | KILLED(2) |
| PEM 属主门移除 | KILLED(3) |
| PEM 权限门移除 | KILLED |
| curl 诊断又被吞 | KILLED |
| JWT 后某个 `die` 退回默认退出码 | KILLED |
| 缺值 flag 不再报出自己的名字 | KILLED |
| **负对照**:仅改注释横线 | **SURVIVED**(正确) |

**一处首轮存活,如实记录并已补测**:「缺值 flag 不报名」首轮**存活**——
我加了修复却没有任何测试驱动该路径。补
`test_a_flag_in_last_position_without_a_value_names_itself`(六个取值 flag
逐一)后击杀。同族教训(修复必须配一条会因其被撤销而变红的测试)本仓已
记录多次。

**套件**:`test_minter_and_explain.py` **31 → 44 OK**(macOS;Linux 下
42 OK + 2 skipped);host_loop `-m unittest discover` **631 → 638 OK + 1
expected failure**;
`check-sdd` **0/0/111**。既有断言除 r1 门 3 明令替换的两条外**未改一处**。

## 部署副本 digest(供 r2 起草)

| | sha256 |
| --- | --- |
| **现装 = 回滚目标** | `5b8cbc06e7246c83c273f37dd78b07c2eca1e91b541cc88532c9f3c6f5cd9671` |
| **本 PR 合入后的新字节** | `2df746cc58cf6dcf825a01f072cea4bdfffa61b706f40695c8e0531b3f2d6103` |

**合入→重装的失配期已按 r1 显式接受**:合入后仓内字节与
`/Library/PrivilegedHelperTools/com.arkdeck.host-loop.mint.sh` 立即
digest 失配,部署副本继续按旧字节运行;本轮修复全部落在故障路径与权限
收紧上,不改铸造语义,失配期内行为不退化。**失配期内回滚 = 不动部署副本、
仅 revert 本 source PR。**

## 未做(r1 明确不授权)

- **`done` 翻转**:本任务保持 `ready`。r2(窗口授权)合入前不得 done。
- 任何 `/Library/**` 写入、`sudo`、launchd 动作、对运行中 unit 的触碰。
- JWT 构造/铸造语义、App/installation id、plist、token 文件路径。
- 重装步骤逐条与窗口双面 read-back 判据:属 r2 内容,本 PR 只提供上表
  两个 digest 作为 r2 起草输入。

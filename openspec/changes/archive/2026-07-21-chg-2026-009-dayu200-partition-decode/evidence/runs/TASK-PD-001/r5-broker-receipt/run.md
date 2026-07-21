# TASK-PD-001 r5 broker-receipt remediation run record — 2026-07-20

- Evidence class:`contract`(headless synthetic vectors;零 broker 启动/GUI/
  pinned archive/device/network dispatch)
- Change:`CHG-2026-009-dayu200-partition-decode@r5`(`approved`;r5 revision PR
  #158,main `b8902b1`)
- Implementation base:`b8902b1`(r5 revision merge)
- Source revision:`b81922d9901a0319d5425737f262e82e4a6a5b6a`(三个 r5 allowed
  源文件先行提交;本 run record 随后提交)
- Acceptance:`DECODE-DAYU200-RECEIPT-CONTRACT-001` /
  `TEST-DECODE-DAYU200-RECEIPT-CONTRACT-001`(minimum evidence:`contract`)
- Canonical boundary:三项 platform AC(`DECODE-DAYU200-PARTITION/INPUT-BOUNDARY/
  RECONCILE-001`)不被本 run 满足或降级,仍归 TASK-PD-002;r4 headless done 不重判。

## Source identity

| File | SHA-256 |
| --- | --- |
| `scripts/partition_decode/macos_input_broker/main.m` | `4bb1e1cad4329d9d807a0a98744e5de04efe812360cb01a19a7b01522bc94e22` |
| `scripts/partition_decode/macos_input_broker/collect_platform_evidence.py` | `b78aca7d86b12cf7afb94e43ad5a8e3ebb7c848ba5cfc46ba917b485da3e3a72` |
| `scripts/partition_decode/macos_input_broker/test_collect_receipt_validation.py` | `b240c845a1b3df284ecde8b04bb4b13c94b7cb33371aa2b2eab48c7d6370b160` |

r5 Out-of-scope 四个 r4 decoder 文件(`decode.py`/`evidence.py`/`README.md`/
`test_decode.py`)保持 r4-done 字节,零改动(TASK-PD-002 对其 pins 不漂移)。

## Delivered behavior

1. `main.m`:四个 `sandbox_check` 派生 policy 字段(`readDenied`/`writeDenied`
   ×4 路径、`network-outbound`、`process-exec`)全部改显式 NSNumber BOOL 赋值
   (if/else + `@YES`/`@NO`),receipt 经 NSJSONSerialization 序列化为真 JSON
   `true`/`false`;全源不再含任何 `@(` int 装箱。实现形态经
   `test_decode.py::test_macos_broker_source_and_entitlements_are_closed` 的
   封闭 source 审计(headers/c-targets/receivers/selector-tokens/dot-targets
   五个面)验证零新 token——初版三元形态(`? @YES : @NO`)会向 selector-token
   面引入 `YES`,已在提交前被该审计拦下并改为本形态,审计允许集合零修改。
2. `collect_platform_evidence.py`:`_validate_runtime_receipt` 由 18 项大合取
   (任一失败均报同一句、KeyError 静默塌缩)拆为逐项判定:每项失败以
   `runtime receipt failed closed validation: <term> observed <value>` 报出字段
   名与实际值,缺失字段以 `<missing>` 哨兵具名;严格性不放宽——`is True`/
   `is False` 身份检查与精确键集保持,device 路径由 dict `==` 的
   `1 == True` 意外通过收敛为逐字段真布尔检查。receipt 无 locator/serial/用户
   路径,错误信息可安全外显。
3. 新建 `test_collect_receipt_validation.py`(14 tests):canonical all-true
   receipt 端到端通过(含 receipt 文件绑定与 core-output hash 绑定);
   **2026-07-20 实测缺陷形态**(全部 sandbox_check 字段 int 装箱)被拒且报出
   首个具名字段;逐字段 int-boxed/缺失/篡改向量各产生具名错误(15 个顶层字段
   缺失矩阵、8 个 device 布尔 int 向量、9 类标量篡改、identity/CDHash 失配、
   core hash 键集与 hex 格式);receipt 文件不一致与 core hash 漂移仍 fail
   closed;`main.m` 显式 BOOL 装箱的 source-literal 断言(12 个字面)+ `@(` 全源
   缺席断言;套件自身静态断言不含 broker 启动面(collect_fresh/launch/build/
   subprocess.Popen 仅出现于禁用清单字面)。

## Commands and results

| Command | Result |
| --- | --- |
| `env PYTHONWARNINGS=error python3 scripts/partition_decode/macos_input_broker/test_collect_receipt_validation.py` | Passed:14 tests,0 failures/skips |
| `env PYTHONWARNINGS=error python3 scripts/partition_decode/test_decode.py`(只读重跑) | Passed:43 tests,0 failures——含封闭 source 审计对 r5 `main.m` 形态的验证;r4 文件零改动 |
| `xcrun clang -fsyntax-only -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -I <python3.14 include> scripts/partition_decode/macos_input_broker/main.m` | Passed:零 diagnostics |
| `ARKDECK_PYTHON=<主树>/.venv-sdd/bin/python scripts/check-sdd.sh` | Passed:0 errors,0 warnings,111 acceptance IDs |
| `git diff --check` | Passed |
| `shasum -a 256 <三个 r5 源文件>` | Passed;值见 Source identity 表 |

环境:macOS 26.5.2(25F84),arm64;CPython 3.14.6(homebrew python@3.14,与
broker 嵌入 framework 同源);`.venv-sdd` 3.14.6+PyYAML 6.0.3(仅 SDD guard)。

## Dispatch counts

broker 启动、collector 发布(create-only publication)、NSOpenPanel/GUI、pinned
archive 读取、真实/合成 device node、HDC/vendor tool、网络、subprocess(除
clang/shasum/guard 等 host 工具链校验命令外的产品面)均为 `0`。测试唯一的
文件 IO 为本地临时目录合成向量。

## Deviations and residual risk

- 无任务范围外改动;r4 四个 decoder 文件与其余全部路径零触碰。
- 初版实现曾用三元 `? @YES : @NO` 形态,被 `test_decode.py` 封闭 source 审计
  (selector-token 面)拦下——审计集合按 r5 Out-of-scope 保持零修改,实现改为
  if/else 赋值形态适配。该事件如实记录:封闭审计按设计工作。
- 残余风险:receipt 布尔语义的端到端证明(真实 broker 运行产出 JSON `true`)
  仍属 TASK-PD-002 platform run;本 contract run 以 source-literal 断言 +
  NSJSONSerialization 的 `@YES`→`true` 既定行为为依据,如实声明不构成 platform
  结论。`TEST-DECODE-DAYU200-RECEIPT-CONTRACT-001` 在本 source revision PASS,
  `ready→done` 仍须独立状态 PR 经维护者 review/merge。

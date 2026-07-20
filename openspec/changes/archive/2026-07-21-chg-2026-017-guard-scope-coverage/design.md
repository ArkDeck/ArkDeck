# Design — CHG-2026-017 check_sdd scope 覆盖校验

> Status:r2 candidate。本文件规定新增 guard 校验的算法与边界;实现须与本文一致,
> 测试须覆盖本文列出的正反用例。

## 1. 校验规则(单向:scope acceptance ⊆ claimed)

对 `openspec/changes/chg-*/` 下**每个含 `scope.yaml` 的 change**:

1. 解析 `scope.yaml` 的 `acceptance:` 列表 → `scope_ids`(acceptance ID
   集合;每个值是不透明、大小写敏感的非空字符串)。
2. 解析同 change `tasks.md`,收集全部任务 `Requirements/AC:` 行认领的 token →
   `claimed`(见 §2 解析规则)。
3. 对 `scope_ids` 中每个 ID:若不在 `claimed` → `err(scope.yaml,
   f"scope acceptance {acceptance_id} 未被任何任务 Requirements/AC 行认领")`。
4. 无 `scope.yaml` 的 change 跳过(与现状一致)。

**单向性**:只校验 `scope_ids ⊆ claimed`,不校验 `claimed ⊆ scope_ids`——任务可引用
canonical Safety input 等 scope 外 AC(read-only,不认领 completion),不构成错误。

## 2. acceptance ID 精确认领规则(tasks.md `Requirements/AC:` 行)

- 认领面 = 以 `- Requirements/AC:` 开头的行 **及其缩进续行**(下一个 `- ` 顶层
  bullet 之前的缩进行)。
- 不使用固定 `AC-*` 正则枚举 token。对每个 `scope_ids` 元素动态构造
  `(?<![A-Za-z0-9_-])<re.escape(id)>(?![A-Za-z0-9_-])`,仅在认领面
  出现完整、大小写一致且不与其他 ASCII 标识符字符粘连时计入
  `claimed`。
- 反引号、`、`/`；`/`;`/空格和换行都是合法边界;它们不会改写 ID。
- `…`、`*`、`01/02`、`等`、前缀或自然语言都不展开为未写出的 ID;
  只有 `scope.yaml` 中那个完整字符串在认领面精确出现才构成认领。
- 任务认领面可包含 `REQ-*`/`POL-*`/scope 外 acceptance ID;单向校验不对
  这些额外 token 报错。

## 3. 边界与幂等

- 校验只读,不修改任何文件;与现有五节校验并列,汇入同一 err/warn 计数。
- PR #183 的 exact preflight 证明 r1 基线声明不成立;`TASK-GUARD-001`
  保持 `blocked`。实现前必须先合入独立 traceability remediation,
  将四个 scoped change(M0A/M1/CHG-005/M0B)的每个 acceptance ID 显式写入
  某个 `Requirements/AC:` 认领面,然后以新 readiness PR 复跑证明
  `scope acceptance ⊆ claimed` 全部成立。
- 增强前后 `scripts/check-sdd.sh` 仍必须保持 `0/0/111`;任一 false
  positive 即实现缺陷,须修精确匹配器而非推断或放宽认领。

## 4. 测试(scripts/test_check_sdd.py)

合成 fixture(临时目录,不碰真实 openspec)覆盖:

- **正例**:scope.yaml acceptance=[AC-X-001-01, MAC-X-PORT-001,
  HW-X-DEVICE-001],三个不同前缀 ID 均被某 task `Requirements/AC:` 认领
  (含反引号变体、含缩进续行变体)→ 零 err;
- **反例(核心)**:scope.yaml 含 AC-X-003-01 但无任务认领 → 恰一条具名 err,消息
  含 `AC-X-003-01`;
- **解析边界**:`、`/`；`/`;`/空格分隔、反引号包裹、续行认领、标识符
  前后粘连拒绝、干扰行(非 Requirements/AC 行内的 token 不计入认领)
  各一用例;
- **简写拒绝**:`AC-X-001-01…03`、`AC-X-002-*`、`AC-X-003-01/02`、
  `MAC-X-PORT-001 等` 均不隐式认领未精确写出的 scope ID;
- **跳过**:无 scope.yaml 的合成 change → 零 err(不误报);
- **真实基线**:仅在显式 traceability remediation 合入后,对真实
  `openspec/` 跑增强后的 `check_sdd` 主流程,断言四个 scope.yaml change
  零 scope-coverage err。

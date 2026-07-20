# Design — CHG-2026-017 check_sdd scope 覆盖校验

> Status:candidate。本文件规定新增 guard 校验的算法与边界;实现须与本文一致,
> 测试须覆盖本文列出的正反用例。

## 1. 校验规则(单向:scope acceptance ⊆ claimed)

对 `openspec/changes/chg-*/` 下**每个含 `scope.yaml` 的 change**:

1. 解析 `scope.yaml` 的 `acceptance:` 列表 → `scope_acs`(AC ID 集合)。
2. 解析同 change `tasks.md`,收集全部任务 `Requirements/AC:` 行认领的 token →
   `claimed`(见 §2 解析规则)。
3. 对 `scope_acs` 中每个 AC:若不在 `claimed` → `err(scope.yaml, f"scope acceptance
   {ac} 未被任何任务 Requirements/AC 行认领")`。
4. 无 `scope.yaml` 的 change 跳过(与现状一致)。

**单向性**:只校验 `scope_acs ⊆ claimed`,不校验 `claimed ⊆ scope_acs`——任务可引用
canonical Safety input 等 scope 外 AC(read-only,不认领 completion),不构成错误。

## 2. token 解析规则(tasks.md `Requirements/AC:` 行)

- 认领面 = 以 `- Requirements/AC:` 开头的行 **及其缩进续行**(下一个 `- ` 顶层
  bullet 之前的缩进行)。
- 从认领面文本用正则提取 AC token:`AC-[A-Z0-9]+-\d+-\d+`(与 spec Scenario 的
  AC 形态一致);容忍反引号包裹(`` `AC-JOB-003-01` ``)与 `、`/`；`/`;`/空格分隔。
- 只提取 AC(本 change 不做 REQ 覆盖);去反引号后精确匹配 `scope_acs` 元素。

## 3. 边界与幂等

- 校验只读,不修改任何文件;与现有五节校验并列,汇入同一 err/warn 计数。
- 现状基线(实现前必须复跑证明):四个 scope.yaml change(M0A/M1/CHG-005/M0B)的
  `scope acceptance ⊆ claimed` **当前全部成立**(AC-JOB-003/004 已由 #138 补认领),
  故增强不改变 `0/0/111`。任一 false positive 即实现缺陷,须修解析规则而非放宽校验。

## 4. 测试(scripts/test_check_sdd.py)

合成 fixture(临时目录,不碰真实 openspec)覆盖:

- **正例**:scope.yaml acceptance=[AC-X-001-01, AC-X-002-01],两 AC 均被某 task
  `Requirements/AC:` 行认领(含反引号变体、含缩进续行变体)→ 零 err;
- **反例(核心)**:scope.yaml 含 AC-X-003-01 但无任务认领 → 恰一条具名 err,消息
  含 `AC-X-003-01`;
- **解析边界**:`、`/`；`/`;`/空格分隔、反引号包裹、续行认领、干扰行(非
  Requirements/AC 行内的 AC token 不计入认领)各一用例;
- **跳过**:无 scope.yaml 的合成 change → 零 err(不误报);
- **真实基线**:对真实 `openspec/` 跑增强后的 `check_sdd` 主流程,断言四个 scope.yaml
  change 零 scope-coverage err(现状不回归)。

# CHG-2026-032 Design：手册引用的耐久形式

> Status:candidate（随 proposal r1；批准前不构成实现授权）
> Core baseline:CORE-2.1.0（零 Core/product behavior 变更）

## 1. 问题的结构

引用方与被引用方的生命周期不对称：

| | 位置 | 归档时是否移动 |
| --- | --- | --- |
| 手册 | `openspec/planning/` | 否（不属于任何 change） |
| 被引用的案例记录 | `openspec/changes/<id>/` | **是**（`git mv` 到 `changes/archive/<date>-<id>/`） |

因此任何 `../changes/<id>/...` 形式的相对链接都是**有到期日**的：到期日 = 该 change
的归档日。且断链静默——guard 不校验 markdown 链接可达性，CI 不会报。

指向 `changes/archive/**` 的链接不受影响：归档目录不再移动。

## 2. 耐久形式

沿用 CHG-2026-029 TASK-AFP-005 已确立并合入的形态（该任务处理了手册指向其自身
change 的那一条）：

```text
改前：[TASK-XXX `run.md`](../changes/chg-2026-0NN-name/evidence/runs/TASK-XXX/run.md)
改后：CHG-2026-0NN 的 `evidence/runs/TASK-XXX/run.md`（<定位 OID>）
```

必须保留三项，缺一即不可唯一定位：

1. **change ID**（`CHG-2026-0NN`）——归档后目录名仍含该 ID，可检索；
2. **文件名/路径尾段 + 必要的章节或任务标识**——定位到文件与位置；
3. **完整 40-hex OID**——不随目录移动失效的锚。

### OID 的选取

优先 **blob OID**（`git rev-parse <commit>:<path>`）：它直接标识被引用的**内容**，
与路径无关，归档后仍可 `git cat-file -p` 取出。次选被引用记录的承载 **merge commit
OID**：定位到该内容所在的历史点。两者都满足"不随目录移动失效"。

实现时逐条记录取值命令，禁止由短 hash 补全为 40 位（`AF-016` 在 CHG-2026-029 期间
的已知复发形态）。

## 3. 取舍

耐久形式牺牲相对链接的**点击可达性**，换取归档后不失效。这是 TASK-AFP-005 已作出
并合入的取舍，本 change 沿用以保持手册内一致——同一份文档不应对同类引用采用两套
形态。

替代方案与否决理由：

- **改指向 `changes/archive/<date>-<id>/` 预期路径**：归档日期在归档前不可知；且
  每个 change 归档时都要再改手册一次，把一次性问题变成周期性负担。
- **把被引用内容复制进手册**：制造第二份事实正本，违反 design §1 的 non-normative
  边界与"只链接不复制"声明。
- **等各 change 归档时逐次修手册**：正是当前的默认路径，也正是本 change 要消除的
  周期负担；且依赖每次归档者记得扫描手册，无机械保障。
- **加 CI 校验链接可达性**：可选的未来方向，但属新增 guard，超出本 change 范围；
  且它只能发现已断的链接，不能防止断链发生。

## 4. 范围边界

只改一个文件的引用形式与一条编辑约定。**不改任何案例的事实内容**——`Observed cases`
的 `Fact`/`Inference` 文字、根因、preflight、验证方法、`Automation status` 与
`Currency` 全部逐字保留（`Currency` 除外：若实现同时更新复核基线，须在 run 中说明；
默认不动）。

指向 `changes/archive/**` 的 16 条链接逐字不动：它们已经是耐久的，改写只降低可用性。

## 5. 验证策略

- **计数二值门**：活跃 change 相对链接 → 0；archive 类计数与内容零变化；
- **逐条对照**：run 记录"原链接 → 改后文本 → 定位 OID → 取值命令"，reviewer 可逐条
  复算；
- **OID 可解析**：每个新增 OID 用 `git cat-file -e` / `merge-base --is-ancestor` 实测；
- **归档模拟**：对每个被引用的活跃 change，验证其目录移入 archive 后手册无可断项；
- **不动面**：ID 集合、八字段契约、取值域、标注与计数逐项零变化；
- **shadow-spec**（HLD-002）：新增 normative 措辞与对其他文档的强制要求均为 0。

不为本 change 新增 parser 或 CI。

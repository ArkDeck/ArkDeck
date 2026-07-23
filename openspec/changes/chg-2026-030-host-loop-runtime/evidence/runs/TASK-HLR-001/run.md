# TASK-HLR-001 Run — PR envelope v1 contract

- Date:2026-07-23（Asia/Shanghai）。
- Executor:`agent`。
- Base:protected `main`
  `ece39d9d2a94640e56bb0a3bc7b47e5dc8804cc6`（TASK-HLR-001 readiness r3
  #400 merge；first parent =
  `09d4afd77b213efd07a5f8b0d07f1be23d71d095`，subject 携 `(#400)`）。
- Classification:`contract`，host-only/offline；零真实设备、HDC、网络/API、
  credential、Issue/ref/lease、subprocess/shell dispatch。
- Task state boundary:本 implementation/evidence run 不翻 `ready→done`；
  completion 另走独立 D0 status PR。

## Deliverables

- `scripts/host_loop/pr_envelope.py`：共享有序 field definition 驱动的 envelope
  v1 renderer/parser/validator；UTF-8/LF、marker、字段顺序、type/task、OID、
  D grade、dependency、evidence、attribution 与 active change/task binding
  全部 fail closed。
- `scripts/host_loop/test_pr_envelope.py`：正反 contract、真实 active task 与
  MECH-004 compatibility、front-matter identity、provider-neutral attribution、
  无外部命令面静态审计。
- `openspec/templates/agent-pr-body.md`：版本化 machine block 模板；producer 与
  run 只来自显式配置占位符，零固定模型/厂商 attribution。

## Commands and results

| Command | Result |
| --- | --- |
| `python3 -m unittest discover -s scripts/host_loop -p 'test_*.py'` | PASS，17 tests，覆盖七类 PR type、十个必填字段逐项缺失、marker/顺序/duplicate/unknown、multiple/inconsistent Task、OID/grade/dependency/evidence/attribution、零/多 active change/task、MECH-004 与静态边界 |
| `python3 scripts/test_check_pr_paths.py` | PASS，20 tests |
| `python3 scripts/test_check_sdd.py`（PyYAML 6.0.3 SDD interpreter） | PASS，19 tests |
| `ARKDECK_PYTHON=<existing-sdd-python> ./scripts/check-sdd.sh` | PASS，0 errors / 0 warnings / 111 acceptance IDs；临时 interpreter 绝对路径按 privacy 边界不入 evidence |
| `python3 -m py_compile scripts/host_loop/__init__.py scripts/host_loop/pr_envelope.py scripts/host_loop/test_pr_envelope.py` | PASS |
| `git diff --check` | PASS |
| production import/call AST scan（测试 `test_runtime_module_is_standard_library_only_and_has_no_command_surface`） | PASS；`subprocess/socket/http/urllib/requests` import = 0，command-construction/execution calls = 0 |

## Contract observations

- task-bound `implementation/status/verification/archive` 只接受唯一
  `Task: TASK-*`；`proposal/approval/readiness` 只接受 `Task: none`。
- 完整 task envelope 被现有 `check_pr_paths.TASK_LINE_RE` 与
  `resolve_task_declaration` 原样识别，并可进入 active task Allowed paths
  resolver；non-task envelope 不产生 task declaration。
- Base/Head 只接受不同的 lowercase full 40-hex；D grade 只接受
  `D0/D1/D2`；dependency 只接受 `none` 或 `#<positive decimal>`。
- evidence 只接受 repository-relative POSIX path，或唯一
  `none: <non-empty reason>`；POSIX/Windows absolute、URL、反斜杠与 traversal
  全拒绝。
- attribution 恰为 configured producer、`runtime: host-loop/1` 与 opaque run；
  provider/model sentinel 被拒，production source/template/default 无固定厂商名。
- parser 只从 active proposal 的 closed YAML front matter 取得 canonical
  change id，并要求同 change `tasks.md` 中 task 恰一命中。

## Scope audit

- Allowed diff：`scripts/host_loop/**`、
  `openspec/templates/agent-pr-body.md`、本 run 与本 task evidence 引用。
- Forbidden diff：`AGENTS.md`、Constitution、`openspec/governance/**`、Core
  specs/contracts、archive、`.github/**`、产品 source/tests = **0**。
- Runtime boundary：GitHub/API/network/subprocess/shell、Issue/cursor/lease、
  credential、auto-review/merge、task/change 状态写入 = **0**。

## Deviation and residual gate

- 首次 15-test run 有 1 个测试断言只期待了错误文案
  `empty or ambiguous`，实现实际正确返回更精确的
  `none evidence requires a non-empty reason`；修正测试期望并加入
  front-matter/Windows absolute/multiple Task 加固后，最终 17/17 PASS。该中间失败不作为
  passing evidence。
- `HLR-ENVELOPE-001` 的 **TASK-HLR-001 contract slice = PASS candidate**。
  change-level acceptance 仍需 HLR-005 的真实 first-PR-event/live evidence，
  且本任务最终结论须由维护者在独立 done PR 确认。

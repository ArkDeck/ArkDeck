# CHG-2026-014 Spec impact

- Core behavior：none。
- Core baseline：unchanged (`CORE-2.0.0`)。
- Current specs/contracts/schemas：unchanged。
- Core/change-local Acceptance Scenario：不修改既有 AC；只新增四项 change-local
  consolidation AC。
- Integration/platform profiles：unchanged；M1-006 缺失 probe 仍需独立 integration change。
- Hardware/support/release：unchanged；无 claim。
- Governance：不修改全局 `enforcement.md` 或 `verification/policy.md`。批准后只在本
  change 内把固定 legacy commits 重新定义为 `TASK-RLC-001` 的输入，使该新任务继续满足
  “一任务一实现 PR”；原 Task 状态和 evidence authority 不迁移。
- Consumer dependencies：本 change 不直接修改。任何非阻塞 consumer 必须走独立、
  维护者批准的 task revision，并证明不依赖 source Task 未通过的 AC。

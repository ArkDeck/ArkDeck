# DAYU200 M0B Bring-up Pre-Task Review Gate

> Status:pending(change 为 proposed;本清单是非授权性 change source 输入)

- [x] Change 是 platform class、`core_change_level: none`,不含任何产品代码、
      Provider、flash 或支持声明
- [x] DEC-001 已 decided(#53)且本 change 与其 Boundary 一致:目标选定 ≠ 支持
      声明,matrix 只产生 `observed`/`partial`
- [x] 两个 Task 的 Requirement/Acceptance 集合与 scope.yaml 精确一致(5 AC)
- [x] 全部真机操作由人类维护者执行;Agent 不执行真实 `hdc`(M0A 结论继承)
- [x] 只读命令白名单封闭且写入 design.md;唯一设备端状态变化=人工授权信任确认
- [x] `GAP-DAYU200-RECOVERY-PATH` unknown 前提下无任何可能致砖/状态漂移操作
- [x] evidence 契约=`hardware-evidence.schema.json`(2.0.0);含序列号字节不入
      仓库;capture 不得改写;golden 登记推迟到后续 integration change
- [x] TASK-M0B-002 依赖 TASK-M1-006 done,且解除 blocked 须独立 readiness PR
      复核 M1-006 实际交付形态
- [ ] 维护者批准本 change(approval-only PR,merge 即批准;approved 前任务不可
      执行)
- [ ] TASK-M0B-001 执行窗口:物理 DAYU200 在场 + 维护者时间确认

本清单不构成 claim、evidence、approval 或 Ready 状态。

import { Button } from "@arkdeck/ds";

const row = {
  display: "flex",
  gap: 10,
  flexWrap: "wrap" as const,
  alignItems: "center",
};

/** The three variants in current v0.6 product language. */
export const VariantScale = () => (
  <div style={row}>
    <Button>更换镜像…</Button>
    <Button variant="primary">选择镜像…</Button>
    <Button variant="danger">擦除数据并开始刷机</Button>
  </div>
);

/** `danger` is only for steps that mutate or destroy device state. */
export const DestructiveActions = () => (
  <div style={row}>
    <Button variant="danger">擦除数据并开始刷机</Button>
    <Button variant="danger">清空设备 buffer…</Button>
    <Button variant="danger">结束恢复并归档…</Button>
  </div>
);

/** Every disabled button names the unmet precondition in `title`. */
export const BlockedByPrecondition = () => (
  <div style={row}>
    <Button
      variant="danger"
      disabled
      title="required prerequisite recoveryPath 为 unsatisfied，Runtime 拒绝提交"
    >
      擦除数据并开始刷机
    </Button>
    <Button disabled title="Provider 未声明 restartSafe,最后一步结果不明">
      从安全边界继续
    </Button>
    <Button disabled title="仍在等待窗口内,归档不可用">
      结束恢复并归档…
    </Button>
  </div>
);

/** Job Drawer cancel — the label states the cancellation policy, not just "取消". */
export const JobDrawerCancel = () => (
  <div style={row}>
    <Button>取消(在安全边界)</Button>
    <Button disabled title="取消已请求,正在等待任务走到安全边界">
      等待安全边界…
    </Button>
  </div>
);

/** Reconnect after a drop needs an explicit identity confirmation, never a silent resume. */
export const RebindDecision = () => (
  <div style={row}>
    <Button variant="primary">确认同一设备,继续</Button>
    <Button>中止</Button>
  </div>
);

/** Host-only, non-destructive actions stay on the default variant. */
export const HostOnlyActions = () => (
  <div style={row}>
    <Button>导出诊断包…</Button>
    <Button>在访达中显示</Button>
    <Button variant="primary">导出 Session 包</Button>
  </div>
);

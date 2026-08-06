import { BudgetMeters, Card, Chip, StatusStrip } from "@arkdeck/ds";

const hint = { margin: 0, fontSize: 12.5, lineHeight: 1.6, color: "var(--ad-ink-2)" };
const mono = { fontFamily: "var(--ad-font-mono)" };

const BUDGETS = [
  { name: "Rounds", value: "4 / 8", percent: 50 },
  { name: "Wall clock", value: "07:42 / 30:00", percent: 26 },
  { name: "Artifacts", value: "18.4 / 64 MB", percent: 29 },
  { name: "E1 mutations", value: "2 / 4", percent: 50 },
  { name: "Model calls", value: "3 / 12", percent: 25 },
];

/** bounded debug loop 的五条停止条件,全部以「已花 / 上限」呈现。 */
export const BoundedLoopBudgets = () => (
  <div style={{ width: "100%", maxWidth: 820 }}>
    <Card
      title="预算"
      action={<Chip tone="dim">停止条件已固化</Chip>}
    >
      <BudgetMeters budgets={BUDGETS} />
      <p style={hint}>
        no-progress 0/2 · action retry 0/2。任一预算耗尽即停止并保存 machine reason,不自动扩大预算。
      </p>
    </Card>
  </div>
);

/** 与页顶摘要条同读:running 的任务还剩多少额度,一屏之内答完。 */
export const BudgetsUnderLifecycle = () => (
  <div style={{ width: "100%", maxWidth: 820, display: "flex", flexDirection: "column", gap: 12 }}>
    <StatusStrip
      cells={[
        { label: "Runtime task", value: <span style={mono}>HTASK-DEMO-001 · debugCrash</span> },
        { label: "Lifecycle", value: <Chip tone="warn">● running</Chip> },
        { label: "Current stage", value: "patching" },
        { label: "Target binding", value: <span style={mono}>rk3568-dev · rev 4</span> },
      ]}
    />
    <Card title="预算" action={<Chip tone="dim">停止条件已固化</Chip>}>
      <BudgetMeters budgets={BUDGETS} />
      <p style={hint}>
        Rounds 4/8 与 E1 mutations 2/4 都已过半:再有两次设备侧改动就会触顶,循环随即停止。
      </p>
    </Card>
  </div>
);

/** 唯一允许画确定进度的场景:分母由 host 自己持有。 */
export const DeterminateOnlyWithARealDenominator = () => (
  <div style={{ width: "100%", maxWidth: 820 }}>
    <Card title="为什么这里可以画满格条">
      <BudgetMeters budgets={BUDGETS} />
      <p style={hint}>
        轮次、墙钟、产物体积、E1 改动次数、模型调用都有 host 自己拥有的上限,百分比是算出来的,不是估的。
      </p>
      <p style={hint}>
        设备侧工作没有这样的分母 —— 那里用 IndeterminateBar 并写明阶段名,绝不编造百分比。
      </p>
    </Card>
  </div>
);

/** 窄栏形态:auto-fit 收成一列,tabular numerals 让数字随刷新不跳。 */
export const TabularStackInANarrowColumn = () => (
  <div style={{ width: "100%", maxWidth: 640, display: "flex", gap: 14, alignItems: "flex-start" }}>
    <div style={{ width: "100%", maxWidth: 190 }}>
      <Card title="预算">
        <BudgetMeters budgets={BUDGETS} />
      </Card>
    </div>
    <div style={{ flex: 1, minWidth: 0 }}>
      <Card title="窄栏里的读法">
        <p style={hint}>
          栅格是 auto-fit:内容区宽时五条并排,收窄到检查器宽度时叠成一列,名称在左、用量在右。
        </p>
        <p style={hint}>
          数字用等宽数位排版,4 / 8 变成 5 / 8、07:42 变成 08:03 时,整列的小数点与斜杠不会左右晃动。
        </p>
      </Card>
    </div>
  </div>
);
